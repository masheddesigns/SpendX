import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C3B-1: TransactionRepo Migration Suite', () {
    late Database db;
    late TransactionRepo repo;
    late CanonicalAccountRepository accountRepo;
    late CanonicalEventRepository eventRepo;
    late CanonicalFinancialQueryRepository queryRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      // Create full schema including v24 canonical tables & triggers
      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      repo = TransactionRepo(executor: db);
      accountRepo = CanonicalAccountRepository(executor: db);
      eventRepo = CanonicalEventRepository(executor: db);
      queryRepo = CanonicalFinancialQueryRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    Transaction sampleTx({
      required String id,
      required String type,
      required double amount,
      String? accountId = 'acc_bank',
      String? categoryId,
      String? relatedEntityId,
      String? source = 'manual',
      String? externalRef,
      DateTime? date,
    }) {
      final effectiveCat = categoryId ?? (type == 'income' ? 'cat_salary' : 'cat_food');
      return Transaction(
        id: id,
        userId: 'user_1',
        type: type,
        amount: amount,
        accountId: accountId,
        categoryId: effectiveCat,
        relatedEntityId: relatedEntityId,
        source: source ?? 'manual',
        externalRef: externalRef,
        date: date ?? DateTime(2025, 1, 15, 10, 0),
        notes: 'Test $type $id',
      );
    }

    // -------------------------------------------------------------------------
    // 1. CREATE TEST: Canonical Persistence & Zero Legacy Write
    // -------------------------------------------------------------------------
    test('Create: Canonical event and postings created, ZERO write to legacy transactions table', () async {
      final tx = sampleTx(id: 'tx_create_1', type: 'expense', amount: 1500.0);
      final id = await repo.insert(tx);
      expect(id, 'tx_create_1');

      // Canonical Truth Verification
      final event = await eventRepo.getEvent('tx_create_1');
      expect(event, isNotNull);
      expect(event!.lifecycleStatus, EventLifecycle.posted);
      expect(event.canonicalType, CanonicalEventType.expense);
      expect(event.postings.length, 2);

      // Verify Postings Balance
      final debits = event.postings
          .where((p) => p.direction == PostingDirection.debit)
          .fold<int>(0, (s, p) => s + p.amount.minorUnits);
      final credits = event.postings
          .where((p) => p.direction == PostingDirection.credit)
          .fold<int>(0, (s, p) => s + p.amount.minorUnits);
      expect(debits, 150000);
      expect(credits, 150000);
      expect(debits, credits);

      // FIREWALL PROOF: Legacy transactions table receives ZERO writes
      final legacyRows = await db.query(Tables.transactions);
      expect(legacyRows, isEmpty);
    });

    // -------------------------------------------------------------------------
    // 2. READ TEST: Compatibility Projection Matches Canonical Truth
    // -------------------------------------------------------------------------
    test('Read: getAll and getById return legacy Transaction projected from canonical truth', () async {
      final tx1 = sampleTx(id: 'tx_read_1', type: 'income', amount: 50000.0);
      final tx2 = sampleTx(id: 'tx_read_2', type: 'expense', amount: 3500.0);
      await repo.insert(tx1);
      await repo.insert(tx2);

      // Read via getById
      final fetched1 = await repo.getById('tx_read_1');
      expect(fetched1, isNotNull);
      expect(fetched1!.id, 'tx_read_1');
      expect(fetched1.type, 'income');
      expect(fetched1.amount, 50000.0);
      expect(fetched1.accountId, 'acc_bank');

      final fetched2 = await repo.getById('tx_read_2');
      expect(fetched2, isNotNull);
      expect(fetched2!.id, 'tx_read_2');
      expect(fetched2.type, 'expense');
      expect(fetched2.amount, 3500.0);

      // Read via getAll
      final all = await repo.getAll();
      expect(all.length, 2);
      expect(all.map((t) => t.id).toSet(), containsAll(['tx_read_1', 'tx_read_2']));

      // Confirm legacy transactions table was NEVER populated
      final legacyCount = (await db.rawQuery('SELECT COUNT(*) AS c FROM ${Tables.transactions}')).first['c'];
      expect(legacyCount, 0);
    });

    // -------------------------------------------------------------------------
    // 3. UPDATE TEST: Posted Immutability & Reversal-Replacement Correction
    // -------------------------------------------------------------------------
    test('Update: Posted event remains immutable, correction uses reversal + replacement', () async {
      final txOriginal = sampleTx(id: 'tx_upd_1', type: 'expense', amount: 1000.0);
      await repo.insert(txOriginal);

      final originalEvent = await eventRepo.getEvent('tx_upd_1');
      expect(originalEvent, isNotNull);
      expect(originalEvent!.lifecycleStatus, EventLifecycle.posted);

      // Initial account balance
      final initialBalance = await accountRepo.getDerivedBalance('cat_food');
      expect(initialBalance.minorUnits, 100000); // Dr 1,000

      // Update amount to 2,500
      final txUpdated = sampleTx(id: 'tx_upd_1', type: 'expense', amount: 2500.0);
      final res = await repo.update(txUpdated);
      expect(res, 1);

      // IMMUTABILITY PROOF: Original posted event was NOT mutated in place
      final originalPostings = await eventRepo.getPostingsForEvent('tx_upd_1');
      expect(originalPostings.first.amount.minorUnits, 100000);

      // Reversal event exists and negates the original
      final allEvents = await eventRepo.listPostedEvents();
      final reversalEvent = allEvents.firstWhere(
        (e) => e.description.startsWith('REVERSAL: tx_upd_1'),
      );
      expect(reversalEvent, isNotNull);

      // Final derived balance reflects updated amount (2,500 = 250,000 paise)
      final updatedBalance = await accountRepo.getDerivedBalance('cat_food');
      expect(updatedBalance.minorUnits, 250000);

      // Legacy table still untouched
      expect(await db.query(Tables.transactions), isEmpty);
    });

    // -------------------------------------------------------------------------
    // 4. DELETE TEST: Soft-Delete via Reversal & Audit Retention
    // -------------------------------------------------------------------------
    test('Delete: Accounting truth not physically deleted; balanced reversal cancels financial impact', () async {
      final tx = sampleTx(id: 'tx_del_1', type: 'expense', amount: 4000.0);
      await repo.insert(tx);

      expect((await accountRepo.getDerivedBalance('cat_food')).minorUnits, 400000);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 400000);

      // Execute delete
      final deleteResult = await repo.delete('tx_del_1');
      expect(deleteResult, 1);

      // CANONICAL AUDIT RETENTION: Original event still exists physically in SQLite
      final originalStillThere = await eventRepo.getEvent('tx_del_1');
      expect(originalStillThere, isNotNull);

      // Financial balance cleanly canceled to ₹0 via reversal
      expect((await accountRepo.getDerivedBalance('cat_food')).minorUnits, 0);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);

      // Compatibility getAll() excludes reversed transaction
      final activeList = await repo.getAll();
      expect(activeList.where((t) => t.id == 'tx_del_1'), isEmpty);
    });

    // -------------------------------------------------------------------------
    // 5. ATOMIC ROLLBACK TEST: Zero Partial State on Injected Failure
    // -------------------------------------------------------------------------
    test('Rollback: Injected constraint violation rolls back cleanly leaving 0 partial state', () async {
      // Transaction with invalid negative amount that fails domain/trigger validation
      final invalidTx = Transaction(
        id: 'tx_fail_1',
        userId: 'u1',
        type: 'expense',
        amount: -500.0, // Invalid negative amount for normal expense
        date: DateTime.now(),
      );

      expect(() => repo.insert(invalidTx), throwsA(isA<ArgumentError>()));

      // Verify ZERO partial artifacts in SQLite
      final event = await eventRepo.getEvent('tx_fail_1');
      expect(event, isNull);

      final postings = await db.rawQuery(
        'SELECT * FROM ${TablesV24.postings} WHERE economic_event_id = ?;',
        ['tx_fail_1'],
      );
      expect(postings, isEmpty);

      final evidence = await db.rawQuery(
        'SELECT * FROM ${TablesV24.evidence} WHERE economic_event_id = ?;',
        ['tx_fail_1'],
      );
      expect(evidence, isEmpty);

      // Financial queries unchanged
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);
    });

    // -------------------------------------------------------------------------
    // 6. DEDUPLICATION TEST: External Ref Duplicate Rejection
    // -------------------------------------------------------------------------
    test('Deduplication: Repeated request with identical externalRef is rejected and deduplicated', () async {
      final tx1 = sampleTx(id: 'tx_dup_1', type: 'expense', amount: 500.0, externalRef: 'SMS_REF_999');
      final tx2 = sampleTx(id: 'tx_dup_2', type: 'expense', amount: 500.0, externalRef: 'SMS_REF_999');

      await repo.insert(tx1);

      expect(await repo.existsByExternalRef('SMS_REF_999'), isTrue);
      expect(await repo.getExistingExternalRefs(['SMS_REF_999', 'UNKNOWN']), {'SMS_REF_999'});

      // Batch insert should ignore tx2
      final inserted = await repo.insertAllReturningRefsWithTxn(db, [tx2]);
      expect(inserted, isEmpty);

      // Financial expense remains 500 (not 1,000)
      expect((await queryRepo.getTotalExpenses()).minorUnits, 50000);
    });

    // -------------------------------------------------------------------------
    // 7. CROSS-REPOSITORY GLOBAL ACCOUNTING EQUATION & DERIVED QUERIES
    // -------------------------------------------------------------------------
    test('Global Accounting Equation & Aggregate Analytics Conformance', () async {
      final now = DateTime.now();
      // 1. Income 60,000
      await repo.insert(sampleTx(id: 't_inc', type: 'income', amount: 60000.0, date: now));
      // 2. Expense 10,000
      await repo.insert(sampleTx(id: 't_exp', type: 'expense', amount: 10000.0, date: now));
      // 3. Card purchase 5,000
      await repo.insert(sampleTx(
        id: 't_card',
        type: 'credit_card_purchase',
        source: 'credit_card_purchase',
        amount: 5000.0,
        accountId: 'card_1',
        date: now,
      ));
      // 4. Transfer 15,000
      await repo.insert(sampleTx(
        id: 't_trans',
        type: 'transfer',
        amount: 15000.0,
        accountId: 'acc_bank',
        relatedEntityId: 'acc_savings',
        date: now,
      ));

      // Global Accounting Equation Validation:
      // Assets = 60k - 10k - 15k + 15k = 50k
      final assets = await queryRepo.getTotalAssets();
      expect(assets.minorUnits, 5000000);

      // Liabilities = 5k (card_1)
      final liabilities = await queryRepo.getTotalLiabilities();
      expect(liabilities.minorUnits, 500000);

      // Net Worth = 50k - 5k = 45k
      final netWorth = await queryRepo.getNetWorth();
      expect(netWorth.minorUnits, 4500000);

      // Equity = Retained earnings (Income 60k - Expense 15k = 45k)
      final totalEquity = await queryRepo.getTotalEquity();
      expect(totalEquity.minorUnits, 4500000);

      expect(assets.minorUnits, liabilities.minorUnits + totalEquity.minorUnits);
      expect(netWorth.minorUnits, totalEquity.minorUnits);

      // Verify TransactionRepo Derived Query Compatibility Methods
      final stats = await repo.getStatsForRange(
        now.subtract(const Duration(days: 1)),
        now.add(const Duration(days: 1)),
      );
      expect(stats['income'], 60000.0);
      expect(stats['expense'], 15000.0); // 10k cash expense + 5k card expense
      expect(stats['txn_count'], 4);
      expect(stats['biggest_expense'], 10000.0);

      final monthlyStats = await repo.getMonthlyStats(12);
      expect(monthlyStats.isNotEmpty, isTrue);
      expect(monthlyStats.first['income'], 60000.0);
      expect(monthlyStats.first['expense'], 15000.0);

      final categories = await repo.getCategoryBreakdown(12);
      expect(categories.isNotEmpty, isTrue);

      final avgDaily = await repo.getAvgDailySpending(30);
      expect(avgDaily, greaterThan(0));

      final months = await repo.getDistinctMonths();
      final monthStr = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      expect(months, contains(monthStr));
    });
  });
}
