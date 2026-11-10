import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

/// Configurable mock of PlatformProcessLockService for testing drain, contention, and failure states.
class Step3MockProcessLockService implements PlatformProcessLockService {
  int acquireForegroundCount = 0;
  int releaseForegroundCount = 0;
  String? activeForegroundLeaseToken;

  int ticketCounter = 0;
  final Map<String, Map<String, dynamic>> activeTickets = {};
  int readersCount = 0;

  bool isRestoreExclusiveHeld = false;
  bool failNextReleaseForeground = false;
  bool failNextBeginExclusiveRestore = false;

  final List<String> eventLog = [];

  @override
  MethodChannel get channel => const MethodChannel('spendx/process_lock');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    eventLog.add('acquireForegroundLease:$engineId');
    if (isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException('Restore active; admission closed');
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
    if (failNextReleaseForeground) {
      failNextReleaseForeground = false;
      return false;
    }
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
    if (isRestoreExclusiveHeld) {
      throw const DatabaseAdmissionClosedException('Restore active; admission closed');
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
    if (failNextBeginExclusiveRestore) {
      failNextBeginExclusiveRestore = false;
      throw const RestoreLockTimeoutException('Contention timeout acquiring exclusive lock');
    }
    if (readersCount > 0) {
      throw StateError('Cannot acquire exclusive restore lock while readersCount ($readersCount) > 0');
    }
    isRestoreExclusiveHeld = true;
    return 'restore_token_step3';
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
      'state': isRestoreExclusiveHeld ? 'EXCLUSIVE_HELD' : 'OPEN',
      'activeReadersCount': readersCount,
      'activeTicketsCount': activeTickets.length,
      'hasForegroundLease': activeForegroundLeaseToken != null,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Step3MockProcessLockService mockLockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue taskQueue;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_step3_test_');
    final dbFile = p.join(tempDir.path, 'spendx_step3.db');
    AppDatabase.setTestDatabasePath(dbFile);

    mockLockService = Step3MockProcessLockService();
    PlatformProcessLockService.instanceForTesting = mockLockService;

    gate = DatabaseAccessGate(processLockService: mockLockService);
    taskQueue = TrackedDatabaseTaskQueue(gate: gate);
    gate.attachTaskQueue(taskQueue);

    DatabaseAccessGate.instanceForTesting = gate;
  });

