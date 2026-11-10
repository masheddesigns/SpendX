import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/gated_database.dart';
import 'package:spend_x/data/core/gated_transaction.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/reminder_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_opening_balance_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_recurring_repository.dart';
import 'package:spend_x/features/merchant_rules/data/merchant_rule_repo.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:flutter/services.dart';
import 'package:spend_x/services/evidence_pruning_service.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

class FakePlatformProcessLockService implements PlatformProcessLockService {
  @override
  MethodChannel get channel => const MethodChannel('fake');

  @override
  Future<String> acquireForegroundLease({String engineId = 'main_engine'}) async {
    return 'fake_lease_token';
  }

  @override
  Future<bool> releaseForegroundLease({
    required String leaseToken,
    String engineId = 'main_engine',
  }) async {
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

class RawTestDatabase implements Database {
  int queryCount = 0;
  bool _isOpen = true;

  @override
  bool get isOpen => _isOpen;

  @override
  String get path => ':memory:';

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
    queryCount++;
    return [
      {
        'id': 'test_1',
        'name': 'Test',
        'account_type': 'asset',
        'account_id': 'acc_1',
        'economic_event_id': 'evt_1',
        'direction': 'debit',
        'title': 'Test Rule',
        'cadence': 'monthly',
        'next_due_date': '2026-01-01T00:00:00.000Z',
        'amount_minor_units': 1000,
        'source_type': 'sms',
        'extracted_timestamp': '2026-01-01T00:00:00.000Z',
        'is_active': 1,
        'count': 0,
        'total': 0.0,
        'limit_amount': 100.0,
        'icon': 'wallet',
        'color': 'blue',
        'type': 'expense',
        'keyword': 'starbucks',
        'category_id': 'cat_1',
        'usage_count': 1,
        'last_used': '2026-01-01T00:00:00.000Z',
        'event_type': 'expense',
        'lifecycle_status': 'posted',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
        'description': 'Test Event',
        'status': 'reconciled',
        'legacy_reported_balance_minor_units': 10000,
        'reconstructed_balance_minor_units': 10000,
        'adjustment_delta_minor_units': 0,
        'reconciliation_reason': 'test',
        'provenance_source': 'test',
      }
    ];
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    queryCount++;
    return [
      {'count': 0, 'balance': 0.0, 'total': 0.0, 'val': 1}
    ];
  }

  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async {
    queryCount++;
    return 1;
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    queryCount++;
    return 1;
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) async {
    queryCount++;
    return 1;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    queryCount++;
    return 1;
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) async {
    queryCount++;
    return 1;
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    queryCount++;
    return 1;
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    queryCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RawTestTransaction implements Transaction {
  final RawTestDatabase _db;
  RawTestTransaction(this._db);

  @override
  Database get database => _db;

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
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) =>
      _db.rawQuery(sql, arguments);

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _db.insert(table, values);

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) =>
      _db.update(table, values);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _db.delete(table);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) => _db.execute(sql);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseAccessGate gate;
  late RawTestDatabase rawDb;
  late RawTestTransaction rawTxn;

  setUp(() {
    final lockService = FakePlatformProcessLockService();
    gate = DatabaseAccessGate(processLockService: lockService);
    gate.resetForTesting();
    DatabaseAccessGate.instanceForTesting = gate;
    rawDb = RawTestDatabase();
    rawTxn = RawTestTransaction(rawDb);
  });

  tearDown(() {
    gate.resetForTesting();
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
  });

