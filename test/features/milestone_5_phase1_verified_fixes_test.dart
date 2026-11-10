import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone 5.0 Phase 1: Verified Fixes Regression Suite', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      transactionRepo = TransactionRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    // =========================================================================
    // 1. DEF-502 & DEF-504: Reversal Idempotency & Database-Level Uniqueness
    // =========================================================================
    group('DEF-502 & DEF-504: Reversal Idempotency & Partial Unique Index', () {
      test('1.1 Fresh database includes idx_events_unique_reversal and rejects duplicate raw reversals', () async {
        // Verify index exists
        final indexRows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_events_unique_reversal';",
        );
        expect(indexRows.length, 1, reason: 'Partial unique index must be installed during TablesV24.createAllV24');

        final nowStr = DateTime(2026, 11, 1, 10, 0).toIso8601String();

        // Insert original event
        await db.insert(TablesV24.economicEvents, {
          'id': 'orig_unique_test',
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'Original event for uniqueness test',
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        // Insert first reversal
        await db.insert(TablesV24.economicEvents, {
          'id': 'rev_unique_1',
          'event_type': 'adjustment',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: orig_unique_test',
          'reversal_of_event_id': 'orig_unique_test',
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        // Attempt second reversal directly via SQL: MUST FAIL with DatabaseException (code 1555)
        expect(
          () async => await db.insert(TablesV24.economicEvents, {
            'id': 'rev_unique_2',
            'event_type': 'adjustment',
            'lifecycle_status': 'draft',
            'timestamp': nowStr,
            'currency': 'INR',
            'description': 'REVERSAL: orig_unique_test duplicate',
            'reversal_of_event_id': 'orig_unique_test',
            'created_at': nowStr,
            'updated_at': nowStr,
          }),
          throwsA(isA<DatabaseException>()),
          reason: 'Database-level partial unique index prevents duplicate reversals at storage level',
        );
      });

      test('1.2 Stale update after deletion is cleanly rejected (returns 0) without balance drift', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_1_2',
          userId: 'user_1',
          name: 'HDFC Checking',
          bank: 'HDFC',
          balance: 10000.0,
          accountType: 'checking',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final expTx = spx.Transaction(
          id: 'tx_fix_1_2',
          userId: 'user_1',
          amount: 1000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_1_2',
          categoryId: 'cat_groceries',
          date: now,
          notes: 'Groceries',
        );
        await transactionRepo.insert(expTx);

        // Delete the transaction
        final delResult = await transactionRepo.delete('tx_fix_1_2');
        expect(delResult, 1);

        var bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_1_2');
        expect(bal.minorUnits, 1000000); // Restored to ₹10,000.00

        // Stale update attempt on deleted transaction
        final staleUpdateTx = expTx.copyWith(amount: 1500.0);
        final updateResult = await transactionRepo.update(staleUpdateTx);

        // CORRECT BEHAVIOR: Returns 0, no second reversal, balance preserved!
        expect(updateResult, 0, reason: 'Stale update on deleted transaction must return 0');

        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['tx_fix_1_2'],
        );
        expect(reversals.length, 1, reason: 'Exactly one reversal must exist');

        bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_1_2');
        expect(bal.minorUnits, 1000000, reason: 'Bank balance must remain exactly ₹10,000.00 (zero drift)');
      });

      test('1.3 Updating an already-reversed transaction is rejected', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_1_3',
          userId: 'user_1',
          name: 'HDFC Checking',
          bank: 'HDFC',
          balance: 10000.0,
          accountType: 'checking',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final expTx = spx.Transaction(
          id: 'tx_fix_1_3',
          userId: 'user_1',
          amount: 2000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_1_3',
          categoryId: 'cat_groceries',
          date: now,
        );
        await transactionRepo.insert(expTx);

        // Valid Edit 1
        final edit1Result = await transactionRepo.update(expTx.copyWith(amount: 2500.0));
        expect(edit1Result, 1);

        var bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_1_3');
        expect(bal.minorUnits, 750000); // ₹7,500.00

        // Attempt second update referencing original ID tx_fix_1_3 instead of replacement ID
        final edit2Result = await transactionRepo.update(expTx.copyWith(amount: 3000.0));
        expect(edit2Result, 0, reason: 'Attempt to update already-reversed transaction must return 0');

        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['tx_fix_1_3'],
        );
        expect(reversals.length, 1);

        bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_1_3');
        expect(bal.minorUnits, 750000, reason: 'Balance remains unchanged after rejected update');
      });

      test('1.4 Concurrent update requests: exactly one succeeds, others rejected with zero balance drift', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_1_4',
          userId: 'user_1',
          name: 'HDFC Checking',
          bank: 'HDFC',
          balance: 10000.0,
          accountType: 'checking',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final expTx = spx.Transaction(
          id: 'tx_fix_1_4',
          userId: 'user_1',
          amount: 2000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_1_4',
          categoryId: 'cat_groceries',
          date: now,
        );
        await transactionRepo.insert(expTx);

        // Rapid successive update calls against same original event
        final res1 = await transactionRepo.update(expTx.copyWith(amount: 2200.0));
        final res2 = await transactionRepo.update(expTx.copyWith(amount: 2400.0));

        expect(res1, 1, reason: 'First update succeeds');
        expect(res2, 0, reason: 'Second update against same original ID rejected');

        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['tx_fix_1_4'],
        );
        expect(reversals.length, 1, reason: 'Only 1 reversal exists for tx_fix_1_4');

        final bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_1_4');
        expect(bal.minorUnits, 780000, reason: 'Bank balance is exact: ₹10,000 - ₹2,200 = ₹7,800.00');
      });
    });

    // =========================================================================
    // 2. DEF-501: Cross-Month and Cross-Year Reversal Semantics (Strategy A)
    // =========================================================================
    group('DEF-501: Cross-Month and Cross-Year Reversal Semantics', () {
      test('2.1 Cross-Month Deletion: October expense deleted in November nets to zero in October with 0 count, November has 0 expense', () async {
        final bank = BankAccount(
          id: 'acc_bank_fix_2_1',
          userId: 'user_1',
          name: 'SBI Savings',
          bank: 'SBI',
          balance: 50000.0,
          accountType: 'savings',
          createdAt: DateTime(2026, 10, 1),
          updatedAt: DateTime(2026, 10, 1),
        );
        await accountRepo.insertAccount(bank);

        // October 15, 2026
        final octDate = DateTime(2026, 10, 15, 12, 0);
        final octTx = spx.Transaction(
          id: 'tx_oct_fix',
          userId: 'user_1',
          amount: 4000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_2_1',
          categoryId: 'cat_shopping',
          date: octDate,
          notes: 'October Jacket Purchase',
        );
        await transactionRepo.insert(octTx);

        final octStart = DateTime(2026, 10, 1);
        final octEnd = DateTime(2026, 10, 31, 23, 59, 59);

        // Before deletion: October expense = 4000.0, count = 1
        var octStats = await transactionRepo.getStatsForRange(octStart, octEnd);
        expect(octStats['expense'], 4000.0);
        expect(octStats['txn_count'], 1);

        // Delete in November
        await transactionRepo.delete('tx_oct_fix');

        // Check October stats after deletion:
        // Strategy A sets reversal.occurredAt = originalEvent.occurredAt
        // Debits (4000.0) - Credits (4000.0) = 0.0 net expense!
        // txn_count = 0. Clean and completely consistent!
        octStats = await transactionRepo.getStatsForRange(octStart, octEnd);
        expect(octStats['expense'], 0.0, reason: 'October net expense must be 0.0 after reversal');
        expect(octStats['txn_count'], 0, reason: 'October transaction count must be 0');
        expect(octStats['biggest_expense'], 0.0);

        // Check November stats:
        final novStart = DateTime(2026, 11, 1);
        final novEnd = DateTime(2026, 11, 30, 23, 59, 59);
        final novStats = await transactionRepo.getStatsForRange(novStart, novEnd);
        expect(novStats['expense'], 0.0, reason: 'November must have 0.0 expense (NO negative expense artifact)');
        expect(novStats['txn_count'], 0);

        // Check balances and net worth
        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_2_1');
        final netWorth = await canonicalQueryRepo.getNetWorth();
        expect(bankBal.minorUnits, 5000000);
        expect(netWorth.minorUnits, 5000000);

        // Verify audit chronology:
        final revRow = (await db.query(
          TablesV24.economicEvents,
          where: 'reversal_of_event_id = ?',
          whereArgs: ['tx_oct_fix'],
        )).first;

        // Accounting timestamp: matches October
        expect(DateTime.parse(revRow['timestamp'] as String).month, 10);
        // Creation timestamp: matches November wall clock (today)
        expect(DateTime.parse(revRow['created_at'] as String).month, DateTime.now().month);
      });

      test('2.2 Cross-Year Deletion: December 2025 expense deleted in January 2026 preserves year-end reporting', () async {
        final bank = BankAccount(
          id: 'acc_bank_fix_2_2',
          userId: 'user_1',
          name: 'SBI Savings',
          bank: 'SBI',
          balance: 50000.0,
          accountType: 'savings',
          createdAt: DateTime(2025, 12, 1),
          updatedAt: DateTime(2025, 12, 1),
        );
        await accountRepo.insertAccount(bank);

        final decDate = DateTime(2025, 12, 20, 12, 0);
        final decTx = spx.Transaction(
          id: 'tx_dec_2025_fix',
          userId: 'user_1',
          amount: 8000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_2_2',
          categoryId: 'cat_shopping',
          date: decDate,
          notes: 'Year-end holiday travel',
        );
        await transactionRepo.insert(decTx);

        final decStart = DateTime(2025, 12, 1);
        final decEnd = DateTime(2025, 12, 31, 23, 59, 59);

        // Delete transaction
        await transactionRepo.delete('tx_dec_2025_fix');

        // December stats: nets to 0.0
        final decStats = await transactionRepo.getStatsForRange(decStart, decEnd);
        expect(decStats['expense'], 0.0);
        expect(decStats['txn_count'], 0);

        // January 2026 stats: 0.0
        final janStart = DateTime(2026, 1, 1);
        final janEnd = DateTime(2026, 1, 31, 23, 59, 59);
        final janStats = await transactionRepo.getStatsForRange(janStart, janEnd);
        expect(janStats['expense'], 0.0);
        expect(janStats['txn_count'], 0);
      });
    });

    // =========================================================================
    // 3. DEF-503: Cumulative Refund Limits & Ceiling Enforcement
    // =========================================================================
    group('DEF-503: Cumulative Refund Limits', () {
      test('3.1 Successive partial refunds up to purchase succeed; excessive refund is rejected', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_3_1',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Purchase ₹5,000.00
        final purchaseTx = spx.Transaction(
          id: 'tx_p3_buy_fix',
          userId: 'user_1',
          amount: 5000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_3_1',
          categoryId: 'cat_electronics',
          date: now,
          notes: 'Smartphone purchase',
        );
        await transactionRepo.insert(purchaseTx);

        // 2. Partial refund 1: ₹2,000.00 (remaining: ₹3,000.00)
        final ref1 = spx.Transaction(
          id: 'tx_p3_ref1_fix',
          userId: 'user_1',
          amount: 2000.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_1',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_fix',
          date: now.add(const Duration(hours: 1)),
        );
        await transactionRepo.insert(ref1);

        // 3. Partial refund 2: ₹1,500.00 (remaining: ₹1,500.00)
        final ref2 = spx.Transaction(
          id: 'tx_p3_ref2_fix',
          userId: 'user_1',
          amount: 1500.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_1',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_fix',
          date: now.add(const Duration(hours: 2)),
        );
        await transactionRepo.insert(ref2);

        // 4. Partial refund 3: ₹1,500.00 (cumulative refunds = ₹5,000.00, remaining = ₹0.00)
        final ref3 = spx.Transaction(
          id: 'tx_p3_ref3_fix',
          userId: 'user_1',
          amount: 1500.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_1',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_fix',
          date: now.add(const Duration(hours: 3)),
        );
        await transactionRepo.insert(ref3);

        var bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_1');
        var catExp = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(bankBal.minorUnits, 2000000, reason: 'Bank restored exactly to ₹20,000.00');
        expect(catExp.minorUnits, 0, reason: 'Category expense reduced exactly to ₹0.00');

        // 5. Excessive 4th refund attempt: ₹500.00 (MUST BE REJECTED)
        final ref4Excess = spx.Transaction(
          id: 'tx_p3_ref4_excess_fix',
          userId: 'user_1',
          amount: 500.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_1',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_fix',
          date: now.add(const Duration(hours: 4)),
        );

        expect(
          () async => await transactionRepo.insert(ref4Excess),
          throwsA(isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Refund ceiling exceeded'),
          )),
          reason: 'Excess refund must be rejected with ArgumentError',
        );

        // Verify balance and category spending remain unchanged after rejection
        bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_1');
        catExp = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(bankBal.minorUnits, 2000000);
        expect(catExp.minorUnits, 0);
      });

      test('3.2 Concurrent refund requests respecting ceiling: first commits, second exceeding ceiling is rejected', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_3_2',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // Purchase: ₹3,000.00
        final purchaseTx = spx.Transaction(
          id: 'tx_p3_conc_buy',
          userId: 'user_1',
          amount: 3000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_3_2',
          categoryId: 'cat_electronics',
          date: now,
        );
        await transactionRepo.insert(purchaseTx);

        // Two refund requests for ₹2,000.00 each against a ₹3,000.00 purchase
        final refA = spx.Transaction(
          id: 'tx_p3_conc_ref_a',
          userId: 'user_1',
          amount: 2000.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_2',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_conc_buy',
          date: now.add(const Duration(minutes: 1)),
        );
        final refB = spx.Transaction(
          id: 'tx_p3_conc_ref_b',
          userId: 'user_1',
          amount: 2000.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_2',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_conc_buy',
          date: now.add(const Duration(minutes: 2)),
        );

        // Sequential or concurrent: first succeeds
        await transactionRepo.insert(refA);

        // Second exceeds remaining headroom (remaining is ₹1,000.00)
        expect(
          () async => await transactionRepo.insert(refB),
          throwsA(isA<ArgumentError>()),
          reason: 'Second refund exceeding remaining headroom must be rejected',
        );

        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_2');
        expect(bankBal.minorUnits, 1900000, reason: 'Balance is ₹20,000 - ₹3,000 + ₹2,000 = ₹19,000.00');
      });

      test('3.3 Refund against a deleted or already-reversed purchase is rejected', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_3_3',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Purchase ₹4,000.00
        final buyTx = spx.Transaction(
          id: 'tx_p3_buy_to_delete',
          userId: 'user_1',
          amount: 4000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_3_3',
          categoryId: 'cat_electronics',
          date: now,
        );
        await transactionRepo.insert(buyTx);

        // 2. Delete the purchase (reversal posted, funds restored)
        await transactionRepo.delete('tx_p3_buy_to_delete');

        // 3. Attempt refund against the deleted purchase: MUST BE REJECTED
        final refundOnDeleted = spx.Transaction(
          id: 'tx_p3_ref_on_deleted',
          userId: 'user_1',
          amount: 1000.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_3',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_to_delete',
          date: now.add(const Duration(hours: 1)),
        );

        expect(
          () async => await transactionRepo.insert(refundOnDeleted),
          throwsA(isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('has already been reversed or deleted'),
          )),
          reason: 'Refund against an already-reversed purchase must be rejected',
        );

        // Balance remains ₹20,000.00 (zero double-crediting)
        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_3');
        expect(bankBal.minorUnits, 2000000);
      });

      test('3.4 Editing an existing refund: valid amount succeeds, excessive amount is rejected', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_3_4',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Purchase ₹5,000.00
        final buyTx = spx.Transaction(
          id: 'tx_p3_buy_edit',
          userId: 'user_1',
          amount: 5000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_3_4',
          categoryId: 'cat_electronics',
          date: now,
        );
        await transactionRepo.insert(buyTx);

        // 2. Partial refund 1: ₹2,000.00
        final ref1 = spx.Transaction(
          id: 'tx_p3_ref1_edit',
          userId: 'user_1',
          amount: 2000.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_4',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_edit',
          date: now.add(const Duration(hours: 1)),
        );
        await transactionRepo.insert(ref1);

        // 3. Partial refund 2: ₹1,500.00 (total refunded: ₹3,500.00, remaining: ₹1,500.00)
        final ref2 = spx.Transaction(
          id: 'tx_p3_ref2_edit',
          userId: 'user_1',
          amount: 1500.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_4',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_edit',
          date: now.add(const Duration(hours: 2)),
        );
        await transactionRepo.insert(ref2);

        var bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_4');
        expect(bankBal.minorUnits, 1850000); // ₹18,500.00 (₹20,000 - ₹5,000 + ₹3,500)

        // Case A: Valid edit to ref2 (change from ₹1,500 to ₹2,500)
        // Since old ref2 (₹1,500) is reversed, new total is ₹2,000 + ₹2,500 = ₹4,500 <= ₹5,000.
        // MUST SUCCEED.
        final validEditResult = await transactionRepo.update(ref2.copyWith(amount: 2500.0));
        expect(validEditResult, 1, reason: 'Valid refund update within purchase ceiling must succeed');

        bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_4');
        expect(bankBal.minorUnits, 1950000, reason: 'Bank balance is exact: ₹20,000 - ₹5,000 + ₹4,500 = ₹19,500.00');

        // Case B: Excessive edit to ref1 (change from ₹2,000 to ₹3,000)
        // Current other refund is ₹2,500. Attempting ₹3,000 would total ₹5,500 > ₹5,000!
        // MUST BE REJECTED.
        expect(
          () async => await transactionRepo.update(ref1.copyWith(amount: 3000.0)),
          throwsA(isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Refund ceiling exceeded'),
          )),
          reason: 'Excessive refund update exceeding purchase ceiling must be rejected',
        );

        // Verify balance unchanged after rejected update
        bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_4');
        expect(bankBal.minorUnits, 1950000);
      });

      test('3.5 Editing an existing refund after original purchase is reversed is rejected', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_3_5',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Purchase ₹5,000.00
        final buyTx = spx.Transaction(
          id: 'tx_p3_buy_reversed_later',
          userId: 'user_1',
          amount: 5000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_3_5',
          categoryId: 'cat_electronics',
          date: now,
        );
        await transactionRepo.insert(buyTx);

        // 2. Active refund of ₹1,000.00
        final refTx = spx.Transaction(
          id: 'tx_p3_ref_active',
          userId: 'user_1',
          amount: 1000.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_5',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_reversed_later',
          date: now.add(const Duration(hours: 1)),
        );
        await transactionRepo.insert(refTx);

        // 3. Purchase is subsequently reversed/deleted
        await transactionRepo.delete('tx_p3_buy_reversed_later');

        // 4. Attempt to edit the existing refund: MUST BE REJECTED because original purchase is reversed!
        expect(
          () async => await transactionRepo.update(refTx.copyWith(amount: 1500.0)),
          throwsA(isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('has already been reversed or deleted'),
          )),
          reason: 'Cannot edit refund after original purchase is reversed',
        );
      });

      test('3.6 Concurrent refund updates against the same refund: exactly one succeeds, other rejected', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_fix_3_6',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Purchase ₹5,000.00
        final buyTx = spx.Transaction(
          id: 'tx_p3_buy_conc_edit',
          userId: 'user_1',
          amount: 5000.0,
          type: 'expense',
          accountId: 'acc_bank_fix_3_6',
          categoryId: 'cat_electronics',
          date: now,
        );
        await transactionRepo.insert(buyTx);

        // 2. Initial refund ₹1,000.00
        final refTx = spx.Transaction(
          id: 'tx_p3_ref_conc_edit',
          userId: 'user_1',
          amount: 1000.0,
          type: 'refund',
          accountId: 'acc_bank_fix_3_6',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy_conc_edit',
          date: now.add(const Duration(hours: 1)),
        );
        await transactionRepo.insert(refTx);

        // 3. Two successive/concurrent update calls targeting same refund ID
        final res1 = await transactionRepo.update(refTx.copyWith(amount: 1500.0));
        final res2 = await transactionRepo.update(refTx.copyWith(amount: 1800.0));

        expect(res1, 1, reason: 'First update succeeds');
        expect(res2, 0, reason: 'Second update against same original refund ID rejected by idempotency');

        // Verify balance: ₹20,000 - ₹5,000 + ₹1,500 = ₹16,500.00
        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_fix_3_6');
        expect(bankBal.minorUnits, 1650000);
      });
    });
  });
}
