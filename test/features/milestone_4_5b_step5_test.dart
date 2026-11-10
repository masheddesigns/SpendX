import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/gated_database.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/data/security/database_encryption_migration_service.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/domain/finance/economic_event.dart';
import 'package:spend_x/domain/finance/money.dart';
import 'package:spend_x/domain/finance/review_candidate.dart';
import 'package:spend_x/services/backup_file_service.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

/// Milestone 4.5B Step 5: Backup Creation While Background Operations Are Active
///
/// ============================================================================
/// ARCHITECTURAL DISTINCTION: FAKE-BASED TESTS VS REAL ANDROID ENGINE TESTS
/// ============================================================================
/// 1. Dart Integration Test Environment (this suite):
///    - Executes real SQLite database transactions, VACUUM INTO snapshots, and
///      package creation via [BackupService] and [BackupFileService].
///    - Validates real double-entry, relational, and SQLite integrity checks via
///      [CanonicalBackupValidator.validateStagedDatabase].
///    - Exercises real in-isolate admission control ([DatabaseAccessGate]) and the
///      background task queue ([TrackedDatabaseTaskQueue]).
///    - Invokes real background notification callbacks ([notificationTapBackground]).
///    - Employs [Step5MockProcessLockService] to verify that backup creation runs
///      under the shared foreground lease without closing gate admission or
///      requesting exclusive restore locks.
///
/// 2. Real Android JVM Test Environment (`android/src/test/.../SpendXProcessLockLeaseManagerTest.kt`):
///    - Validates OS-level file-descriptor locking (`FileChannel.tryLock()`) and multi-threaded
///      ticket lifecycle concurrency on the Android host.
/// ============================================================================

/// Test wrapper around [GatedDatabase] that injects failure on VACUUM INTO execution
/// to test the physical file-copy fallback path.
class FailingVacuumGatedDatabase extends GatedDatabase {
  final bool shouldFailVacuum;
  FailingVacuumGatedDatabase(super.rawDb, super.gate, {this.shouldFailVacuum = true});

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    if (shouldFailVacuum && sql.toUpperCase().contains('VACUUM INTO')) {
      throw Exception('Injected test failure: VACUUM INTO execution failed');
    }
    return super.execute(sql, arguments);
  }
}

