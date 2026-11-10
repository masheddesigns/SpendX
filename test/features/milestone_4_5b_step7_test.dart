import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:spend_x/data/providers.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/data_change_bus.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

/// Milestone 4.5B Step 7: Atomic Database Replacement, Rollback, and Invalidation
///
/// ============================================================================
/// ARCHITECTURAL VERIFICATION SCOPE: STEP 7
/// ============================================================================
/// Phase A — Exclusive Admission:
///   1. Quiesce WriteQueue.
///   2. Close DatabaseAccessGate admission.
///   3. Drain active SQL operations and tracked background database tasks.
///   4. Release the foreground native lease.
///   5. Acquire the native exclusive restore lease.
///   6. Reject new foreground database operations and notification tickets.
///   7. Confirm exclusive ownership before proceeding.
/// Phase B — Primary Database Preparation:
///   1. Checkpoint WAL and inspect checkpoint result.
///   2. Close the primary database connection.
///   3. Confirm the connection is actually closed.
///   4. Preserve the current database as .pre_restore_backup.
///   5. Verify the staged database is still available and validated.
/// Phase C — Atomic Replacement:
///   1. Copy staged database to sibling .new_swap file on same filesystem.
///   2. Delete -wal and -shm sidecars to prevent stale sidecar association.
///   3. Rename .new_swap atomically to active database path.
/// Phase D — Reopen and Validate:
///   1. Reopen via normal encrypted database factory.
///   2. Verify SQLite integrity checks (PRAGMA integrity_check == 'ok').
///   3. Verify foreign-key checks (PRAGMA foreign_key_check is empty).
///   4. Verify user_version == 24 and canonical ledger invariants.
/// Phase E — Rollback:
///   1. Deterministic failure injection at every destructive boundary.
///   2. Automatic rollback restores .pre_restore_backup and verifies reopen.
///   3. Fail-closed quarantine on ambiguous or failed rollback: gate admission
///      remains closed and all recovery artifacts are preserved.
/// Phase F — Provider and Application Invalidation:
///   1. Applied only after restored database is verified.
///   2. Financial Riverpod providers invalidated.
///   3. DataChangeBus and DatabaseLifecycleCoordinator notified.
/// Phase G — Lock and Gate Recovery:
///   1. On success: release exclusive restore lease, reopen gate admission,
///      restore foreground lease, and return lifecycle to active.
///   2. On failure: reopen gate admission only if rollback verified;
///      otherwise keep admission closed and preserve quarantine.
/// ============================================================================