  tearDown(() async {
    PlatformProcessLockService.instanceForTesting = null;
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
    AppDatabase.setTestDatabasePath(null);

    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Milestone 4.5B — Step 3: Required Sequence (Happy Path Transition)', () {
    test('3.1. Full 12-step transition from OPEN to EXCLUSIVE and return to OPEN', () async {
      // 1. Begin with gate in OPEN state and open the real database connection
      final db = await AppDatabase.instance.database;
      expect(gate.isOpen, isTrue);

      // Verify initial read succeeds and establishes foreground lease
      await db.query('accounts');
      expect(gate.nativeLeaseToken, isNotNull);
      expect(mockLockService.readersCount, 1);

      // 2. Start multiple admitted operations, including a deliberately blocked operation
      final blockedCompleter = Completer<void>();
      var blockedOpFinished = false;

      final futureBlockedOp = gate.admit(() async {
        await blockedCompleter.future; // Deliberate hold inside active admission
        blockedOpFinished = true;
      });

      // Quick fast concurrent query on real SQLite
      await db.query('accounts');

      // 3. Start a tracked background database task
      final backgroundTaskCompleter = Completer<void>();
      var backgroundTaskFinished = false;

      final futureTrackedTask = taskQueue.run('background_sync', () async {
        await backgroundTaskCompleter.future;
        backgroundTaskFinished = true;
      });

      expect(gate.activeOperations, greaterThanOrEqualTo(1));
      expect(taskQueue.activeTaskCount, 1);

      // 4. Initiate closeAdmissionAndDrain() asynchronously
      final drainFuture = gate.closeAdmissionAndDrain(timeout: const Duration(seconds: 3));
      expect(gate.isDraining, isTrue);

      // 5. Verify new database operations are rejected immediately after admission closes
      await expectLater(
        () => db.query('accounts'),
        throwsA(isA<DatabaseGateClosedException>()),
      );
      await expectLater(
        () => taskQueue.run('rejected_new_task', () async {}),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      // 6. Verify already-admitted operations finish within drain timeout
      // Let the tracked background task complete
      backgroundTaskCompleter.complete();
      await futureTrackedTask;
      expect(backgroundTaskFinished, isTrue);
      expect(taskQueue.activeTaskCount, 0);

      // Let the blocked operation complete
      blockedCompleter.complete();
      await futureBlockedOp;
      expect(blockedOpFinished, isTrue);

      // 7. Await drain future completion
      await drainFuture;

      // 8. Verify native foreground lease is released and readers count is 0
      expect(gate.isClosed, isTrue);
      expect(gate.nativeLeaseToken, isNull);
      expect(gate.activeOperations, 0);
      expect(mockLockService.readersCount, 0);

      // 9. Acquire exclusive restore ownership
      final restoreToken = await mockLockService.beginExclusiveRestore();
      expect(restoreToken, isNotEmpty);
      expect(mockLockService.isRestoreExclusiveHeld, isTrue);

      // 10. Verify no database operation can reach primary database while restore is held
      await expectLater(
        () => db.query('accounts'),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      // 11. Complete restore-lock lifecycle and reopen admission
      await mockLockService.completeExclusiveRestore(restoreToken);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      await gate.reopenAdmission();
      expect(gate.isOpen, isTrue);
      expect(gate.nativeLeaseToken, isNotNull);
      expect(mockLockService.readersCount, 1);

      // 12. Verify normal foreground reads and writes work again on real SQLite
      final now = DateTime.now().toIso8601String();
      final insertedId = await db.insert('accounts', {
        'id': 'acc_step3_recovered',
        'name': 'Recovered Account',
        'account_type': 'asset',
        'subtype': 'checking',
        'currency': 'INR',
        'created_at': now,
        'updated_at': now,
      });
      expect(insertedId, greaterThan(0));

      final rows = await db.query('accounts', where: "id = 'acc_step3_recovered'");
      expect(rows.length, 1);
      expect(rows.first['name'], 'Recovered Account');

      await db.close();
    });
  });

  group('Milestone 4.5B — Step 3: Required Failure Scenarios', () {
    test('3.2. Failure Scenario 1: Admitted operation does not finish before drain timeout', () async {
      final db = await AppDatabase.instance.database;
      await db.query('accounts');
      expect(gate.nativeLeaseToken, isNotNull);

      // Start an operation that never completes within the timeout
      final neverCompleter = Completer<void>();
      final unawaitedOp = gate.admit(() async {
        await neverCompleter.future;
      });

      expect(gate.activeOperations, 1);

      // Drain with a tight 50ms timeout
      await expectLater(
        () => gate.closeAdmissionAndDrain(timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );

      // Gate must NOT be marked closed
      expect(gate.isClosed, isFalse);
      // Native lease was NOT released because operations were not quiesced
      expect(gate.nativeLeaseToken, isNotNull);
      expect(mockLockService.readersCount, 1);

      // Clean up the stalled operation
      neverCompleter.complete();
      await unawaitedOp;
      expect(gate.activeOperations, 0);

      await db.close();
    });

    test('3.3. Failure Scenario 2: Tracked task fails while draining without deadlocking or crashing isolate', () async {
      final db = await AppDatabase.instance.database;
      await db.query('accounts');

      var taskFailedCaught = false;

      // Start a tracked task that throws an error after a short delay
      taskQueue.runTracked(
        'failing_background_task',
        () async {
          await Future.delayed(const Duration(milliseconds: 20));
          throw FormatException('Simulated background task failure during drain');
        },
        onError: (e, st) {
          taskFailedCaught = true;
        },
      );

      expect(taskQueue.activeTaskCount, 1);

      // Drain should wait for the task, handle the exceptional completion, and finish cleanly
      await gate.closeAdmissionAndDrain(timeout: const Duration(seconds: 2));

      expect(taskFailedCaught, isTrue);
      expect(taskQueue.activeTaskCount, 0);
      expect(gate.isClosed, isTrue);
      expect(gate.nativeLeaseToken, isNull);
      expect(mockLockService.readersCount, 0);

      await db.close();
    });

    test('3.4. Failure Scenario 3: Two drain requests arrive concurrently and coalesce safely', () async {
      final db = await AppDatabase.instance.database;
      await db.query('accounts');
      expect(mockLockService.readersCount, 1);

      // Invoke closeAdmissionAndDrain simultaneously
      await Future.wait([
        gate.closeAdmissionAndDrain(timeout: const Duration(seconds: 2)),
        gate.closeAdmissionAndDrain(timeout: const Duration(seconds: 2)),
      ]);

      expect(gate.isClosed, isTrue);
      expect(gate.nativeLeaseToken, isNull);
      // Native release was called exactly once despite 2 simultaneous calls
      expect(mockLockService.releaseForegroundCount, 1);
      expect(mockLockService.readersCount, 0);

      await db.close();
    });

    test('3.5. Failure Scenario 4: New tracked task attempted after admission closes is rejected', () async {
      final db = await AppDatabase.instance.database;
      await db.query('accounts');
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);

      // 1. run() throws DatabaseGateClosedException
      await expectLater(
        () => taskQueue.run('late_task_run', () async {}),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      // 2. runTracked() silently ignores and does not enqueue
      taskQueue.runTracked('late_task_tracked', () async {});
      expect(taskQueue.activeTaskCount, 0);

      await db.close();
    });

    test('3.6. Failure Scenario 5: Native shared lease release failure prevents gate from marking closed', () async {
      final db = await AppDatabase.instance.database;
      await db.query('accounts');
      expect(gate.nativeLeaseToken, isNotNull);

      // Simulate native platform failure when releasing the lease
      mockLockService.failNextReleaseForeground = true;

      await expectLater(
        () => gate.closeAdmissionAndDrain(timeout: const Duration(seconds: 2)),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Failed to release native foreground lease'),
        )),
      );

      // Gate must not claim to be closed
      expect(gate.isClosed, isFalse);
      expect(gate.state, isNot(equals(GateState.closed)));

      await db.close();
    });

    test('3.7. Failure Scenario 6: Exclusive restore acquisition fails or times out without corrupting manager', () async {
      final db = await AppDatabase.instance.database;
      await db.query('accounts');
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);

      // Simulate contention / timeout in native lock manager
      mockLockService.failNextBeginExclusiveRestore = true;

      await expectLater(
        () => mockLockService.beginExclusiveRestore(),
        throwsA(isA<RestoreLockTimeoutException>()),
      );

      // Restore lock was not granted
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      // Reopen gate recovers gracefully
      await gate.reopenAdmission();
      expect(gate.isOpen, isTrue);
      expect(gate.nativeLeaseToken, isNotNull);
      expect(mockLockService.readersCount, 1);

      await db.close();
    });

    test('3.8. Failure Scenario 7: Reopening attempted before exclusive ownership released is rejected', () async {
      final db = await AppDatabase.instance.database;
      await db.query('accounts');
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);

      // Native restore acquires exclusive ownership
      final restoreToken = await mockLockService.beginExclusiveRestore();
      expect(mockLockService.isRestoreExclusiveHeld, isTrue);

      // Attempting to reopen admission while restore is held must throw DatabaseAdmissionClosedException
      await expectLater(
        () => gate.reopenAdmission(),
        throwsA(isA<DatabaseAdmissionClosedException>()),
      );

      // Gate remains closed
      expect(gate.isOpen, isFalse);
      expect(gate.nativeLeaseToken, isNull);

      // Now release exclusive ownership
      await mockLockService.completeExclusiveRestore(restoreToken);
      expect(mockLockService.isRestoreExclusiveHeld, isFalse);

      // Now reopen admission succeeds
      await gate.reopenAdmission();
      expect(gate.isOpen, isTrue);
      expect(gate.nativeLeaseToken, isNotNull);
      expect(mockLockService.readersCount, 1);

      await db.close();
    });
  });

  group('Milestone 4.5B — Step 3: Required Invariants Verification', () {
    test('3.9. Invariants: zero permit leaks, strict rejection, and baseline reconciliation', () async {
      final db = await AppDatabase.instance.database;

      // 1. OPEN baseline
      await db.query('accounts');
      expect(gate.activeOperations, 0);
      expect(mockLockService.readersCount, 1);

      // 2. Multiple concurrent operations
      final f1 = db.query('accounts');
      final f2 = db.query('accounts');
      final f3 = db.query('accounts');
      await Future.wait([f1, f2, f3]);
      expect(gate.activeOperations, 0);

      // 3. Drain and closure
      await gate.closeAdmissionAndDrain();
      expect(gate.activeOperations, 0);
      expect(mockLockService.readersCount, 0);
      expect(gate.isClosed, isTrue);

      // 4. Invariant: Exclusive restore ownership cannot be granted while readersCount > 0
      mockLockService.readersCount = 1; // Artificially inject reader
      await expectLater(
        () => mockLockService.beginExclusiveRestore(),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Cannot acquire exclusive restore lock while readersCount'),
        )),
      );
      mockLockService.readersCount = 0; // Restore baseline

      // 5. Invariant: Exclusive restore granted when readersCount is 0
      final token = await mockLockService.beginExclusiveRestore();
      expect(mockLockService.isRestoreExclusiveHeld, isTrue);

      // 6. Complete and reopen
      await mockLockService.completeExclusiveRestore(token);
      await gate.reopenAdmission();

      // 7. Verified final baseline
      expect(gate.isOpen, isTrue);
      expect(gate.activeOperations, 0);
      expect(mockLockService.readersCount, 1);

      await db.close();
    });
  });
}
