import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/gated_database.dart';
import 'package:spend_x/data/core/gated_transaction.dart';
import 'package:spend_x/data/core/gated_batch.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';
import 'package:spend_x/services/evidence_pruning_service.dart';

/// Fake in-memory mock for [Database], [Transaction], and [Batch].
class FakeDatabase implements Database {
  bool _isOpen = true;
  int operationCount = 0;
  bool inTransaction = false;
  Completer<void>? slowOpCompleter;

  @override
  String get path => ':memory:';

  @override
  bool get isOpen => _isOpen;

  @override
  Database get database => this;

  @override
  Future<void> close() async {
    _isOpen = false;
  }

  @override
  Batch batch() => FakeBatch(this);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    operationCount++;
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    operationCount++;
    return 1;
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    operationCount++;
    return 1;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    operationCount++;
    return 1;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    operationCount++;
    return 1;
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    operationCount++;
    return 1;
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) async {
    operationCount++;
    return 1;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (sql.contains('slow_op') && slowOpCompleter != null) {
      await slowOpCompleter!.future;
    }
    operationCount++;
    return [
      {'val': 42}
    ];
  }

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
    operationCount++;
    return [
      {'id': 1}
    ];
  }

  @override
  Future<QueryCursor> rawQueryCursor(String sql, List<Object?>? arguments,
      {int? bufferSize}) {
    throw UnimplementedError();
  }

  @override
  Future<QueryCursor> queryCursor(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset,
      int? bufferSize}) {
    throw UnimplementedError();
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    inTransaction = true;
    final txn = FakeTransaction(this);
    try {
      return await action(txn);
    } finally {
      inTransaction = false;
    }
  }

  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction txn) action) async {
    return transaction(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTransaction implements Transaction {
  final FakeDatabase _db;
  FakeTransaction(this._db);

  @override
  Database get database => _db;

  @override
  Batch batch() => FakeBatch(_db);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    _db.operationCount++;
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    _db.operationCount++;
    return 1;
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    _db.operationCount++;
    return 1;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    _db.operationCount++;
    return 1;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    _db.operationCount++;
    return 1;
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) async {
    _db.operationCount++;
    return 1;
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    _db.operationCount++;
    return 1;
  }

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
    _db.operationCount++;
    return [
      {'id': 1}
    ];
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    _db.operationCount++;
    return [
      {'val': 1}
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeBatch implements Batch {
  final FakeDatabase _db;
  int _queued = 0;
  FakeBatch(this._db);

  @override
  int get length => _queued;

  @override
  void execute(String sql, [List<Object?>? arguments]) => _queued++;

  @override
  void insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _queued++;

  @override
  void rawInsert(String sql, [List<Object?>? arguments]) => _queued++;

  @override
  void update(String table, Map<String, Object?> values,
      {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) =>
      _queued++;

  @override
  void rawUpdate(String sql, [List<Object?>? arguments]) => _queued++;

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _queued++;

  @override
  void rawDelete(String sql, [List<Object?>? arguments]) => _queued++;

  @override
  void query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) =>
      _queued++;

  @override
  void rawQuery(String sql, [List<Object?>? arguments]) => _queued++;

  @override
  Future<List<Object?>> commit(
      {bool? exclusive, bool? noResult, bool? continueOnError}) async {
    _db.operationCount += _queued;
    return List.filled(_queued, 1);
  }

  @override
  Future<List<Object?>> apply({bool? noResult, bool? continueOnError}) async {
    return commit();
  }
}

class FakePlatformProcessLockService implements PlatformProcessLockService {
  int acquireCount = 0;
  int releaseCount = 0;
  String? lastReleasedToken;

  FakePlatformProcessLockService();

  @override
  MethodChannel get channel => const MethodChannel('fake');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    acquireCount++;
    return 'fake_native_lease_$acquireCount';
  }

  @override
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
    releaseCount++;
    lastReleasedToken = leaseToken;
    return true;
  }

  @override
  Future<NativeTicketResult> acquireOperationTicket({
    String? engineId,
    required String tag,
  }) async {
    return const NativeTicketResult(ticketId: 'fake_ticket', tag: 'fake_tag');
  }

  @override
  Future<bool> releaseOperationTicket(
    String ticketId, {
    String? engineId,
  }) async => true;

  @override
  Future<String> beginExclusiveRestore({
    int drainTimeoutMs = 5000,
    int contentionTimeoutMs = 5000,
  }) async => 'fake_restore_token';

  @override
  Future<bool> completeExclusiveRestore(String restoreToken) async => true;

  @override
  Future<bool> abortExclusiveRestore(String restoreToken) async => true;

  @override
  Future<bool> validateExclusiveRestoreToken(String restoreToken) async => true;

  @override
  Future<Map<String, dynamic>> getLockStatus() async => {};
}

class FailingAcquireProcessLockService extends FakePlatformProcessLockService {
  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    throw const DatabaseAdmissionClosedException('Host manager rejected lease');
  }
}

