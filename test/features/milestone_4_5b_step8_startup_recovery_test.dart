import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/restore_recovery_service.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

/// Milestone 4.5B Step 8: Startup Recovery and Decision Table Deterministic Verification
///
/// Validates cold-start recovery across all 20 states + edge cases:
/// - Journal authentication and atomic writes
/// - Non-destructive rollback from .pre_restore_backup
/// - Fail-closed quarantine on ambiguity or dual corruption
/// - Native exclusive lock verification before destructive filesystem repair
/// - Sidecar purging and zero permanent deletion of recoverable artifacts

class Step8MockProcessLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;

  bool isRestorePending = false;
  bool isRestoreExclusiveHeld = false;
  bool failBeginExclusiveRestore = false;

  final List<String> eventLog = [];

  @override
  MethodChannel get channel => const MethodChannel('spendx/process_lock');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    eventLog.add('acquireForegroundLease:$engineId');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire foreground lease while restore is pending or exclusive',
      );
    }
    if (activeForegroundLeaseToken != null) {
      return activeForegroundLeaseToken!;
    }
    acquireForegroundCount++;
    readersCount++;
    activeForegroundLeaseToken = 'fg_lease_$acquireForegroundCount';
    return activeForegroundLeaseToken!;
  }

  @override
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
    eventLog.add('releaseForegroundLease:$leaseToken');
    if (activeForegroundLeaseToken == null || activeForegroundLeaseToken != leaseToken) {
      return false;
    }
    activeForegroundLeaseToken = null;
    releaseForegroundCount++;
    readersCount = (readersCount - 1).clamp(0, 999999);
    return true;
  }

  @override
  Future<NativeTicketResult> acquireOperationTicket({
    String? engineId,
    required String tag,
  }) async {
    eventLog.add('acquireOperationTicket:$tag');
    if (isRestorePending || isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException(
        'ADMISSION_CLOSED: Cannot acquire operation ticket while restore is pending or exclusive',
      );
    }
    ticketCounter++;
    final assignedEngineId = engineId ?? 'engine_$ticketCounter';
    final ticketId = 'ticket_${ticketCounter}_$tag';
    activeTickets[ticketId] = {
      'ticketId': ticketId,
      'engineId': assignedEngineId,
      'tag': tag,
    };
    readersCount++;
    return NativeTicketResult(
      ticketId: ticketId,
      tag: tag,
      engineId: assignedEngineId,
    );
  }

  @override
  Future<bool> releaseOperationTicket(
    String ticketId, {
    String? engineId,
  }) async {
    eventLog.add('releaseOperationTicket:$ticketId');
    final ticket = activeTickets.remove(ticketId);
    if (ticket == null) {
      throw const StaleTicketException('Stale or unknown ticket');
    }
    readersCount = (readersCount - 1).clamp(0, 999999);
    return true;
  }

  @override
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async {
    eventLog.add('beginExclusiveRestore');
    if (failBeginExclusiveRestore) {
      throw const RestoreLockTimeoutException(
        'TIMEOUT: Injected exclusive restore lock timeout',
      );
    }
    isRestorePending = false;
    isRestoreExclusiveHeld = true;
    return 'restore_token_step8';
  }

  @override
  Future<bool> completeExclusiveRestore(String restoreToken) async {
    eventLog.add('completeExclusiveRestore:$restoreToken');
    isRestoreExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> abortExclusiveRestore(String restoreToken) async {
    eventLog.add('abortExclusiveRestore:$restoreToken');
    isRestoreExclusiveHeld = false;
    return true;
  }

  @override
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async {
    eventLog.add('validateExclusiveRestoreToken:$restoreToken');
    if (restoreToken.trim().isEmpty) return false;
    return isRestoreExclusiveHeld && restoreToken == 'restore_token_step8';
  }

  @override
  Future<Map<String, dynamic>> getLockStatus() async {
    return {
      'state': isRestoreExclusiveHeld
          ? 'EXCLUSIVE_HELD'
          : (isRestorePending ? 'RESTORE_PENDING' : 'OPEN'),
      'activeReadersCount': readersCount,
      'activeTicketsCount': activeTickets.length,
      'hasForegroundLease': activeForegroundLeaseToken != null,
    };
  }
}

