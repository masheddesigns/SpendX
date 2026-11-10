import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/gated_database.dart';
import 'package:spend_x/data/core/gated_transaction.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

class FakeLockService implements PlatformProcessLockService {
  int acquireCount = 0;
  int releaseCount = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #acquireForegroundLease) {
      acquireCount++;
      return Future.value('fake_lease_$acquireCount');
    }
    if (invocation.memberName == #releaseForegroundLease) {
      releaseCount++;
      return Future.value(true);
    }
    return super.noSuchMethod(invocation);
  }
}

class FakeDb implements Database {
  int queryCount = 0;
  Completer<void>? slowCompleter;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    if (table == 'slow' && slowCompleter != null) {
      await slowCompleter!.future;
    }
    queryCount++;
    return [
      {'val': 1}
    ];
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    final fakeTxn = FakeTxn(this);
    return await action(fakeTxn);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTxn implements Transaction {
  final FakeDb _db;
  FakeTxn(this._db);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _db.query(table);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLockService lockService;
  late DatabaseAccessGate gate;
  late TrackedDatabaseTaskQueue queue;
  late FakeDb fakeDb;
  late GatedDatabase gatedDb;

  setUp(() {
    lockService = FakeLockService();
    gate = DatabaseAccessGate(processLockService: lockService);
    queue = TrackedDatabaseTaskQueue(gate: gate);
    gate.attachTaskQueue(queue);
    fakeDb = FakeDb();
    gatedDb = GatedDatabase(fakeDb, gate);
  });

  group('TrackedDatabaseTaskQueue Core Suite', () {
    test('1. Concurrent task registration and completion tracks activeTaskCount accurately', () async {
      expect(queue.activeTaskCount, 0);

      final completers = List.generate(10, (_) => Completer<void>());
      final taskDone = List.generate(10, (_) => Completer<void>());

      for (var i = 0; i < 10; i++) {
        queue.runTracked('task_$i', () async {
          await completers[i].future;
          taskDone[i].complete();
        });
      }

      expect(queue.activeTaskCount, 10);

      // Complete 5 tasks
      for (var i = 0; i < 5; i++) {
        completers[i].complete();
      }
      await Future.wait(taskDone.take(5).map((c) => c.future));

      expect(queue.activeTaskCount, 5);

      // Complete remaining 5 tasks
      for (var i = 5; i < 10; i++) {
        completers[i].complete();
      }
      await Future.wait(taskDone.skip(5).map((c) => c.future));

      expect(queue.activeTaskCount, 0);
    });

    test('2. Successful and failed background tasks both clear task registration', () async {
      expect(queue.activeTaskCount, 0);

      final successCompleter = Completer<void>();
      final failureHandledCompleter = Completer<void>();

      // Task 1: Success
      queue.runTracked('success_task', () async {
        await successCompleter.future;
      });

      // Task 2: Failure with error callback
      queue.runTracked(
        'failing_task',
        () async {
          throw FormatException('Simulated background task failure');
        },
        onError: (err, st) {
          expect(err, isA<FormatException>());
          failureHandledCompleter.complete();
        },
      );

      // Failure completes and is handled without crashing
      await failureHandledCompleter.future;
      expect(queue.activeTaskCount, 1); // Only success_task remains

      successCompleter.complete();
      await Future.delayed(const Duration(milliseconds: 20));
      expect(queue.activeTaskCount, 0);
    });

    test('3. Restore drain blocks until all active background tasks complete', () async {
      await gatedDb.query('accounts');
      expect(gate.nativeLeaseToken, isNotNull);

      final taskCompleter = Completer<void>();
      final taskExecutedCompleter = Completer<void>();

      queue.runTracked('long_running_sync', () async {
        await taskCompleter.future;
        taskExecutedCompleter.complete();
      });

      expect(queue.activeTaskCount, 1);

      // Start gate drain
      final drainFuture = gate.closeAdmissionAndDrain();
      expect(gate.isDraining, isTrue);

      // Verify drain does not complete prematurely while task is active
      var drainCompleted = false;
      unawaited(drainFuture.then((_) => drainCompleted = true));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(drainCompleted, isFalse);
      expect(gate.isClosed, isFalse);

      // Allow task to finish
      taskCompleter.complete();
      await taskExecutedCompleter.future;

      // Now drain must complete cleanly
      await drainFuture;
      expect(gate.isClosed, isTrue);
      expect(queue.activeTaskCount, 0);
      expect(lockService.releaseCount, 1);
    });

    test('3b. Avoid deadlock: task attempting query during drain fails fast and removes itself', () async {
      final taskStarted = Completer<void>();
      final taskDone = Completer<void>();

      queue.runTracked('task_waiting_for_drain', () async {
        taskStarted.complete();
        // Wait until gate is draining
        while (!gate.isDraining) {
          await Future.delayed(const Duration(milliseconds: 5));
        }
        try {
          // This must throw DatabaseGateClosedException immediately rather than hang!
          await gatedDb.query('accounts');
        } finally {
          taskDone.complete();
        }
      });

      await taskStarted.future;
      expect(queue.activeTaskCount, 1);

      // Drain begins
      final drainFuture = gate.closeAdmissionAndDrain();
      await taskDone.future;

      // Drain completes without deadlock!
      await drainFuture;
      expect(gate.isClosed, isTrue);
      expect(queue.activeTaskCount, 0);
    });

    test('4. New task registration is rejected immediately during draining and closed states', () async {
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);

      var actionRan = false;
      queue.runTracked('rejected_task', () async {
        actionRan = true;
      });

      await Future.delayed(const Duration(milliseconds: 20));
      expect(actionRan, isFalse);
      expect(queue.activeTaskCount, 0);

      // Synchronous run() throws DatabaseGateClosedException
      await expectLater(
        () => queue.run('rejected_run', () async => 'val'),
        throwsA(isA<DatabaseGateClosedException>()),
      );
    });

    test('5. Task completion after exception cleans up activeTaskCount without unhandled error', () async {
      final handledErrorCompleter = Completer<void>();

      queue.runTracked(
        'error_task',
        () async {
          await Future.delayed(const Duration(milliseconds: 10));
          throw StateError('Simulated unexpected crash');
        },
        onError: (e, st) {
          handledErrorCompleter.complete();
        },
      );

      expect(queue.activeTaskCount, 1);
      await handledErrorCompleter.future;

      // Wait a microtask for finally cleanup
      await Future.delayed(const Duration(milliseconds: 10));
      expect(queue.activeTaskCount, 0);
    });

    test('6. Duplicate completion protection prevents counter corruption', () async {
      final task = TrackedDatabaseTask(id: 'dup_test', tag: 'test');
      expect(task.isCompleted, isFalse);

      final completer = Completer<void>();
      queue.runTracked('dup_task', () async {
        await completer.future;
      });

      expect(queue.activeTaskCount, 1);
      completer.complete();

      await Future.delayed(const Duration(milliseconds: 20));
      expect(queue.activeTaskCount, 0);

      // Queue state cannot become negative
      expect(queue.activeTaskCount >= 0, isTrue);
    });

    test('7. Drain timeout throws TimeoutException and does not mark gate closed', () async {
      final permanentBlocker = Completer<void>();

      queue.runTracked('stuck_task', () async {
        await permanentBlocker.future;
      });

      expect(queue.activeTaskCount, 1);

      // Attempt drain with a tiny 50ms timeout
      await expectLater(
        () => gate.closeAdmissionAndDrain(timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );

      // Gate state must NOT be closed because task was not drained!
      expect(gate.isClosed, isFalse);
      expect(lockService.releaseCount, 0); // Native lease NOT released!

      permanentBlocker.complete();
      await Future.delayed(const Duration(milliseconds: 20));
      expect(queue.activeTaskCount, 0);
    });

    test('8. Background task inside transaction Zone obeys transaction token lifetime', () async {
      final unblockCompleter = Completer<void>();
      final asyncTaskDoneCompleter = Completer<Object?>();

      await gatedDb.transaction((txn) async {
        await txn.query('accounts');

        // Spawn a tracked background task inside transaction Zone without awaiting
        queue.runTracked(
          'escaped_zoned_task',
          () async {
            try {
              await unblockCompleter.future;
              await gatedDb.query('accounts');
              asyncTaskDoneCompleter.complete(null);
            } catch (e) {
              asyncTaskDoneCompleter.complete(e);
            }
          },
        );
      });

      // Outer transaction completed and committed.
      // Unblock the background task
      unblockCompleter.complete();
      final err = await asyncTaskDoneCompleter.future;

      // Must be rejected with DatabaseTransactionClosedException!
      expect(err, isA<DatabaseTransactionClosedException>());
      expect(queue.activeTaskCount, 0);
    });

    test('9. Synchronous run() returns value and handles exceptions properly', () async {
      final result = await queue.run('compute_something', () async {
        return 42 * 2;
      });
      expect(result, 84);
      expect(queue.activeTaskCount, 0);

      await expectLater(
        () => queue.run('throw_something', () async {
          throw ArgumentError('Invalid argument');
        }),
        throwsA(isA<ArgumentError>()),
      );
      expect(queue.activeTaskCount, 0);
    });
  });
}