class FailingReleaseProcessLockService extends FakePlatformProcessLockService {
  @override
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
    return false; // Host manager failed release
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformProcessLockService lockService;
  late DatabaseAccessGate gate;
  late FakeDatabase fakeDb;
  late GatedDatabase gatedDb;

  setUp(() {
    lockService = FakePlatformProcessLockService();
    gate = DatabaseAccessGate(processLockService: lockService);
    DatabaseAccessGate.instanceForTesting = gate;
    fakeDb = FakeDatabase();
    gatedDb = GatedDatabase(fakeDb, gate);
  });

  tearDown(() {
    gate.resetForTesting();
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate(processLockService: FakePlatformProcessLockService());
  });

  group('DatabaseAccessGate & Decorators Core Suite', () {
    test('1. Normal read and write admission increments and decrements active operations', () async {
      expect(gate.activeOperations, 0);

      final queryResult = await gatedDb.query('expenses');
      expect(queryResult, isNotEmpty);
      expect(gate.activeOperations, 0);
      expect(fakeDb.operationCount, 1);

      final insertResult = await gatedDb.insert('expenses', {'amount': 100});
      expect(insertResult, 1);
      expect(gate.activeOperations, 0);
      expect(fakeDb.operationCount, 2);
    });

    test('2. Concurrent reads and writes track operations count without leak', () async {
      expect(gate.activeOperations, 0);

      final futures = List.generate(20, (i) => gatedDb.rawQuery('SELECT 1'));
      final results = await Future.wait(futures);

      expect(results.length, 20);
      expect(gate.activeOperations, 0);
      expect(fakeDb.operationCount, 20);
    });

    test('3. Transaction nesting inherits admission zone without secondary tickets', () async {
      expect(gate.activeOperations, 0);

      await gatedDb.transaction((txn) async {
        // First query on txn
        expect(gate.activeOperations, 1); // 1 active operation for the transaction
        await txn.insert('accounts', {'name': 'Checking'});

        // Nested call on gatedDb inside transaction inherits transaction zone!
        await gatedDb.query('accounts');
        // Still 1 active operation because it inherits zone!
        expect(gate.activeOperations, 1);

        await txn.update('accounts', {'name': 'Savings'});
        expect(gate.activeOperations, 1);
      });

      // Once transaction finishes, counter is 0
      expect(gate.activeOperations, 0);
    });

    test('4. Transaction callback exceptions rethrow, clean invalidation, and clear counter', () async {
      expect(gate.activeOperations, 0);

      await expectLater(
        () => gatedDb.transaction((txn) async {
          await txn.execute('UPDATE foo SET bar = 1');
          throw StateError('Simulated transaction failure');
        }),
        throwsA(isA<StateError>()),
      );

      expect(gate.activeOperations, 0);
      expect(fakeDb.inTransaction, isFalse);
    });

    test('5. Escaped transaction handle rejection throws DatabaseTransactionClosedException', () async {
      late Transaction escapedTxn;

      await gatedDb.transaction((txn) async {
        await txn.insert('logs', {'msg': 'ok'});
        escapedTxn = txn; // Leak transaction handle outside callback scope
      });

      // Attempting to use the leaked handle outside the transaction callback must fail!
      expect(
        () => escapedTxn.query('logs'),
        throwsA(isA<DatabaseTransactionClosedException>()),
      );

      expect(
        () => escapedTxn.insert('logs', {'msg': 'illegal'}),
        throwsA(isA<DatabaseTransactionClosedException>()),
      );
    });

    test('6. Batch lifecycle and commit admission', () async {
      final batch = gatedDb.batch();
      batch.insert('items', {'val': 1});
      batch.insert('items', {'val': 2});
      expect(batch.length, 2);

      final results = await batch.commit();
      expect(results.length, 2);
      expect(gate.activeOperations, 0);
    });

    test('7. Admission closure while operations active waits for drain and rejects new operations', () async {
      fakeDb.slowOpCompleter = Completer<void>();
      final inFlightCompleter = Completer<void>();

      // Launch an operation that stays active until we trigger it
      unawaited(
        gatedDb.rawQuery('SELECT slow_op').then((_) {
          inFlightCompleter.complete();
        }),
      );

      // Wait until activeOperations == 1
      while (gate.activeOperations == 0) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      expect(gate.activeOperations, 1);

      // Begin closing admission for restore in background
      final drainFuture = gate.closeAdmissionAndDrain();
      expect(gate.state, GateState.draining);

      // New database operations must be rejected immediately!
      expect(
        () => gatedDb.query('expenses'),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      // Finish the slow in-flight operation
      fakeDb.slowOpCompleter!.complete();
      await inFlightCompleter.future;

      // Drain completes and gate transitions to closed
      await drainFuture;
      expect(gate.state, GateState.closed);
      expect(gate.activeOperations, 0);
    });

    test('8. Native lease acquisition and release with PlatformProcessLockService', () async {
      expect(lockService.acquireCount, 0);
      expect(lockService.releaseCount, 0);

      // Open gate acquires native lease
      final token = await gate.ensureNativeLeaseAcquired();
      expect(token, 'fake_native_lease_1');
      expect(lockService.acquireCount, 1);

      // Second check returns same token without re-acquiring
      final token2 = await gate.ensureNativeLeaseAcquired();
      expect(token2, token);
      expect(lockService.acquireCount, 1);

      // Close and drain releases native lease
      await gate.closeAdmissionAndDrain();
      expect(lockService.releaseCount, 1);
      expect(lockService.lastReleasedToken, token);
      expect(gate.nativeLeaseToken, isNull);
    });

    test('9. Injected DatabaseExecutor bypass prevention', () async {
      final rawDb = FakeDatabase();
      final executor1 = gate.wrapExecutor(rawDb);
      expect(executor1, isA<GatedDatabase>());

      final rawTxn = FakeTransaction(rawDb);
      final executor2 = gate.wrapExecutor(rawTxn);
      expect(executor2, isA<GatedTransaction>());

      // Already wrapped executors are returned as-is
      final executor3 = gate.wrapExecutor(executor1);
      expect(identical(executor1, executor3), isTrue);
    });

    test('10. Reopen admission restores access and re-acquires native lease', () async {
      await gate.closeAdmissionAndDrain();
      expect(gate.state, GateState.closed);

      await gate.reopenAdmission();
      expect(gate.state, GateState.open);
      expect(gate.isOpen, isTrue);

      final res = await gatedDb.query('test');
      expect(res, isNotEmpty);
    });

    test('11. First query automatically acquires native lease, concurrent queries coalesce', () async {
      final customLockService = FakePlatformProcessLockService();
      final freshGate = DatabaseAccessGate(processLockService: customLockService);
      final freshGatedDb = GatedDatabase(fakeDb, freshGate);

      expect(customLockService.acquireCount, 0);
      expect(freshGate.nativeLeaseToken, isNull);

      // Launch 5 concurrent queries at cold start
      final futures = List.generate(5, (_) => freshGatedDb.query('accounts'));
      await Future.wait(futures);

      // Native lease acquired exactly once!
      expect(customLockService.acquireCount, 1);
      expect(freshGate.nativeLeaseToken, 'fake_native_lease_1');
    });

    test('12. Failed native lease acquisition does not leak active operations count', () async {
      final failingLockService = FailingAcquireProcessLockService();
      final failingGate = DatabaseAccessGate(processLockService: failingLockService);
      final failingGatedDb = GatedDatabase(fakeDb, failingGate);

      expect(failingGate.activeOperations, 0);

      await expectLater(
        () => failingGatedDb.query('accounts'),
        throwsA(isA<DatabaseAdmissionClosedException>()),
      );

      // Operation count remains 0, no leak!
      expect(failingGate.activeOperations, 0);
      expect(failingGate.nativeLeaseToken, isNull);
    });

    test('13. Failed native lease release prevents marking gate closed and safe', () async {
      final failingReleaseService = FailingReleaseProcessLockService();
      final customGate = DatabaseAccessGate(processLockService: failingReleaseService);
      final customGatedDb = GatedDatabase(fakeDb, customGate);

      await customGatedDb.query('accounts');
      expect(customGate.nativeLeaseToken, isNotNull);

      // Drain attempt fails during native lease release
      await expectLater(
        () => customGate.closeAdmissionAndDrain(),
        throwsA(isA<StateError>()),
      );

      // Gate MUST NOT be marked closed!
      expect(customGate.state, isNot(GateState.closed));
      expect(customGate.isClosed, isFalse);
    });

    test('14. Simultaneous drain calls coalesce onto single future', () async {
      final customLockService = FakePlatformProcessLockService();
      final customGate = DatabaseAccessGate(processLockService: customLockService);
      final customGatedDb = GatedDatabase(fakeDb, customGate);

      await customGatedDb.query('accounts');
      expect(customLockService.releaseCount, 0);

      // Issue two simultaneous closeAdmissionAndDrain calls
      final drain1 = customGate.closeAdmissionAndDrain();
      final drain2 = customGate.closeAdmissionAndDrain();

      await Future.wait([drain1, drain2]);

      expect(customGate.state, GateState.closed);
      // Native release dispatched exactly once
      expect(customLockService.releaseCount, 1);
    });

    test('15. Reopening admission during active drain is rejected', () async {
      fakeDb.slowOpCompleter = Completer<void>();
      unawaited(gatedDb.rawQuery('SELECT slow_op'));

      while (gate.activeOperations == 0) {
        await Future.delayed(const Duration(milliseconds: 10));
      }

      final drainFuture = gate.closeAdmissionAndDrain();
      expect(gate.isDraining, isTrue);

      // Reopening during drain must throw StateError
      expect(
        () => gate.reopenAdmission(),
        throwsA(isA<StateError>()),
      );

      fakeDb.slowOpCompleter!.complete();
      await drainFuture;
      expect(gate.isClosed, isTrue);
    });

    test('16. Inherited Zone transaction token expires on callback exit, rejecting unawaited async ops', () async {
      final unblockCompleter = Completer<void>();
      final asyncOpDoneCompleter = Completer<Object?>();
      late Transaction capturedTxn;

      await gatedDb.transaction((txn) async {
        capturedTxn = txn;
        await txn.insert('accounts', {'name': 'Initial'});

        // Spawn asynchronous operation inside transaction Zone without awaiting it
        unawaited(
          Future(() async {
            try {
              // Wait until outer transaction callback finishes
              await unblockCompleter.future;

              // Attempting to use gatedDb within this inherited Zone MUST be rejected!
              await gatedDb.query('accounts');
              asyncOpDoneCompleter.complete(null);
            } catch (e) {
              asyncOpDoneCompleter.complete(e);
            }
          }),
        );
      });

      // Confirm transaction handle is invalidated
      expect(capturedTxn, isA<GatedTransaction>());
      expect((capturedTxn as GatedTransaction).isClosed, isTrue);

      // Unblock the spawned async operation
      unblockCompleter.complete();
      final err = await asyncOpDoneCompleter.future;

      // Must fail with DatabaseTransactionClosedException!
      expect(err, isA<DatabaseTransactionClosedException>());
      expect(
        (err as DatabaseTransactionClosedException).message,
        contains('expired or escaped transaction zone'),
      );
    });

    test('17. Database initialization raw executor does not escape; subsequent access is GatedDatabase', () async {
      final rawInitDb = FakeDatabase();
      final purged = await EvidencePruningService.instance.pruneExpiredEvidence(
        executor: rawInitDb,
      );
      expect(purged, 1);

      final wrappedDb = gate.wrapDatabase(rawInitDb);
      expect(wrappedDb, isA<GatedDatabase>());
      expect(wrappedDb.isOpen, isTrue);

      await wrappedDb.query('accounts');
      expect(gate.activeOperations, 0);
      expect(rawInitDb.operationCount, 2);
    });
  });
}