class EmptyTokenMockProcessLockService extends Step8MockProcessLockService {
  @override
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async {
    return '';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;
  late Step8MockProcessLockService mockLockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue taskQueue;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_4_5b_step8_test_');
    dbPath = p.join(tempDir.path, 'spendx_step8.db');
    AppDatabase.setTestDatabasePath(dbPath);

    mockLockService = Step8MockProcessLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;

    gate = DatabaseAccessGate(processLockService: mockLockService);
    taskQueue = TrackedDatabaseTaskQueue(gate: gate);
    gate.attachTaskQueue(taskQueue);
    DatabaseAccessGate.instanceForTesting = gate;

    DatabaseLifecycleCoordinator.instance.resetForTesting();
    BackupService.resetTestingFlags();
  });

  tearDown(() async {
    SpendXDatabaseKeyManager.setTestInstance(null);
    BackupService.resetTestingFlags();
    PlatformProcessLockService.instanceForTesting = null;
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
    AppDatabase.setTestDatabasePath(null);
    DatabaseLifecycleCoordinator.instance.resetForTesting();

    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  /// Helper to create a valid test database satisfying all v24 schema and accounting checks.
  Future<void> createValidDatabase(String path) async {
    final db = await openDatabase(
      path,
      version: 24,
      onCreate: (d, v) async {
        await TablesV24.createAllV24(d);
        await TablesV24.seedSystemAccounts(d);
        await TablesV24.installTriggers(d);
        final now = DateTime.now().toUtc().toIso8601String();
        await d.insert(TablesV24.accounts, {
          'id': 'acc_step8_seed',
          'name': 'Step 8 Test Account',
          'account_type': 'asset',
          'subtype': 'checking',
          'currency': 'INR',
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        });
      },
    );
    await db.rawQuery('PRAGMA user_version = 24;');
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
    await db.close();
  }

  /// Helper to create a corrupt non-SQLite file.
  Future<void> createCorruptDatabase(String path) async {
    final file = File(path);
    await file.writeAsString('CORRUPT_NON_SQLITE_HEADER_DATA_1234567890_TRUNCATED');
  }

  /// Helper to create an authenticated journal file.
  Future<RestoreJournal> createJournal({
    required RestoreJournalState state,
    int sequenceNumber = 1,
    String? error,
    Map<String, dynamic>? expectedFingerprint,
    Map<String, dynamic>? expectedBackupFingerprint,
  }) async {
    final journalFile = File(p.join(tempDir.path, RestoreJournal.journalFileName));
    final backupFile = File('$dbPath.pre_restore_backup');
    Map<String, dynamic>? bkpFp = expectedBackupFingerprint;
    if (bkpFp == null && await backupFile.exists() && await backupFile.length() > 0) {
      try {
        final computed = await DatabaseGenerationFingerprint.compute(
          dbPath: backupFile.path,
          restoreOperationId: 'test_op_step8',
          expectedGeneration: 0,
        );
        bkpFp = computed.toJson();
      } catch (_) {}
    }

    final journal = await RestoreJournal.create(
      journalFile: journalFile,
      restoreOperationId: 'test_op_step8',
      targetDbPath: dbPath,
      safetyBackupPath: '$dbPath.pre_restore_backup',
      swapCandidatePath: '$dbPath.new_swap',
      expectedFingerprint: expectedFingerprint,
      expectedBackupFingerprint: bkpFp,
    );
    if (state != RestoreJournalState.stagingPrepared) {
      await journal.record(
        state,
        error: error,
        expectedBackupFingerprint: bkpFp,
      );
    }
    return journal;
  }

  group('Milestone 4.5B Step 8: Startup Recovery & Decision Table Matrix', () {
    test('8.1: State 01 — Normal Healthy Cold Start', () async {
      await createValidDatabase(dbPath);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts, isEmpty);
      expect(gate.isOpen, isTrue);
    });

    test('8.2: State 02 — Stale Swap Orphan Quarantined Without Deletion', () async {
      await createValidDatabase(dbPath);
      final swapFile = File('$dbPath.new_swap');
      await swapFile.writeAsString('stale swap content');

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.length, 1);
      expect(result.quarantinedArtifacts.first, contains('orphan_swap'));

      // Sibling swap file is quarantined, not permanently deleted
      expect(swapFile.existsSync(), isFalse);
      expect(File(result.quarantinedArtifacts.first).existsSync(), isTrue);
    });

    test('8.3: State 03 — Stale Backup Orphan Retained Indefinitely', () async {
      await createValidDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.length, 1);
      expect(result.quarantinedArtifacts.first, contains('retained_backup'));

      // Safety backup is preserved in quarantine
      expect(File(result.quarantinedArtifacts.first).existsSync(), isTrue);
    });

    test('8.4: State 04 & 05 — Crash in cleanupPending / contentVerified', () async {
      await createValidDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.cleanupPending);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.first, contains('archive_backup'));

      // Journal cleared after clean finalization
      final journalFile = File(p.join(tempDir.path, RestoreJournal.journalFileName));
      expect(journalFile.existsSync(), isFalse);
    });

    test('8.5: State 06 — Crash During Swap with Valid Live DB Roll-Forwards', () async {
      await createValidDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.first, contains('safety_backup'));
    });

    test('8.6: State 07 — Crash During Swap with Corrupt Live DB Rolls Back from Backup', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(mockLockService.eventLog, contains('beginExclusiveRestore'));
      expect(mockLockService.eventLog, contains('completeExclusiveRestore:restore_token_step8'));

      // Corrupt live was quarantined
      expect(result.quarantinedArtifacts.any((a) => a.contains('corrupt_swap_live')), isTrue);

      // Reopened database is healthy pre-restore generation
      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(dbPath);
      expect(isValid, isTrue);
    });

    test('8.7: State 08 — Crash Mid-Rename (Live Missing, Backup Valid) Restores Backup', () async {
      // Live DB does not exist
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(File(dbPath).existsSync(), isTrue);
      expect(mockLockService.eventLog, contains('beginExclusiveRestore'));
    });

    test('8.8: State 09 — Crash in backupCreated with Corrupt Live DB Rolls Back', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.backupCreated);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.any((a) => a.contains('corrupt_pre_swap')), isTrue);
      expect(File(dbPath).existsSync(), isTrue);
    });

    test('8.9: State 10 — Crash in backupCreated with Valid Live DB Preserves Live', () async {
      await createValidDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.backupCreated);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.any((a) => a.contains('aborted_backup')), isTrue);
    });

    test('8.10: State 11 — Active DB Missing, Unlinked Backup Present Fails Closed (No Journal)', () async {
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      // Gate admission must remain strictly closed to prevent unauthorized orphan promotion
      expect(gate.isClosed, isTrue);

      // Orphan backup is quarantined and preserved, never deleted
      final entries = tempDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(entries.any((e) => e.contains('orphan_backup')), isTrue);
    });

    test('8.11: State 12 — Dual Corruption (Live and Backup Corrupt) Enforces Quarantine', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createCorruptDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );

      // Gate admission must remain strictly closed!
      expect(gate.isClosed, isTrue);

      // Both corrupt files preserved in quarantine
      final entries = tempDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(entries.any((e) => e.contains('fatal_corrupt_live')), isTrue);
      expect(entries.any((e) => e.contains('fatal_corrupt_backup')), isTrue);
    });

    test('8.12: State 13 — Live Missing and Backup Corrupt Enforces Quarantine', () async {
      final backupPath = '$dbPath.pre_restore_backup';
      await createCorruptDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);
    });

    test('8.13: State 14 — Live & Backup Missing, Swap Valid Promotes Swap', () async {
      final swapPath = '$dbPath.new_swap';
      await createValidDatabase(swapPath);
      await createJournal(state: RestoreJournalState.swapping);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(File(dbPath).existsSync(), isTrue);
      expect(result.quarantinedArtifacts.any((a) => a.contains('promoted_swap')), isTrue);
    });

    test('8.14: State 15 — Crash After Rollback Finalizes State', () async {
      await createValidDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.rolledBack);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.any((a) => a.contains('consumed_rollback_backup')), isTrue);
    });

    test('8.15: State 16 — Prior Unresolved Quarantine Recorded Refuses Auto-Recovery', () async {
      await createValidDatabase(dbPath);
      await createJournal(state: RestoreJournalState.quarantined);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);
    });

    test('8.16: State 17 — Live Corrupt Without Backup Fails Closed', () async {
      await createCorruptDatabase(dbPath);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);
    });

    test('8.17: State 18 — Journal HMAC Tampering Detected with Clean Live DB', () async {
      await createValidDatabase(dbPath);
      final journal = await createJournal(state: RestoreJournalState.swapping);
      // Tamper with journal file
      final content = await journal.file.readAsString();
      final tampered = content.replaceFirst('swapping', 'quarantined');
      await journal.file.writeAsString(tampered, flush: true);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(result.quarantinedArtifacts.any((a) => a.contains('corrupt_journal')), isTrue);
    });

    test('8.18: State 18b — Journal Tampering with Ambiguous Backup Fails Closed', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      final journal = await createJournal(state: RestoreJournalState.swapping);
      // Tamper with journal
      await journal.file.writeAsString('INVALID_JSON_CORRUPTED_HMAC', flush: true);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);
    });

    test('8.19: State 19 — Exclusive Lock Acquisition Failure Aborts Repair', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      // Simulate native exclusive lock contention
      mockLockService.failBeginExclusiveRestore = true;

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('exclusive restore lock acquisition failed'))),
      );

      // File was NOT modified due to lock failure
      expect(await File(dbPath).readAsString(), contains('CORRUPT_NON_SQLITE'));
    });

    test('8.20: State 20 — Sidecars Cleared on Rollback', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      // Create stale sidecars
      final wal = File('$dbPath-wal');
      final shm = File('$dbPath-shm');
      await wal.writeAsString('stale wal');
      await shm.writeAsString('stale shm');

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);
      expect(wal.existsSync(), isFalse);
      expect(shm.existsSync(), isFalse);
    });

    test('8.21: End-to-End Startup Integration — AppDatabase.database triggers recovery reconciliation before open', () async {
      // Setup corrupted live with valid backup and swapping journal
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      // Calling AppDatabase.instance.database will run _initDB() which runs reconcile()
      final db = await AppDatabase.instance.database;
      expect(db.isOpen, isTrue);

      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, 24);

      // Corrupt live DB was safely rolled back before any query ran
      final rows = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['acc_step8_seed'],
      );
      expect(rows.length, 1);
    });

    test('8.22: End-to-End Quarantine Integration — Failed recovery blocks all queries', () async {
      // Setup dual corruption
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createCorruptDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      await expectLater(
        () => AppDatabase.instance.database,
        throwsA(isA<RestoreQuarantinedException>()),
      );

      expect(gate.isClosed, isTrue);
      expect(
        () => gate.admit(() async => 1),
        throwsA(isA<DatabaseGateClosedException>()),
      );
    });

    test('8.23: Streaming SHA-256 Fingerprint — Full digest streaming, binding operation ID, generation, and WAL', () async {
      await createValidDatabase(dbPath);

      final fp1 = await DatabaseGenerationFingerprint.compute(
        dbPath: dbPath,
        restoreOperationId: 'op_alpha',
        expectedGeneration: 1,
      );

      final fp2 = await DatabaseGenerationFingerprint.compute(
        dbPath: dbPath,
        restoreOperationId: 'op_beta',
        expectedGeneration: 1,
      );

      // Same database file yields identical streaming file SHA-256
      expect(fp1.dbFileSha256, equals(fp2.dbFileSha256));
      expect(fp1.dbFileSha256.length, 64);

      // Distinct operation IDs produce distinct composite hashes (cryptographic binding)
      expect(fp1.compositeHash, isNot(equals(fp2.compositeHash)));

      // Modifying 1 byte in database file changes the file SHA-256
      final bytes = await File(dbPath).readAsBytes();
      bytes[100] ^= 0xFF;
      final tamperedPath = '$dbPath.tampered';
      await File(tamperedPath).writeAsBytes(bytes, flush: true);

      final fpTampered = await DatabaseGenerationFingerprint.compute(
        dbPath: tamperedPath,
        restoreOperationId: 'op_alpha',
        expectedGeneration: 1,
      );
      expect(fpTampered.dbFileSha256, isNot(equals(fp1.dbFileSha256)));

      // Non-empty WAL is digested
      final walFile = File('$dbPath-wal');
      await walFile.writeAsString('uncheckpointed wal frames data', flush: true);
      final fpWithWal = await DatabaseGenerationFingerprint.compute(
        dbPath: dbPath,
        restoreOperationId: 'op_alpha',
        expectedGeneration: 1,
      );
      expect(fpWithWal.walFileSha256, isNotNull);
      expect(fpWithWal.walFileSha256!.length, 64);
      expect(fpWithWal.compositeHash, isNot(equals(fp1.compositeHash)));
    });

    test('8.24: State 14 Hardening — Swap candidate with fingerprint mismatch is quarantined and fails closed', () async {
      final swapPath = '$dbPath.new_swap';
      await createValidDatabase(swapPath);

      // Journal specifies expected fingerprint with mismatched hash
      final fakeFp = DatabaseGenerationFingerprint(
        restoreOperationId: 'test_op_step8',
        expectedGeneration: 1,
        dbFileSha256: '0000000000000000000000000000000000000000000000000000000000000000',
        compositeHash: 'fake_composite',
      );

      await createJournal(
        state: RestoreJournalState.swapping,
        expectedFingerprint: fakeFp.toJson(),
      );

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);

      // Active database was NOT created from unverified swap
      expect(File(dbPath).existsSync(), isFalse);

      // Swap candidate was quarantined due to fingerprint mismatch
      final entries = tempDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(entries.any((e) => e.contains('unverified_swap_fingerprint_mismatch')), isTrue);
    });

    test('8.25: State 14 Hardening — Swap candidate present under non-swapping state is quarantined, never promoted', () async {
      final swapPath = '$dbPath.new_swap';
      await createValidDatabase(swapPath);

      // Journal is in quiesced state (not swapping or swapComplete)
      await createJournal(state: RestoreJournalState.quiesced);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);

      // Swap was quarantined, active database was NOT promoted
      expect(File(dbPath).existsSync(), isFalse);
      final entries = tempDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(entries.any((e) => e.contains('orphan_swap')), isTrue);
    });

    test('8.26: Journal Authentication — Constant-time HMAC rejects 1-byte tampered signature', () async {
      await createValidDatabase(dbPath);
      final journal = await createJournal(state: RestoreJournalState.swapping);

      // Tamper with HMAC by 1 byte
      final origHmac = journal.hmacSha256;
      final tamperedChar = origHmac[0] == 'a' ? 'b' : 'a';
      final tamperedHmac = '$tamperedChar${origHmac.substring(1)}';

      final content = await journal.file.readAsString();
      final tamperedContent = content.replaceFirst(origHmac, tamperedHmac);
      await journal.file.writeAsString(tamperedContent, flush: true);

      await expectLater(
        () => RestoreJournal.load(journal.file.path),
        throwsA(isA<RestoreJournalCorruptException>()),
      );
    });

    test('8.27: Journal Authentication — Stale or decreasing sequence numbers reject with RestoreJournalCorruptException', () async {
      await createValidDatabase(dbPath);
      final journal = await createJournal(state: RestoreJournalState.swapping);

      final content = await journal.file.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      map['sequenceNumber'] = 0;
      await journal.file.writeAsString(jsonEncode(map), flush: true);

      await expectLater(
        () => RestoreJournal.load(journal.file.path),
        throwsA(isA<RestoreJournalCorruptException>().having(
          (e) => e.message,
          'message',
          contains('Stale or invalid journal sequence counter'),
        )),
      );
    });

    test('8.28: Key Retrieval Safety — Key unavailability fails closed without recreating key', () async {
      await createValidDatabase(dbPath);

      // Setup in-memory adapter throwing read failure
      final inMemory = InMemorySecureStorageAdapter();
      inMemory.shouldThrowOnRead = true;
      inMemory.readExceptionMessage = 'Simulated hardware keystore failure';
      SpendXDatabaseKeyManager.setTestInstance(
        SpendXDatabaseKeyManager(storageAdapter: inMemory),
      );

      // Corrupt live database and valid backup
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);

      // Key generation was NOT invoked
      inMemory.shouldThrowOnRead = false;
      expect(await inMemory.containsKey(SpendXDatabaseKeyManager.defaultKeyStorageName), isFalse);
    });

    test('8.29: Key Retrieval Safety — Key invalidation fails closed without overwriting key', () async {
      await createValidDatabase(dbPath);

      final inMemory = InMemorySecureStorageAdapter();
      // Corrupt key value (only 8 bytes instead of required 32)
      inMemory.corrupt(SpendXDatabaseKeyManager.defaultKeyStorageName, 'Y29ycnVwdA==');
      SpendXDatabaseKeyManager.setTestInstance(
        SpendXDatabaseKeyManager(storageAdapter: inMemory),
      );

      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>()),
      );
      expect(gate.isClosed, isTrue);

      // Storage was NOT overwritten with a regenerated key
      expect(
        await inMemory.read(SpendXDatabaseKeyManager.defaultKeyStorageName),
        equals('Y29ycnVwdA=='),
      );
    });

    test('8.30: Interrupted Journal Reconciliation — Incomplete .tmp journal is quarantined', () async {
      await createValidDatabase(dbPath);
      final journal = await createJournal(state: RestoreJournalState.swapping);

      // Simulate interrupted atomic write leaving .tmp behind
      final tmpFile = File('${journal.file.path}.tmp');
      await tmpFile.writeAsString('{"incomplete": true}', flush: true);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);

      // .tmp file was quarantined
      expect(tmpFile.existsSync(), isFalse);
      expect(result.quarantinedArtifacts.any((a) => a.contains('incomplete_journal_tmp')), isTrue);
    });

    test('8.31: Exclusive Locking — Quarantining and mutations strictly require valid restore token', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);
      await createJournal(state: RestoreJournalState.swapping);

      // EmptyTokenMockProcessLockService defined at top-level returns empty token
      PlatformProcessLockService.instanceForTesting = EmptyTokenMockProcessLockService();

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('acquired native exclusive restore token is null or empty'),
        )),
      );
    });

    test('8.32: Zero Permanent Deletion — Pre-restore backup is archived with timestamp, never unlinked', () async {
      await createValidDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);

      // In cleanupPending/contentVerified state, backup must be archived, not deleted
      await createJournal(state: RestoreJournalState.cleanupPending);

      final result = await RestoreRecoveryService.instance.reconcile(dbPath: dbPath);
      expect(result.admissionPermitted, isTrue);

      // .pre_restore_backup is no longer at its original active path
      expect(File(backupPath).existsSync(), isFalse);

      // BUT archived backup exists in quarantine/archive path with preserved content
      expect(result.quarantinedArtifacts.any((a) => a.contains('archive_backup')), isTrue);
      final archiveFilePath = result.quarantinedArtifacts.firstWhere((a) => a.contains('archive_backup'));
      expect(File(archiveFilePath).existsSync(), isTrue);

      // Deep validate archived database to prove zero data loss/corruption
      final isArchiveValid = await RestoreRecoveryService.instance.validateCandidateDatabase(archiveFilePath);
      expect(isArchiveValid, isTrue);
    });

    test('8.33: Rollback Provenance — Backup fingerprint mismatch aborts rollback, quarantines backup, and fails closed', () async {
      await createCorruptDatabase(dbPath);
      final backupPath = '$dbPath.pre_restore_backup';
      await createValidDatabase(backupPath);

      // Supply a fake expected backup fingerprint with a mismatched hash
      final fakeBackupFp = DatabaseGenerationFingerprint(
        restoreOperationId: 'test_op_step8',
        expectedGeneration: 0,
        dbFileSha256: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        compositeHash: 'fake_backup_hash',
      );

      await createJournal(
        state: RestoreJournalState.swapping,
        expectedBackupFingerprint: fakeBackupFp.toJson(),
      );

      await expectLater(
        () => RestoreRecoveryService.instance.reconcile(dbPath: dbPath),
        throwsA(isA<RestoreQuarantinedException>().having(
          (e) => e.message,
          'message',
          contains('Safety backup fingerprint does not match authenticated journal'),
        )),
      );

      // Gate admission remains strictly closed
      expect(gate.isClosed, isTrue);

      // Backup was quarantined, not promoted to active DB
      final entries = tempDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(entries.any((e) => e.contains('unverified_backup_fingerprint_mismatch')), isTrue);
    });
  });
}