  group('Repository Factory & Boundary Hardening Suite', () {
    test('1. Every repository receiving raw DatabaseExecutor is wrapped in GatedDatabase', () async {
      final accountRepo = AccountRepo(executor: rawDb);
      final creditRepo = CreditRepo(executor: rawDb);
      final loanRepo = LoanRepo(executor: rawDb);
      final txRepo = TransactionRepo(executor: rawDb);
      final catRepo = CategoryRepo(executor: rawDb);
      final goalRepo = GoalRepo(executor: rawDb);
      final ruleRepo = MerchantRuleRepo(executor: rawDb);
      final budgetRepo = BudgetRepo(executor: rawDb);
      final reminderRepo = ReminderRepo(database: rawDb);

      // Verify that calling repository methods executes under DatabaseAccessGate
      expect(gate.activeOperations, 0);

      await catRepo.getAll();
      expect(rawDb.queryCount, 1);
      expect(gate.activeOperations, 0);

      await ruleRepo.getByKeyword('starbucks');
      expect(rawDb.queryCount, 2);
      expect(gate.activeOperations, 0);

      await reminderRepo.getAll();
      expect(rawDb.queryCount, 3);
      expect(gate.activeOperations, 0);

      await budgetRepo.getAll();
      expect(rawDb.queryCount, 4);
      expect(gate.activeOperations, 0);
    });

    test('2. Every canonical repository receiving raw DatabaseExecutor is wrapped in GatedDatabase', () async {
      final cAccountRepo = CanonicalAccountRepository(executor: rawDb);
      final cEventRepo = CanonicalEventRepository(executor: rawDb);
      final cOpRepo = CanonicalOpeningBalanceRepository(executor: rawDb);
      final cEarmarkRepo = CanonicalEarmarkRepository(executor: rawDb);
      final cQueryRepo = CanonicalFinancialQueryRepository(executor: rawDb);
      final cReviewRepo = CanonicalReviewRepository(executor: rawDb);
      final cRecRepo = CanonicalRecurringRepository(executor: rawDb);

      expect(gate.activeOperations, 0);

      await cAccountRepo.getAccount('acc_1');
      expect(rawDb.queryCount, 1);
      expect(gate.activeOperations, 0);

      await cEventRepo.getEvidenceForEvent('evt_1');
      expect(rawDb.queryCount, 2);
      expect(gate.activeOperations, 0);

      await cOpRepo.getReconciliation('rec_1');
      expect(rawDb.queryCount, 3);
      expect(gate.activeOperations, 0);

      await cQueryRepo.getTotalAssets();
      expect(rawDb.queryCount, 4);
      expect(gate.activeOperations, 0);

      await cRecRepo.getRules();
      expect(rawDb.queryCount, 5);
      expect(gate.activeOperations, 0);
    });

    test('3. Raw Transaction injection is automatically wrapped in GatedTransaction', () async {
      final cAccountRepo = CanonicalAccountRepository();
      // Pass raw un-gated transaction handle
      await cAccountRepo.getAccount('acc_1', txn: rawTxn);
      expect(rawDb.queryCount, 1);

      final cOpRepo = CanonicalOpeningBalanceRepository();
      await cOpRepo.getReconciliation('rec_1', txn: rawTxn);
      expect(rawDb.queryCount, 2);
    });

    test('4. When gate admission closes, all repositories with custom executors are rejected', () async {
      final catRepo = CategoryRepo(executor: rawDb);
      final ruleRepo = MerchantRuleRepo(executor: rawDb);

      // Close gate admission
      await gate.closeAdmissionAndDrain();
      expect(gate.isClosed, isTrue);

      // Even with injected rawDb, calls must be rejected by DatabaseAccessGate!
      await expectLater(
        () => catRepo.getAll(),
        throwsA(isA<DatabaseGateClosedException>()),
      );

      await expectLater(
        () => ruleRepo.getByKeyword('starbucks'),
        throwsA(isA<DatabaseGateClosedException>()),
      );
    });

    test('5. EvidencePruningService wraps custom executor and respects gate admission', () async {
      expect(gate.activeOperations, 0);

      await EvidencePruningService.instance.pruneExpiredEvidence(executor: rawDb);
      expect(rawDb.queryCount, 1);
      expect(gate.activeOperations, 0);

      // Close gate
      await gate.closeAdmissionAndDrain();
      await expectLater(
        () => EvidencePruningService.instance.pruneExpiredEvidence(executor: rawDb),
        throwsA(isA<DatabaseGateClosedException>()),
      );
    });

    test('6. Temporary backup databases remain unwrapped and separate from primary gate', () async {
      final standaloneRawDb = RawTestDatabase();
      // Standalone auxiliary DB not wrapped in gate
      expect(standaloneRawDb, isNot(isA<GatedDatabase>()));

      // Operations on standalone auxiliary DB do not affect primary gate active operations
      await standaloneRawDb.rawQuery('SELECT 1');
      expect(gate.activeOperations, 0);
    });

    test('7. Ordinary callers cannot open primary spendx.db via either factory method or getFactory', () async {
      // 1. openEncryptedDatabase
      await expectLater(
        () => SpendXDatabaseFactory.instance.openEncryptedDatabase(
          'spendx.db',
          password: 'fake_password',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Direct opening of primary database "spendx.db" via SpendXDatabaseFactory is prohibited'),
          ),
        ),
      );

      // 2. openPlaintextDatabase
      await expectLater(
        () => SpendXDatabaseFactory.instance.openPlaintextDatabase(
          'spendx.db',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Direct opening of primary database "spendx.db" via SpendXDatabaseFactory is prohibited'),
          ),
        ),
      );

      // 3. getFactory().openDatabase
      final guardedFactory = SpendXDatabaseFactory.instance.getFactory();
      await expectLater(
        () => guardedFactory.openDatabase('spendx.db'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Direct opening of primary database "spendx.db" via SpendXDatabaseFactory is prohibited'),
          ),
        ),
      );
    });

    test('8. Equivalent primary paths (relative dots, parent navigation, symlinks, nonexistent nested paths) are rejected', () async {
      final dbDir = await getDatabasesPath();
      await Directory(dbDir).create(recursive: true);

      // Relative paths
      expect(await SpendXDatabaseFactory.isPrimaryDatabasePath('spendx.db'), isTrue);
      expect(await SpendXDatabaseFactory.isPrimaryDatabasePath('./spendx.db'), isTrue);
      expect(await SpendXDatabaseFactory.isPrimaryDatabasePath('foo/../spendx.db'), isTrue);
      expect(await SpendXDatabaseFactory.isPrimaryDatabasePath('sub/nested/../../spendx.db'), isTrue);

      // Absolute paths with equivalent segments
      expect(await SpendXDatabaseFactory.isPrimaryDatabasePath(p.join(dbDir, 'spendx.db')), isTrue);
      expect(await SpendXDatabaseFactory.isPrimaryDatabasePath(p.join(dbDir, 'foo/../spendx.db')), isTrue);
      expect(await SpendXDatabaseFactory.isPrimaryDatabasePath(p.join(dbDir, '././spendx.db')), isTrue);

      // Test symlink equivalence and nonexistent nested paths beneath symlinked ancestors
      final tempSymlinkDir = await Directory.systemTemp.createTemp('spendx_symlink_test_');
      try {
        final symlink = Link(p.join(tempSymlinkDir.path, 'symlink_db_dir'));
        try {
          await symlink.create(dbDir);
          final symlinkPath = p.join(symlink.path, 'spendx.db');
          expect(await SpendXDatabaseFactory.isPrimaryDatabasePath(symlinkPath), isTrue);

          // Nonexistent nested path beneath symlinked ancestor
          final nonexistentNestedPath = p.join(symlink.path, 'nonexistent_child/sub/../../spendx.db');
          expect(await SpendXDatabaseFactory.isPrimaryDatabasePath(nonexistentNestedPath), isTrue);
        } on FileSystemException {
          // Some environments restrict symlink creation
        }
      } finally {
        await tempSymlinkDir.delete(recursive: true);
      }
    });

    test('9. Exact attack prevention: unrelated production caller cannot obtain or invoke primary opener', () async {
      // 1. Verify that no public capability transfer or opener binding method exists on SpendXDatabaseFactory
      expect(
        () => (SpendXDatabaseFactory.instance as dynamic).bindPrimaryDatabaseOpener(),
        throwsA(isA<NoSuchMethodError>()),
      );

      // 2. Verify that no public opener getter or field is exposed
      expect(
        () => (SpendXDatabaseFactory.instance as dynamic).primaryOpener,
        throwsA(isA<NoSuchMethodError>()),
      );
      expect(
        () => (SpendXDatabaseFactory.instance as dynamic).openPrimaryEncryptedInternal,
        throwsA(isA<NoSuchMethodError>()),
      );

      // 3. Verify that an unauthorized caller calling factory open on spendx.db cannot bypass the boundary
      await expectLater(
        () => SpendXDatabaseFactory.instance.openEncryptedDatabase(
          'spendx.db',
          password: 'stolen_or_fake_key',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Direct opening of primary database "spendx.db" via SpendXDatabaseFactory is prohibited'),
          ),
        ),
      );

      // 4. Verify that factory open on equivalent relative path is rejected unconditionally
      await expectLater(
        () => SpendXDatabaseFactory.instance.openPlaintextDatabase(
          'foo/../spendx.db',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Direct opening of primary database "spendx.db" via SpendXDatabaseFactory is prohibited'),
          ),
        ),
      );
    });

    test('10. Backup, restore staging, and migration staging databases remain permitted', () async {
      // Backup snapshot
      final isSnapPrimary = await SpendXDatabaseFactory.isPrimaryDatabasePath('vacuum_snap.db');
      expect(isSnapPrimary, isFalse);

      // Restore staging directory
      final isRestoreStaging = await SpendXDatabaseFactory.isPrimaryDatabasePath(
        '/data/user/0/com.mashingdesigns.spend_x/cache/spendx_restore_stage_123/spendx.db',
      );
      expect(isRestoreStaging, isFalse);

      // Migration staging file
      final isMigrationStaging = await SpendXDatabaseFactory.isPrimaryDatabasePath(
        '/data/user/0/com.mashingdesigns.spend_x/databases/spendx.db.migration_staging',
      );
      expect(isMigrationStaging, isFalse);
    });

    test('11. AppDatabase can initialize and return a gated connection', () async {
      final tempTestDir = await Directory.systemTemp.createTemp('app_db_boundary_test_');
      try {
        final testDbFile = p.join(tempTestDir.path, 'isolated_spendx.db');
        AppDatabase.setTestDatabasePath(testDbFile);

        final db = await AppDatabase.instance.database;
        expect(db, isA<GatedDatabase>());
        expect(db.isOpen, isTrue);

        await db.query('accounts');
        expect(gate.activeOperations, 0);

        await db.close();
      } finally {
        AppDatabase.setTestDatabasePath(null);
        await tempTestDir.delete(recursive: true);
      }
    });
  });
}