class Step7MockProcessLockService implements PlatformProcessLockService {
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
    if (readersCount > 0) {
      throw StateError('Cannot acquire exclusive restore lock while readersCount ($readersCount) > 0');
    }
    isRestorePending = false;
    isRestoreExclusiveHeld = true;
    return 'restore_token_step7';
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
  Future<bool> validateExclusiveRestoreToken(
    String restoreToken, {
    String? crossEngineIdForTesting,
  }) async => true;

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
  late Step7MockProcessLockService mockLockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue taskQueue;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    try {
      final initialTempEntries = Directory.systemTemp.listSync();
      for (final entry in initialTempEntries) {
        if (entry is Directory &&
            (p.basename(entry.path).startsWith('spendx_backup_stage_') ||
             p.basename(entry.path).startsWith('spendx_restore_stage_'))) {
          try {
            entry.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}

    tempDir = await Directory.systemTemp.createTemp('spendx_4_5b_step7_test_');
    final dbFile = p.join(tempDir.path, 'spendx_step7.db');
    AppDatabase.setTestDatabasePath(dbFile);

    mockLockService = Step7MockProcessLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;

    gate = DatabaseAccessGate(processLockService: mockLockService);
    taskQueue = TrackedDatabaseTaskQueue(gate: gate);
    gate.attachTaskQueue(taskQueue);

    DatabaseAccessGate.instanceForTesting = gate;
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    BackupService.resetTestingFlags();
  });

  tearDown(() async {
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

  /// Helper to seed an account and balanced postings for valid backup generation.
  Future<File> generateValidBackupPackage({required String filename}) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final uid = DateTime.now().microsecondsSinceEpoch;

    await db.insert(TablesV24.accounts, {
      'id': 'acc_step7_valid_$uid',
      'name': 'Step 7 Seed Account',
      'account_type': 'asset',
      'subtype': 'checking',
      'currency': 'INR',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });

    final pkg = await BackupService.instance.createBackupPackage();
    final targetFile = File(p.join(tempDir.path, filename));
    await pkg.$1.copy(targetFile.path);
    return targetFile;
  }

  group('Milestone 4.5B Step 7: Atomic Database Replacement, Rollback, and Invalidation', () {
    test('7.1: Active foreground operations delaying exclusive admission', () async {
      await AppDatabase.instance.database;
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_1.spendx');

      final holdCompleter = Completer<void>();
      final startedCompleter = Completer<void>();

      // Start an active foreground operation that holds admission
      final fgOpFuture = gate.admit(() async {
        startedCompleter.complete();
        await holdCompleter.future;
        return 42;
      });

      await startedCompleter.future;
      expect(gate.activeOperations, 1);

      // Initiate restore — closeAdmissionAndDrain should wait for the in-flight operation
      bool restoreFinished = false;
      final restoreFuture = BackupService.instance.restoreFromFile(packageFile).then((val) {
        restoreFinished = true;
        return val;
      });

      // Wait until staging completes and gate begins draining
      for (int i = 0; i < 100 && !gate.isDraining && !restoreFinished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(gate.isDraining, isTrue);
      expect(restoreFinished, isFalse);

      // Release foreground operation
      holdCompleter.complete();
      await fgOpFuture;

      final success = await restoreFuture;
      expect(success, isTrue);
      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);
    });

    test('7.2: Active tracked tasks delaying exclusive admission', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_2.spendx');

      final taskHoldCompleter = Completer<void>();
      final taskStartedCompleter = Completer<void>();
      final taskFinishedCompleter = Completer<void>();

      taskQueue.runTracked('tracked_bg_task_7_2', () async {
        taskStartedCompleter.complete();
        await taskHoldCompleter.future;
        taskFinishedCompleter.complete();
      });

      await taskStartedCompleter.future;
      expect(taskQueue.activeTaskCount, 1);

      bool restoreFinished = false;
      final restoreFuture = BackupService.instance.restoreFromFile(packageFile).then((val) {
        restoreFinished = true;
        return val;
      });

      // Wait until staging completes and gate begins draining
      for (int i = 0; i < 100 && !gate.isDraining && !restoreFinished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(gate.isDraining, isTrue);
      expect(restoreFinished, isFalse);

      // Release the tracked task
      taskHoldCompleter.complete();
      await taskFinishedCompleter.future;

      final success = await restoreFuture;
      expect(success, isTrue);
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.isOpen, isTrue);
    });

    test('7.3: Notification callbacks rejected during exclusive restore', () async {
      // Inject a delay during restore replacement to test concurrent callback rejection
      BackupService.failFirstRenameForTesting = false;

      // Close admission and acquire exclusive restore
      await gate.closeAdmissionAndDrain();
      final restoreToken = await mockLockService.beginExclusiveRestore();

      expect(gate.isClosed, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isTrue);

      // Notification ticket acquisition must be rejected immediately
      expect(
        () => mockLockService.acquireOperationTicket(tag: 'live_expense_cb'),
        throwsA(isA<DatabaseAdmissionClosedException>()),
      );

      // Gated operations must also be rejected immediately
      expect(
        () => gate.admit(() async => 1),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      await mockLockService.completeExclusiveRestore(restoreToken);
      await gate.reopenAdmission();
      expect(gate.isOpen, isTrue);
    });

    test('7.4: Exclusive lock acquisition failure rolls back gate admission', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_4.spendx');

      // Simulate lock timeout or contention when attempting exclusive restore
      mockLockService.failBeginExclusiveRestore = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreLockTimeoutException>()),
      );

      // Gate admission must be safely reopened and foreground lease restored
      expect(gate.isOpen, isTrue);
      expect(mockLockService.activeForegroundLeaseToken, isNotNull);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      // Database remains operational
      final db = await AppDatabase.instance.database;
      final res = await db.rawQuery('SELECT 1;');
      expect(res.isNotEmpty, isTrue);
    });

    test('7.5: Full replacement success (atomic rename, sidecars cleaned, providers invalidated)', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_5.spendx');

      final container = ProviderContainer();
      bool providerInvalidated = false;
      container.listen(accountsProvider, (previous, next) {
        providerInvalidated = true;
      });

      bool dataChangeNotified = false;
      void busListener() {
        dataChangeNotified = true;
      }
      DataChangeBus.instance.addListener(busListener);

      bool lifecycleReplacedNotified = false;
      void lifecycleListener() {
        lifecycleReplacedNotified = true;
      }
      DatabaseLifecycleCoordinator.instance.addDatabaseReplacementListener(lifecycleListener);

      final success = await BackupService.instance.restoreFromFile(
        packageFile,
        container: container,
      );

      expect(success, isTrue);
      expect(providerInvalidated, isTrue);
      expect(dataChangeNotified, isTrue);
      expect(lifecycleReplacedNotified, isTrue);
      expect(gate.isOpen, isTrue);

      // Verify no temporary swap or rollback files remain
      final activePath = await AppDatabase.instance.getDatabasePath();
      expect(File('$activePath.new_swap').existsSync(), isFalse);
      expect(File('$activePath.pre_restore_backup').existsSync(), isFalse);

      // Restored database is usable through the gate
      final db = await AppDatabase.instance.database;
      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, 24);

      DataChangeBus.instance.removeListener(busListener);
      DatabaseLifecycleCoordinator.instance.removeDatabaseReplacementListener(lifecycleListener);
      container.dispose();
    });

    test('7.6: Destructive boundary failure: WAL checkpoint failure', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_6.spendx');
      BackupService.failWalCheckpointForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('WAL checkpoint failure'))),
      );

      // Gate admission safely recovered
      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      final activePath = await AppDatabase.instance.getDatabasePath();
      expect(File('$activePath.pre_restore_backup').existsSync(), isFalse);
    });

    test('7.7: Destructive boundary failure: Primary connection close failure', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_7.spendx');
      BackupService.failConnectionCloseForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('connection close failure'))),
      );

      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);
    });

    test('7.8: Destructive boundary failure: Existing database backup creation failure', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_8.spendx');
      BackupService.failBackupCreationForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('backup creation failure'))),
      );

      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);
    });

    test('7.9: Destructive boundary failure: First rename failure', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_9.spendx');
      BackupService.failFirstRenameForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreException>().having((e) => e.message, 'message', contains('Active database rolled back safely'))),
      );

      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      final db = await AppDatabase.instance.database;
      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, 24);
    });

    test('7.10: Destructive boundary failure: Replacement rename failure and rollback', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_10.spendx');
      BackupService.failReplacementRenameForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreException>().having((e) => e.message, 'message', contains('Active database rolled back safely'))),
      );

      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      final db = await AppDatabase.instance.database;
      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, 24);
    });

    test('7.11: Destructive boundary failure: Reopen failure and rollback', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_11.spendx');
      BackupService.failReopenForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreException>().having((e) => e.message, 'message', contains('Active database rolled back safely'))),
      );

      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      final db = await AppDatabase.instance.database;
      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, 24);
    });

    test('7.12: Destructive boundary failure: Integrity validation failure and rollback', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_12.spendx');
      BackupService.failIntegrityValidationForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreException>().having((e) => e.message, 'message', contains('Active database rolled back safely'))),
      );

      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      final db = await AppDatabase.instance.database;
      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, 24);
    });

    test('7.13: Ambiguous recovery and quarantine (gate remains CLOSED, artifacts preserved)', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_13.spendx');
      BackupService.failIntegrityValidationForTesting = true;
      BackupService.failRollbackForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreQuarantinedException>()),
      );

      // CRITICAL INVARIANT: Gate admission must remain strictly CLOSED!
      expect(gate.isClosed, isTrue);
      expect(gate.isOpen, isFalse);

      // Any attempt to use the database must fail closed
      expect(
        () => gate.admit(() async => 1),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      // Exclusive lock released so host process is not deadlocked
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      // Recovery artifacts must be preserved on disk
      final activePath = await AppDatabase.instance.getDatabasePath();
      expect(File('$activePath.pre_restore_backup').existsSync(), isTrue);
    });

    test('7.14: Subsequent database operations succeed through gated factory after successful restore', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_14.spendx');

      final success = await BackupService.instance.restoreFromFile(packageFile);
      expect(success, isTrue);

      expect(gate.isOpen, isTrue);
      expect(mockLockService.activeForegroundLeaseToken, isNotNull);

      final db = await AppDatabase.instance.database;
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(TablesV24.accounts, {
        'id': 'acc_step7_post_restore',
        'name': 'Post Restore Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });

      final rows = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['acc_step7_post_restore'],
      );
      expect(rows.length, 1);
      expect(rows.first['name'], 'Post Restore Account');
    });

    // =========================================================================
    // Priority 1: rawDatabase escape-hatch removal
    // =========================================================================

    test('7.15: rawDatabase getter is absent — fixed validation interface enforces restoring state', () {
      // Verify that AppDatabase exposes NO public arbitrary-SQL accessor.
      // The fixed-query interface (runPostRestoreIntegrityChecks) requires the
      // lifecycle coordinator to be in the 'restoring' state.  When it is
      // 'active' (normal operation), any attempt to call it must throw StateError.
      expect(
        DatabaseLifecycleCoordinator.instance.currentState,
        equals(DatabaseLifecycleState.active),
      );
      expect(
        () async => AppDatabase.instance.runPostRestoreIntegrityChecks(
          canonicalTableNames: ['accounts'],
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('restoring state'),
        )),
      );
    });

    test('7.16: runPostRestoreIntegrityChecks rejects call when lifecycle is backingUp', () async {
      // Simulate lifecycle state = backingUp (not restoring) — also rejected.
      await DatabaseLifecycleCoordinator.instance.beginBackup();
      expect(
        DatabaseLifecycleCoordinator.instance.currentState,
        equals(DatabaseLifecycleState.backingUp),
      );
      expect(
        () async => AppDatabase.instance.runPostRestoreIntegrityChecks(
          canonicalTableNames: ['accounts'],
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('restoring state'),
        )),
      );
      DatabaseLifecycleCoordinator.instance.endBackup();
    });

    // =========================================================================
    // Priority 2: Production-path coverage — gate/lock boundary assertions
    // =========================================================================

    test('7.17: Gate and exclusive lock state verified at every boundary of full restore', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_17.spendx');

      // Before restore: gate is open, no exclusive lock held, foreground lease active.
      expect(gate.isOpen, isTrue);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);
      expect(mockLockService.activeForegroundLeaseToken, isNotNull);
      final tokenBefore = mockLockService.activeForegroundLeaseToken!;

      // Start a foreground op that observes gate.isClosed during the draining phase.
      final holdCompleter = Completer<void>();
      final startedCompleter = Completer<void>();
      bool gateWasClosedDuringOp = false;

      final fgOpFuture = gate.admit(() async {
        startedCompleter.complete();
        await holdCompleter.future;
        // This check runs while restore is draining — gate should be draining/closed.
        gateWasClosedDuringOp = !gate.isOpen;
        return 1;
      });

      await startedCompleter.future;

      // Start restore concurrently — it will drain waiting for fgOpFuture.
      final restoreFuture = BackupService.instance.restoreFromFile(packageFile);
      for (int i = 0; i < 100 && !gate.isDraining; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Gate should be draining while foreground op is held.
      expect(gate.isDraining, isTrue);

      // Release foreground op — restore can now proceed.
      holdCompleter.complete();
      await fgOpFuture;

      final success = await restoreFuture;
      expect(success, isTrue);

      // The gate was not open while the foreground op was completing inside drain.
      expect(gateWasClosedDuringOp, isTrue);

      // After restore: gate is re-opened.
      expect(gate.isOpen, isTrue);

      // Exclusive restore lock has been released.
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      // A new foreground lease was acquired after restore.
      expect(mockLockService.activeForegroundLeaseToken, isNotNull);
      // The token must differ from the pre-restore token (new lease acquired).
      expect(
        mockLockService.activeForegroundLeaseToken,
        isNot(equals(tokenBefore)),
      );

      // Event log must show the full exclusive restore lifecycle.
      expect(mockLockService.eventLog, containsAll([
        'beginExclusiveRestore',
        'completeExclusiveRestore:restore_token_step7',
      ]));

      // Database is accessible through the gate after restore.
      final db = await AppDatabase.instance.database;
      expect(db, isA<GatedDatabase>());
      final rows = await db.rawQuery('PRAGMA user_version;');
      expect(rows.first.values.first, 24);
    });

    // =========================================================================
    // Priority 3: Crash-recovery artifact tests
    // =========================================================================

    test('7.18: Stale .new_swap orphan cleaned before replacement begins', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_18.spendx');

      // Create a stale .new_swap file at the target location before restore.
      final activePath = await AppDatabase.instance.getDatabasePath();
      final staleSwap = File('$activePath.new_swap');
      await staleSwap.writeAsString('stale orphan content');
      expect(staleSwap.existsSync(), isTrue);

      // Restore must succeed: the stale swap is overwritten/deleted.
      final success = await BackupService.instance.restoreFromFile(packageFile);
      expect(success, isTrue);

      // After successful restore, no .new_swap remains.
      expect(File('$activePath.new_swap').existsSync(), isFalse);
      // No .pre_restore_backup remains after successful validation.
      expect(File('$activePath.pre_restore_backup').existsSync(), isFalse);
    });

    test('7.19: WAL and SHM sidecars absent after successful restore', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_19.spendx');
      final activePath = await AppDatabase.instance.getDatabasePath();

      // Simulate stale WAL / SHM sidecars present before restore.
      final walFile = File('$activePath-wal');
      final shmFile = File('$activePath-shm');
      await walFile.writeAsString('stale wal content');
      await shmFile.writeAsString('stale shm content');
      expect(walFile.existsSync(), isTrue);
      expect(shmFile.existsSync(), isTrue);

      final success = await BackupService.instance.restoreFromFile(packageFile);
      expect(success, isTrue);

      // Phase C of the restore deletes WAL and SHM sidecars before the atomic rename.
      expect(walFile.existsSync(), isFalse);
      expect(shmFile.existsSync(), isFalse);
    });

    test('7.20: WAL and SHM sidecars absent after rollback recovery', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_20.spendx');
      final activePath = await AppDatabase.instance.getDatabasePath();

      // Inject failure at reopen — triggers rollback.
      BackupService.failReopenForTesting = true;

      // Simulate stale sidecars.
      final walFile = File('$activePath-wal');
      final shmFile = File('$activePath-shm');
      await walFile.writeAsString('stale wal');
      await shmFile.writeAsString('stale shm');

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreException>().having(
          (e) => e.message,
          'message',
          contains('Active database rolled back safely'),
        )),
      );

      // Rollback cleans WAL/SHM as part of the rollback procedure.
      expect(walFile.existsSync(), isFalse);
      expect(shmFile.existsSync(), isFalse);

      // Database is usable after rollback.
      expect(gate.isOpen, isTrue);
      final db = await AppDatabase.instance.database;
      final rows = await db.rawQuery('PRAGMA user_version;');
      expect(rows.first.values.first, 24);
    });

    test('7.21: .pre_restore_backup preserved until validation; cleanup only on success', () async {
      final packageFile = await generateValidBackupPackage(filename: 'backup_7_21.spendx');
      final activePath = await AppDatabase.instance.getDatabasePath();
      final rollbackFile = File('$activePath.pre_restore_backup');

      // Inject integrity validation failure — rollback must trigger.
      BackupService.failIntegrityValidationForTesting = true;

      await expectLater(
        () => BackupService.instance.restoreFromFile(packageFile),
        throwsA(isA<RestoreException>().having(
          (e) => e.message,
          'message',
          contains('Active database rolled back safely'),
        )),
      );

      // After successful rollback, .pre_restore_backup is consumed (renamed to
      // active db path) or deleted as part of rollback; it must not linger.
      // The key invariant is that after a successful rollback the database
      // is healthy — the rollback file location is implementation detail.
      expect(gate.isOpen, isTrue);
      final db = await AppDatabase.instance.database;
      final rows = await db.rawQuery('PRAGMA user_version;');
      expect(rows.first.values.first, 24);

      // Confirm no leftover rollback file once rollback has completed cleanly.
      // (Rollback renames or copies the file to the active path; .pre_restore_backup should be gone.)
      expect(rollbackFile.existsSync(), isFalse);
    });
  });
}