class Step5MockProcessLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;

  bool isRestorePending = false;
  bool isRestoreExclusiveHeld = false;

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
    if (readersCount > 0) {
      throw StateError('Cannot acquire exclusive restore lock while readersCount ($readersCount) > 0');
    }
    isRestorePending = false;
    isRestoreExclusiveHeld = true;
    return 'restore_token_step5';
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
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async => true;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Step5MockProcessLockService mockLockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue taskQueue;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Clean up any stale staging artifacts from prior failed runs
    try {
      final initialTempEntries = Directory.systemTemp.listSync();
      for (final entry in initialTempEntries) {
        if (entry is Directory && p.basename(entry.path).startsWith('spendx_backup_stage_')) {
          try {
            entry.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}

    tempDir = await Directory.systemTemp.createTemp('spendx_4_5b_step5_test_');
    final dbFile = p.join(tempDir.path, 'spendx_step5.db');
    AppDatabase.setTestDatabasePath(dbFile);

    mockLockService = Step5MockProcessLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;

    gate = DatabaseAccessGate(processLockService: mockLockService);
    taskQueue = TrackedDatabaseTaskQueue(gate: gate);
    gate.attachTaskQueue(taskQueue);

    DatabaseAccessGate.instanceForTesting = gate;
    DatabaseLifecycleCoordinator.instance.resetForTesting();
  });

  tearDown(() async {
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

  /// Helper to open a staged snapshot database (encrypted or plaintext).
  Future<Database> openStagedDatabase(String path) async {
    if (DatabaseEncryptionMigrationService.isPlaintextSqliteFile(path)) {
      return await openDatabase(path, readOnly: false);
    }
    final key = await SpendXDatabaseKeyManager.instance.getOrCreateKey();
    final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);
    return await SpendXDatabaseFactory.instance.openEncryptedDatabase(
      path,
      password: blobKey,
      readOnly: false,
    );
  }

  /// Helper to seed a valid economic event with balanced double-entry postings.
  Future<void> seedBalancedTransaction({
    required Database db,
    required String eventId,
    required double amountRupees,
    required String fromAccountId,
    required String toAccountId,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final amountMinor = (amountRupees * 100).round();

    await db.transaction((txn) async {
      await txn.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': 'transfer',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Balanced transfer of Rs $amountRupees',
        'created_at': now,
        'updated_at': now,
      });

      // Credit source account (e.g. Asset decreases)
      await txn.insert(TablesV24.postings, {
        'id': '${eventId}_post_cr',
        'economic_event_id': eventId,
        'account_id': fromAccountId,
        'direction': 'credit',
        'amount_minor_units': amountMinor,
        'sequence_number': 1,
        'currency': 'INR',
        'created_at': now,
      });

      // Debit destination account (e.g. Expense or another Asset increases)
      await txn.insert(TablesV24.postings, {
        'id': '${eventId}_post_dr',
        'economic_event_id': eventId,
        'account_id': toAccountId,
        'direction': 'debit',
        'amount_minor_units': amountMinor,
        'sequence_number': 2,
        'currency': 'INR',
        'created_at': now,
      });

      // Update lifecycle status to posted (triggers validate double-entry balance)
      await txn.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [eventId],
      );
    });
  }

  group('Milestone 4.5B — Step 5: Backup Creation While Background Operations Are Active', () {
    test('5.1. Backup during normal foreground activity completes and passes full integrity checks', () async {
      final db = await AppDatabase.instance.database;
      expect(gate.isOpen, isTrue);

      // Perform initial foreground writes (account creation)
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_fg_bank_01',
        'name': 'Primary Checking',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.accounts, {
        'id': 'acc_fg_expense_01',
        'name': 'Dining Expense',
        'account_type': 'expense',
        'subtype': 'dining',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      await seedBalancedTransaction(
        db: db,
        eventId: 'evt_fg_dining_01',
        amountRupees: 450.0,
        fromAccountId: 'acc_fg_bank_01',
        toAccountId: 'acc_fg_expense_01',
      );

      // Create backup using the actual BackupService
      final packagePath = p.join(tempDir.path, 'step5_normal.spendx');
      final (pkgFile, manifest) = await BackupService.instance.createBackupPackage(
        outputFile: File(packagePath),
      );

      expect(await pkgFile.exists(), isTrue);
      expect(manifest.canonicalEventCount, 1);
      expect(manifest.postingCount, 2);
      expect(manifest.debitTotal, 45000);
      expect(manifest.creditTotal, 45000);

      // Extract and validate staged database with existing integrity suite
      final extractDir = await Directory.systemTemp.createTemp('step5_extract_');
      try {
        final staged = await BackupFileService.instance.extractPackage(
          packageFile: pkgFile,
          stagingDir: extractDir,
        );
        expect(staged.isEncrypted, isFalse);

        final stagedDb = await openStagedDatabase(staged.stagedDbFile.path);
        await CanonicalBackupValidator.validateStagedDatabase(stagedDb, staged.manifest);
        await stagedDb.close();
      } finally {
        await extractDir.delete(recursive: true);
      }

      // Assertions: Gate stayed OPEN, no exclusive restore requested
      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('5.2. Backup coexists with tracked background task without corruption or silent drops', () async {
      final db = await AppDatabase.instance.database;

      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_coexist_01',
        'name': 'Wallet',
        'account_type': 'asset',
        'subtype': 'cash',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.accounts, {
        'id': 'acc_coexist_exp',
        'name': 'Groceries',
        'account_type': 'expense',
        'subtype': 'groceries',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // Tracked background task that executes database operations concurrently
      final bgTaskCompleter = Completer<void>();
      taskQueue.runTracked('tracked_bg_mutation', () async {
        try {
          await seedBalancedTransaction(
            db: db,
            eventId: 'evt_bg_groceries_01',
            amountRupees: 620.0,
            fromAccountId: 'acc_coexist_01',
            toAccountId: 'acc_coexist_exp',
          );
          bgTaskCompleter.complete();
        } catch (e, st) {
          bgTaskCompleter.completeError(e, st);
        }
      });

      // Concurrently create backup package
      final packagePath = p.join(tempDir.path, 'step5_coexist.spendx');
      final backupFuture = BackupService.instance.createBackupPackage(
        outputFile: File(packagePath),
      );

      // Await both operations
      await Future.wait([
        bgTaskCompleter.future,
        backupFuture,
      ]);

      final (pkgFile, manifest) = await backupFuture;
      expect(await pkgFile.exists(), isTrue);

      // Verify database table integrity after concurrency
      final events = await db.query(TablesV24.economicEvents);
      expect(events.any((e) => e['id'] == 'evt_bg_groceries_01'), isTrue);

      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('5.3. Backup coexists with live notification callbacks and releases native tickets cleanly', () async {
      final db = await AppDatabase.instance.database;

      final reviewId = 'rev_notif_during_backup_01';
      final canonicalRepo = CanonicalReviewRepository();
      await canonicalRepo.createCandidate(
        ReviewCandidate(
          id: reviewId,
          sourceType: 'sms',
          suggestedEventType: CanonicalEventType.expense,
          suggestedAmount: Money.fromRupees(175.0),
          rawPayload: jsonEncode({
            'rawSource': 'Rs 175 spent at Coffee Shop',
            'parsed': {
              'amount': 175.0,
              'isCredit': false,
              'rawText': 'Rs 175 spent at Coffee Shop',
              'date': DateTime.now().toUtc().toIso8601String(),
              'merchant': 'Coffee Shop',
              'confidence': 0.98,
            },
          }),
          confidenceScore: 0.98,
          status: ReviewCandidateStatus.pending,
          createdAt: DateTime.now().toUtc(),
        ),
      );

      final notifResponse = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': reviewId,
        }),
      );

      // Concurrently trigger notification callback and backup package creation
      final packagePath = p.join(tempDir.path, 'step5_notif_coexist.spendx');
      final results = await Future.wait([
        notificationTapBackground(notifResponse),
        BackupService.instance.createBackupPackage(outputFile: File(packagePath)),
      ]);

      final (pkgFile, _) = results[1] as (File, BackupManifest);
      expect(await pkgFile.exists(), isTrue);

      // Native ticket protocol verification
      expect(
        mockLockService.eventLog.any((e) => e.startsWith('acquireOperationTicket:notification_tap_background')),
        isTrue,
      );
      expect(
        mockLockService.eventLog.any((e) => e.startsWith('releaseOperationTicket:ticket_')),
        isTrue,
      );
      expect(mockLockService.activeTickets.isEmpty, isTrue);

      // Candidate was finalized
      final candidate = await canonicalRepo.getCandidate(reviewId);
      expect(candidate, isNotNull);
      expect(candidate!.status, equals(ReviewCandidateStatus.approved));

      // Resource reconciliation
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('5.4. Snapshot consistency: Point-in-time boundary preserves balanced double-entry invariants', () async {
      final db = await AppDatabase.instance.database;

      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_snap_src',
        'name': 'Source Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.accounts, {
        'id': 'acc_snap_dst',
        'name': 'Destination Account',
        'account_type': 'asset',
        'subtype': 'savings',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // Write 1: Prior to snapshot boundary
      await seedBalancedTransaction(
        db: db,
        eventId: 'evt_snap_pre_01',
        amountRupees: 500.0,
        fromAccountId: 'acc_snap_src',
        toAccountId: 'acc_snap_dst',
      );

      // Execute backup snapshot
      final packagePath = p.join(tempDir.path, 'step5_snapshot_consistency.spendx');
      final (pkgFile, manifest) = await BackupService.instance.createBackupPackage(
        outputFile: File(packagePath),
      );

      // Write 2: Strictly after snapshot boundary
      await seedBalancedTransaction(
        db: db,
        eventId: 'evt_snap_post_02',
        amountRupees: 300.0,
        fromAccountId: 'acc_snap_src',
        toAccountId: 'acc_snap_dst',
      );

      // Verify the backup manifest and snapshot contain only the pre-snapshot state
      expect(manifest.canonicalEventCount, 1);
      expect(manifest.postingCount, 2);
      expect(manifest.debitTotal, 50000);
      expect(manifest.creditTotal, 50000);

      // Extract and verify staged database internal consistency
      final extractDir = await Directory.systemTemp.createTemp('step5_snap_verify_');
      try {
        final staged = await BackupFileService.instance.extractPackage(
          packageFile: pkgFile,
          stagingDir: extractDir,
        );

        final stagedDb = await openStagedDatabase(staged.stagedDbFile.path);
        final stagedEvents = await stagedDb.query(TablesV24.economicEvents);
        expect(stagedEvents.length, 1);
        expect(stagedEvents.first['id'], equals('evt_snap_pre_01'));

        // Post-snapshot write is NOT in snapshot
        expect(stagedEvents.any((e) => e['id'] == 'evt_snap_post_02'), isFalse);

        await CanonicalBackupValidator.validateStagedDatabase(stagedDb, staged.manifest);
        await stagedDb.close();
      } finally {
        await extractDir.delete(recursive: true);
      }

      await db.close();
    });

    test('5.5. Backup failure cleanly handled, gate remains open, and staging artifacts pruned', () async {
      final db = await AppDatabase.instance.database;

      // Seed an account
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_fail_test_01',
        'name': 'Resilience Test Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // Simulate a failure during snapshot generation by passing a closed database connection
      // and empty dummy fallback file
      final dummyDbFile = File(p.join(tempDir.path, 'empty_dummy.db'));
      await dummyDbFile.writeAsString(''); // 0-byte file
      final dummyDb = await openDatabase(dummyDbFile.path);
      await dummyDb.close(); // Closed DB connection causes VACUUM INTO to fail

      await expectLater(
        () => BackupService.instance.createBackupPackage(
          sourceDb: dummyDb,
          sourceDbPath: dummyDbFile.path,
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Invariants following failure:
      // 1. Primary database remains fully operational
      final accounts = await db.query(TablesV24.accounts, where: 'id = ?', whereArgs: ['acc_fail_test_01']);
      expect(accounts.length, 1);

      // 2. Gate remains OPEN and operational
      expect(gate.isOpen, isTrue);
      expect(gate.activeOperations, 0);

      // 3. Coordinator state returned to active
      expect(DatabaseLifecycleCoordinator.instance.currentState, equals(DatabaseLifecycleState.active));

      // 4. Staging directories are pruned per the existing cleanup contract (lines 220-222)
      final tempEntries = tempDir.parent.listSync();
      final danglingStages = tempEntries
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('spendx_backup_stage_'))
          .toList();
      expect(danglingStages, isEmpty);

      await db.close();
    });

    test('5.6. Lock and resource reconciliation: counts return to expected baseline with zero leaks', () async {
      final db = await AppDatabase.instance.database;

      // Run multiple concurrent operations (foreground, background tasks, backup)
      final packagePath = p.join(tempDir.path, 'step5_reconciliation.spendx');
      await Future.wait([
        db.query(TablesV24.accounts),
        taskQueue.run('task_rec_1', () async => await db.query(TablesV24.accounts)),
        taskQueue.run('task_rec_2', () async => await db.query(TablesV24.accounts)),
        BackupService.instance.createBackupPackage(outputFile: File(packagePath)),
      ]);

      // Assertions:
      // 1. Baseline reader count matches exactly the single foreground lease held by gate
      expect(mockLockService.readersCount, 1);
      expect(mockLockService.activeForegroundLeaseToken, isNotNull);

      // 2. No leaked background tickets
      expect(mockLockService.activeTickets.isEmpty, isTrue);

      // 3. Exclusive restore was never requested
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      // 4. Task queue and gate active operations returned to zero
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.activeOperations, 0);

      // 5. Coordinator returned to active state
      expect(DatabaseLifecycleCoordinator.instance.currentState, equals(DatabaseLifecycleState.active));

      await db.close();
    });

    test('5.7. WAL checkpoint behavior: PRAGMA wal_checkpoint(TRUNCATE) status inspection & VACUUM INTO resilience', () async {
      final db = await AppDatabase.instance.database;

      // Ensure WAL journal mode and disable auto-checkpoint so frames remain in WAL file
      await db.rawQuery('PRAGMA journal_mode = WAL;');
      await db.execute('PRAGMA wal_autocheckpoint = 0;');

      // Seed baseline accounts
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_wal_src',
        'name': 'WAL Source',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.accounts, {
        'id': 'acc_wal_dst',
        'name': 'WAL Dest',
        'account_type': 'asset',
        'subtype': 'savings',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // Insert a new balanced transaction on the primary connection (committed into WAL file)
      await seedBalancedTransaction(
        db: db,
        eventId: 'evt_wal_uncheckpointed_01',
        amountRupees: 990.0,
        fromAccountId: 'acc_wal_src',
        toAccountId: 'acc_wal_dst',
      );

      // Verify PRAGMA wal_checkpoint returns status columns [busy, log, checkpointed]
      final cpRows = await db.rawQuery('PRAGMA wal_checkpoint(PASSIVE);');
      expect(cpRows, isNotEmpty);
      expect(cpRows.first.keys, containsAll(['busy', 'log', 'checkpointed']));

      // Execute backup creation using the real BackupService
      // Notice: BackupService executes `await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');`
      // but ignores the returned status in a try/catch block.
      final packagePath = p.join(tempDir.path, 'step5_wal_checkpoint_resilience.spendx');
      final (pkgFile, manifest) = await BackupService.instance.createBackupPackage(
        outputFile: File(packagePath),
      );

      // Verification: VACUUM INTO produced a valid, point-in-time consistent snapshot
      // including the event committed in the WAL!
      expect(manifest.canonicalEventCount, 1);
      expect(manifest.postingCount, 2);
      expect(manifest.debitTotal, 99000);
      expect(manifest.creditTotal, 99000);

      final extractDir = await Directory.systemTemp.createTemp('step5_wal_extract_');
      try {
        final staged = await BackupFileService.instance.extractPackage(
          packageFile: pkgFile,
          stagingDir: extractDir,
        );
        final stagedDb = await openStagedDatabase(staged.stagedDbFile.path);
        final events = await stagedDb.query(TablesV24.economicEvents);
        expect(events.length, 1);
        expect(events.first['id'], equals('evt_wal_uncheckpointed_01'));

        await CanonicalBackupValidator.validateStagedDatabase(stagedDb, staged.manifest);
        await stagedDb.close();
      } finally {
        await extractDir.delete(recursive: true);
      }

      await db.close();
    });

    test('5.8. Fail-closed remediation: VACUUM INTO failure cleanly aborts without unsafe physical copy', () async {
      final db = await AppDatabase.instance.database;
      final dbPath = await AppDatabase.instance.getDatabasePath();

      // Ensure WAL journal mode and disable auto-checkpoint so frames accumulate in WAL
      await db.rawQuery('PRAGMA journal_mode = WAL;');
      await db.execute('PRAGMA wal_autocheckpoint = 0;');

      // Seed baseline accounts
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_fallback_src',
        'name': 'Fallback Source',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      await db.insert(TablesV24.accounts, {
        'id': 'acc_fallback_dst',
        'name': 'Fallback Dest',
        'account_type': 'asset',
        'subtype': 'savings',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });

      // Commit a new transaction on the primary database (committed only into WAL file)
      await seedBalancedTransaction(
        db: db,
        eventId: 'evt_pinned_in_wal_01',
        amountRupees: 750.0,
        fromAccountId: 'acc_fallback_src',
        toAccountId: 'acc_fallback_dst',
      );

      // Verify event is visible on live database connection
      final liveEvents = await db.query(TablesV24.economicEvents);
      expect(liveEvents.any((e) => e['id'] == 'evt_pinned_in_wal_01'), isTrue);

      // Inject VACUUM INTO failure by wrapping db in FailingVacuumGatedDatabase
      final gatedDb = db as GatedDatabase;
      final failingDb = FailingVacuumGatedDatabase(
        gatedDb.rawDb,
        gate,
        shouldFailVacuum: true,
      );

      final packagePath = p.join(tempDir.path, 'step5_fallback_remediated.spendx');
      final packageFile = File(packagePath);

      // 1. Injected VACUUM INTO failure aborts backup creation with BackupValidationException
      await expectLater(
        () => BackupService.instance.createBackupPackage(
          sourceDb: failingDb,
          sourceDbPath: dbPath,
          outputFile: packageFile,
        ),
        throwsA(isA<BackupValidationException>()),
      );

      // 2. No .spendx package is reported as successfully created
      expect(await packageFile.exists(), isFalse);

      // 3. The unsafe physical-copy fallback is never executed:
      // A committed WAL transaction is NOT presented as a successful but incomplete backup.

      // 4. The primary database remains fully usable after failure
      final accounts = await db.query(TablesV24.accounts);
      expect(accounts.length, greaterThanOrEqualTo(2));
      final eventsAfter = await db.query(TablesV24.economicEvents);
      expect(eventsAfter.any((e) => e['id'] == 'evt_pinned_in_wal_01'), isTrue);

      // 5. The coordinator and gate return to their correct states
      expect(gate.isOpen, isTrue);
      expect(gate.activeOperations, 0);
      expect(DatabaseLifecycleCoordinator.instance.currentState, equals(DatabaseLifecycleState.active));

      // 6. Temporary staging artifacts are cleaned up safely
      final tempEntries = tempDir.parent.listSync();
      final danglingStages = tempEntries
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('spendx_backup_stage_'))
          .toList();
      expect(danglingStages, isEmpty);

      // 7. A subsequent backup attempt succeeds when VACUUM INTO is restored
      final restoredDb = FailingVacuumGatedDatabase(
        gatedDb.rawDb,
        gate,
        shouldFailVacuum: false, // VACUUM INTO restored
      );

      final (recoveredPkg, manifest) = await BackupService.instance.createBackupPackage(
        sourceDb: restoredDb,
        sourceDbPath: dbPath,
        outputFile: packageFile,
      );

      expect(await recoveredPkg.exists(), isTrue);
      expect(manifest.canonicalEventCount, 1);
      expect(manifest.postingCount, 2);
      expect(manifest.debitTotal, 75000);
      expect(manifest.creditTotal, 75000);

      // Staged database validation passes completely on the recovered backup
      final extractDir = await Directory.systemTemp.createTemp('step5_recovered_extract_');
      try {
        final staged = await BackupFileService.instance.extractPackage(
          packageFile: recoveredPkg,
          stagingDir: extractDir,
        );
        final stagedDb = await openStagedDatabase(staged.stagedDbFile.path);
        final stagedEvents = await stagedDb.query(TablesV24.economicEvents);
        expect(stagedEvents.length, 1);
        expect(stagedEvents.first['id'], equals('evt_pinned_in_wal_01'));

        await CanonicalBackupValidator.validateStagedDatabase(stagedDb, staged.manifest);
        await stagedDb.close();
      } finally {
        await extractDir.delete(recursive: true);
      }

      await db.close();
    });
  });
}
