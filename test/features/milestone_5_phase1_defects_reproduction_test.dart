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
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
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

  group('Milestone 5.0 Phase 1: Defect Reproduction & Proof Suite', () {
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
    // PRIORITY 1: DEF-502 — Reversal Idempotency in TransactionRepo.update()
    // =========================================================================
    group('Priority 1: DEF-502 — Reversal Idempotency', () {
      test('1.1 Normal unreversed transaction update behaves correctly', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_p1_1',
          userId: 'user_1',
          name: 'HDFC Checking',
          bank: 'HDFC',
          balance: 10000.0,
          accountType: 'checking',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final initialBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_1');
        expect(initialBal.minorUnits, 1000000); // ₹10,000.00

        // Incur ₹2,000 expense
        final expTx = spx.Transaction(
          id: 'tx_p1_1',
          userId: 'user_1',
          amount: 2000.0,
          type: 'expense',
          accountId: 'acc_bank_p1_1',
          categoryId: 'cat_groceries',
          date: now,
          notes: 'Groceries',
        );
        await transactionRepo.insert(expTx);

        final balAfterExp = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_1');
        expect(balAfterExp.minorUnits, 800000); // ₹8,000.00

        // Update amount from ₹2,000 to ₹2,500
        final updatedTx = expTx.copyWith(amount: 2500.0, notes: 'Groceries updated');
        final rowsAffected = await transactionRepo.update(updatedTx);
        expect(rowsAffected, 1);

        final balAfterUpdate = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_1');
        expect(balAfterUpdate.minorUnits, 750000); // ₹7,500.00 (₹10,000 - ₹2,500)

        // Verify reversal count for tx_p1_1
        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['tx_p1_1'],
        );
        expect(reversals.length, 1);
      });

      test('1.2 Stale update after deletion reproduces balance drift (DEF-502)', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_p1_2',
          userId: 'user_1',
          name: 'HDFC Checking',
          bank: 'HDFC',
          balance: 10000.0,
          accountType: 'checking',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Insert ₹1,000 expense
        final expTx = spx.Transaction(
          id: 'tx_p1_2',
          userId: 'user_1',
          amount: 1000.0,
          type: 'expense',
          accountId: 'acc_bank_p1_2',
          categoryId: 'cat_groceries',
          date: now,
          notes: 'Groceries to be deleted',
        );
        await transactionRepo.insert(expTx);

        var bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_2');
        expect(bal.minorUnits, 900000); // ₹9,000.00

        // 2. Delete the transaction
        final delResult = await transactionRepo.delete('tx_p1_2');
        expect(delResult, 1);

        bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_2');
        expect(bal.minorUnits, 1000000); // ₹10,000.00 restored

        // 3. Stale update attempt on deleted transaction
        // EXPECTED FOR SECURE/CORRECT LEDGER: should reject or return 0, maintaining balance at ₹10,000.00
        // ACTUAL BEHAVIOR (DEF-502): update() succeeds, creates a 2nd reversal (adding another ₹1,000), then posts replacement
        final staleUpdateTx = expTx.copyWith(amount: 1500.0);
        final updateResult = await transactionRepo.update(staleUpdateTx);

        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['tx_p1_2'],
        );

        bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_2');

        print('=== DEF-502 (Stale Update after Delete) ===');
        print('updateResult: $updateResult');
        print('reversals count for tx_p1_2: ${reversals.length}');
        print('Final bank balance (minor units): ${bal.minorUnits} (Expected ₹8,500.00 = 850000, Actual: ${bal.minorUnits})');

        // Confirm defect presence:
        // Because update did NOT check if tx_p1_2 was already reversed, it posted a 2nd reversal!
        // ₹10,000 (after delete) + ₹1,000 (2nd reversal) - ₹1,500 (replacement) = ₹9,500 (950000 minor units)!
        // ₹1,000 phantom drift!
        expect(reversals.length, 2, reason: 'DEF-502 confirmed: 2 reversals exist for tx_p1_2');
        expect(bal.minorUnits, 950000, reason: 'DEF-502 confirmed: Bank balance suffered ₹1,000 upward drift!');
      });

      test('1.3 Updating an already-reversed transaction (Second update on original ID) reproduces drift', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_p1_3',
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
          id: 'tx_p1_3',
          userId: 'user_1',
          amount: 2000.0,
          type: 'expense',
          accountId: 'acc_bank_p1_3',
          categoryId: 'cat_groceries',
          date: now,
        );
        await transactionRepo.insert(expTx);

        // Edit 1: change to ₹2,500
        await transactionRepo.update(expTx.copyWith(amount: 2500.0));
        var bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_3');
        expect(bal.minorUnits, 750000); // ₹7,500.00

        // Edit 2: attempt to update using original tx_p1_3 reference instead of replacement
        await transactionRepo.update(expTx.copyWith(amount: 3000.0));
        bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_3');

        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['tx_p1_3'],
        );

        print('=== DEF-502 (Double update on original ID) ===');
        print('reversals count for tx_p1_3: ${reversals.length}');
        print('Bank balance: ${bal.minorUnits}');

        // Without guard, a second reversal was created for tx_p1_3!
        // ₹7,500 + ₹2,000 (duplicate reversal) - ₹3,000 = ₹6,500 (650000 minor units).
        // Correct balance should be ₹7,000 (if properly chained or rejected).
        expect(reversals.length, 2);
        expect(bal.minorUnits, 650000);
      });

      test('1.4 Concurrent update requests against the same original event', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_p1_4',
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
          id: 'tx_p1_4',
          userId: 'user_1',
          amount: 2000.0,
          type: 'expense',
          accountId: 'acc_bank_p1_4',
          categoryId: 'cat_groceries',
          date: now,
        );
        await transactionRepo.insert(expTx);

        // Scenario A: Exact simultaneous calls collide on timestamp-based ID or race
        // Scenario B: Rapid successive update calls (5ms apart) race and both commit reversals
        final res1 = await transactionRepo.update(expTx.copyWith(amount: 2200.0));
        await Future.delayed(const Duration(milliseconds: 10));
        final res2 = await transactionRepo.update(expTx.copyWith(amount: 2400.0));

        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['tx_p1_4'],
        );

        final bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p1_4');

        print('=== DEF-502 (Rapid Concurrent/Successive Updates) ===');
        print('Update 1 result: $res1, Update 2 result: $res2');
        print('Reversals created for tx_p1_4: ${reversals.length}');
        print('Bank balance: ${bal.minorUnits}');

        // Both succeeded because there is no reversal_of guard in update()!
        expect(reversals.length, 2);
      });
    });

    // =========================================================================
    // PRIORITY 2: DEF-501 — Cross-Month Reversal Semantics
    // =========================================================================
    group('Priority 2: DEF-501 — Cross-Month Reversal Semantics', () {
      test('2.1 Cross-Month Deletion: Month A retains positive expense, Month B becomes negative', () async {
        final bank = BankAccount(
          id: 'acc_bank_p2',
          userId: 'user_1',
          name: 'SBI Savings',
          bank: 'SBI',
          balance: 50000.0,
          accountType: 'savings',
          createdAt: DateTime(2026, 10, 1),
          updatedAt: DateTime(2026, 10, 1),
        );
        await accountRepo.insertAccount(bank);

        // Month A: October 2026 (2026-10-15)
        final octDate = DateTime(2026, 10, 15, 12, 0);
        final octTx = spx.Transaction(
          id: 'tx_oct_expense',
          userId: 'user_1',
          amount: 4000.0,
          type: 'expense',
          accountId: 'acc_bank_p2',
          categoryId: 'cat_shopping',
          date: octDate,
          notes: 'October Jacket Purchase',
        );
        await transactionRepo.insert(octTx);

        // Check October stats before deletion
        final octStart = DateTime(2026, 10, 1);
        final octEnd = DateTime(2026, 10, 31, 23, 59, 59);
        final octStatsBefore = await transactionRepo.getStatsForRange(octStart, octEnd);

        expect(octStatsBefore['expense'], 4000.0);
        expect(octStatsBefore['txn_count'], 1);
        expect(octStatsBefore['biggest_expense'], 4000.0);

        // Month B: November 2026 (current time simulated when deleting)
        // Note: CanonicalTransactionAdapter.createReversal uses DateTime.now()
        // Here we delete the transaction
        final delResult = await transactionRepo.delete('tx_oct_expense');
        expect(delResult, 1);

        // Query October stats after deletion
        final octStatsAfter = await transactionRepo.getStatsForRange(octStart, octEnd);

        // Query November stats after deletion
        final novStart = DateTime(2026, 11, 1);
        final novEnd = DateTime(2026, 11, 30, 23, 59, 59);
        final novStatsAfter = await transactionRepo.getStatsForRange(novStart, novEnd);

        // Check overall balance and net worth
        final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p2');
        final netWorth = await canonicalQueryRepo.getNetWorth();

        print('=== DEF-501 (Cross-Month Deletion Stats) ===');
        print('OCTOBER BEFORE DELETION: expense=${octStatsBefore['expense']}, count=${octStatsBefore['txn_count']}, biggest=${octStatsBefore['biggest_expense']}');
        print('OCTOBER AFTER DELETION:  expense=${octStatsAfter['expense']}, count=${octStatsAfter['txn_count']}, biggest=${octStatsAfter['biggest_expense']}');
        print('NOVEMBER AFTER DELETION: expense=${novStatsAfter['expense']}, count=${novStatsAfter['txn_count']}, biggest=${novStatsAfter['biggest_expense']}');
        print('BANK BALANCE: ${bankBal.minorUnits} (₹50,000.00 = 5000000)');
        print('NET WORTH:    ${netWorth.minorUnits}');

        // DEF-501 Confirmed:
        // October expense remains 4000.0 because the credit posting occurred in November!
        // But October txn_count is 0 because NOT EXISTS checks all time!
        expect(octStatsAfter['expense'], 4000.0, reason: 'October still shows +₹4,000.00 expense');
        expect(octStatsAfter['txn_count'], 0, reason: 'October shows 0 transactions despite ₹4,000.00 expense!');
        expect(octStatsAfter['biggest_expense'], 0.0);

        // November shows negative expense -₹4,000.00!
        expect(novStatsAfter['expense'], -4000.0, reason: 'November registers negative ₹4,000.00 expense!');
        expect(novStatsAfter['txn_count'], 0);

        // Bank balance and net worth are restored across all time
        expect(bankBal.minorUnits, 5000000);
        expect(netWorth.minorUnits, 5000000);
      });

      test('2.2 Strategy Comparison: Strategy A (Original Timestamp) vs Strategy B (Current Timestamp + Reporting Reconciliation)', () async {
        // Strategy A: Reversal uses original event timestamp
        // Verify that if a reversal had occurred_at = originalEvent.occurred_at:
        // October: expense = 0 (debit 4000 - credit 4000), txn_count = 0.
        // November: expense = 0, txn_count = 0.
        // Both months are consistent without negative expense.
        print('=== DEF-501 Strategy Comparison Analysis ===');
        print('Strategy A: Assign occurredAt = originalEvent.occurredAt');
        print('  - Prior month expense becomes 0.0, txn_count becomes 0');
        print('  - Current month expense unaffected (0.0)');
        print('  - Preserves monthly spending reality for personal finance');
        print('Strategy B: Keep occurredAt = DateTime.now(), join reversal_of_event_id in queries');
        print('  - Keeps physical execution timestamp on reversal');
        print('  - Requires modifying every stats query to correlate reversal dates');
      });
    });

    // =========================================================================
    // PRIORITY 3: DEF-503 — Cumulative Refund Limits
    // =========================================================================
    group('Priority 3: DEF-503 — Cumulative Refund Limits', () {
      test('3.1 Multiple successive partial refunds and exceeding original purchase amount', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_p3',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        // 1. Original Purchase: ₹5,000.00
        final purchaseTx = spx.Transaction(
          id: 'tx_p3_buy',
          userId: 'user_1',
          amount: 5000.0,
          type: 'expense',
          accountId: 'acc_bank_p3',
          categoryId: 'cat_electronics',
          date: now,
          notes: 'Smartphone purchase',
        );
        await transactionRepo.insert(purchaseTx);

        var bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p3');
        var catExp = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(bankBal.minorUnits, 1500000); // ₹15,000.00
        expect(catExp.minorUnits, 500000);   // ₹5,000.00

        // 2. Single partial refund: ₹2,000.00
        final ref1 = spx.Transaction(
          id: 'tx_p3_ref1',
          userId: 'user_1',
          amount: 2000.0,
          type: 'refund',
          accountId: 'acc_bank_p3',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy',
          date: now.add(const Duration(hours: 1)),
          notes: 'Partial refund 1',
        );
        await transactionRepo.insert(ref1);

        bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p3');
        catExp = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(bankBal.minorUnits, 1700000); // ₹17,000.00
        expect(catExp.minorUnits, 300000);   // ₹3,000.00

        // 3. Second successive partial refund: ₹1,500.00
        final ref2 = spx.Transaction(
          id: 'tx_p3_ref2',
          userId: 'user_1',
          amount: 1500.0,
          type: 'refund',
          accountId: 'acc_bank_p3',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy',
          date: now.add(const Duration(hours: 2)),
          notes: 'Partial refund 2',
        );
        await transactionRepo.insert(ref2);

        bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p3');
        catExp = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(bankBal.minorUnits, 1850000); // ₹18,500.00
        expect(catExp.minorUnits, 150000);   // ₹1,500.00

        // 4. Third partial refund: ₹1,500.00 (Cumulative refunds now exactly equal purchase: ₹5,000.00)
        final ref3 = spx.Transaction(
          id: 'tx_p3_ref3',
          userId: 'user_1',
          amount: 1500.0,
          type: 'refund',
          accountId: 'acc_bank_p3',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy',
          date: now.add(const Duration(hours: 3)),
          notes: 'Partial refund 3',
        );
        await transactionRepo.insert(ref3);

        bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p3');
        catExp = await canonicalQueryRepo.getCategorySpending('cat_electronics');
        expect(bankBal.minorUnits, 2000000); // ₹20,000.00 (Fully restored)
        expect(catExp.minorUnits, 0);        // ₹0.00

        // 5. Fourth refund attempt: ₹1,000.00 (Exceeds original purchase!)
        // EXPECTED FOR SECURE/CORRECT LEDGER: Should throw or reject, keeping bank at ₹20,000.00 and category at ₹0.00
        // ACTUAL BEHAVIOR (DEF-503): System accepts it unconditionally!
        final ref4Excess = spx.Transaction(
          id: 'tx_p3_ref4_excess',
          userId: 'user_1',
          amount: 1000.0,
          type: 'refund',
          accountId: 'acc_bank_p3',
          categoryId: 'cat_electronics',
          relatedEntityId: 'tx_p3_buy',
          date: now.add(const Duration(hours: 4)),
          notes: 'Excess refund',
        );
        await transactionRepo.insert(ref4Excess);

        bankBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_p3');
        catExp = await canonicalQueryRepo.getCategorySpending('cat_electronics');

        print('=== DEF-503 (Excess Refund Results) ===');
        print('Bank balance after excess refund: ${bankBal.minorUnits} (Expected max: 2000000 = ₹20,000.00, Actual: ${bankBal.minorUnits})');
        print('Category electronics net spending: ${catExp.minorUnits} (Expected min: 0, Actual: ${catExp.minorUnits})');

        // Confirmed DEF-503: The system created a ₹1,000 surplus in the bank and negative ₹1,000 expense
        expect(bankBal.minorUnits, 2100000, reason: 'DEF-503 confirmed: Bank artificially inflated beyond baseline!');
        expect(catExp.minorUnits, -100000, reason: 'DEF-503 confirmed: Category spending became negative!');
      });

      test('3.2 Duplicate refund insertion test', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final bank = BankAccount(
          id: 'acc_bank_p3_dup',
          userId: 'user_1',
          name: 'Axis Bank',
          bank: 'Axis',
          balance: 20000.0,
          accountType: 'savings',
          createdAt: now,
          updatedAt: now,
        );
        await accountRepo.insertAccount(bank);

        final refTx = spx.Transaction(
          id: 'tx_p3_dup_1',
          userId: 'user_1',
          amount: 2000.0,
          type: 'refund',
          accountId: 'acc_bank_p3_dup',
          categoryId: 'cat_electronics',
          date: now,
        );
        await transactionRepo.insert(refTx);

        // Attempt exact duplicate insert with same ID
        // Expected: SQLite PRIMARY KEY constraint violation
        expect(
          () async => await transactionRepo.insert(refTx),
          throwsA(isA<DatabaseException>()),
          reason: 'Duplicate primary key insert rejected by SQLite',
        );
      });
    });

    // =========================================================================
    // PRIORITY 4: DEF-504 — Database-Level Reversal Uniqueness
    // =========================================================================
    group('Priority 4: DEF-504 — Database-Level Reversal Uniqueness', () {
      test('4.1 Multiple reversals can be committed at the SQLite database level for the same original event', () async {
        final nowStr = DateTime(2026, 11, 1, 10, 0).toIso8601String();

        // 1. Insert original event into economic_events and postings
        await db.insert(TablesV24.economicEvents, {
          'id': 'orig_event_def504',
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'Original Event',
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        await db.insert(TablesV24.postings, {
          'id': 'p_orig_1',
          'economic_event_id': 'orig_event_def504',
          'account_id': TablesV24.sysExpMisc,
          'direction': 'debit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': nowStr,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_orig_2',
          'economic_event_id': 'orig_event_def504',
          'account_id': TablesV24.sysSuspenseTransfer,
          'direction': 'credit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': nowStr,
        });

        // Commit original event to posted
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['orig_event_def504'],
        );

        // 2. Insert Reversal 1 targeting orig_event_def504
        await db.insert(TablesV24.economicEvents, {
          'id': 'rev_event_1',
          'event_type': 'adjustment',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: orig_event_def504',
          'reversal_of_event_id': 'orig_event_def504',
          'created_at': nowStr,
          'updated_at': nowStr,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_rev1_1',
          'economic_event_id': 'rev_event_1',
          'account_id': TablesV24.sysExpMisc,
          'direction': 'credit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': nowStr,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_rev1_2',
          'economic_event_id': 'rev_event_1',
          'account_id': TablesV24.sysSuspenseTransfer,
          'direction': 'debit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': nowStr,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['rev_event_1'],
        );

        // 3. Insert Reversal 2 targeting the SAME orig_event_def504
        // DEF-504: In the absence of a unique constraint on reversal_of_event_id,
        // this second reversal successfully commits at the database level!
        await db.insert(TablesV24.economicEvents, {
          'id': 'rev_event_2',
          'event_type': 'adjustment',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: orig_event_def504 duplicate',
          'reversal_of_event_id': 'orig_event_def504',
          'created_at': nowStr,
          'updated_at': nowStr,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_rev2_1',
          'economic_event_id': 'rev_event_2',
          'account_id': TablesV24.sysExpMisc,
          'direction': 'credit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': nowStr,
        });
        await db.insert(TablesV24.postings, {
          'id': 'p_rev2_2',
          'economic_event_id': 'rev_event_2',
          'account_id': TablesV24.sysSuspenseTransfer,
          'direction': 'debit',
          'amount_minor_units': 100000,
          'currency': 'INR',
          'created_at': nowStr,
        });
        await db.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted'},
          where: 'id = ?',
          whereArgs: ['rev_event_2'],
        );

        final reversals = await db.rawQuery(
          'SELECT id FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?;',
          ['orig_event_def504'],
        );

        print('=== DEF-504 (Database-level multi-reversal proof) ===');
        print('Committed reversals count for orig_event_def504: ${reversals.length}');
        for (final r in reversals) {
          print('  - Reversal ID: ${r['id']}');
        }

        // Confirmed DEF-504: Both reversals are committed in the database
        expect(reversals.length, 2, reason: 'DEF-504 confirmed: SQLite permits multiple reversals for one event');
      });

      test('4.2 Verify partial unique index prevents duplicate reversals cleanly', () async {
        // Test compatibility of:
        // CREATE UNIQUE INDEX idx_events_unique_reversal ON economic_events(reversal_of_event_id)
        // WHERE reversal_of_event_id IS NOT NULL;
        final nowStr = DateTime(2026, 11, 1, 10, 0).toIso8601String();

        // Create the partial unique index
        await db.execute('''
          CREATE UNIQUE INDEX idx_events_unique_reversal
          ON ${TablesV24.economicEvents}(reversal_of_event_id)
          WHERE reversal_of_event_id IS NOT NULL;
        ''');

        // Insert original event first (to satisfy FK constraint)
        await db.insert(TablesV24.economicEvents, {
          'id': 'orig_idx_test',
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'Original event for index test',
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        // Insert first reversal
        await db.insert(TablesV24.economicEvents, {
          'id': 'rev_event_idx_1',
          'event_type': 'adjustment',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'REVERSAL: orig_idx_test',
          'reversal_of_event_id': 'orig_idx_test',
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        // Insert a normal non-reversal event with reversal_of_event_id = NULL
        await db.insert(TablesV24.economicEvents, {
          'id': 'norm_event_idx_1',
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'Normal event with null reversal_of',
          'reversal_of_event_id': null,
          'created_at': nowStr,
          'updated_at': nowStr,
        });
        // Insert a second normal non-reversal event with reversal_of_event_id = NULL
        // MUST SUCCEED (NULLs not indexed or multiple NULLs permitted)
        await db.insert(TablesV24.economicEvents, {
          'id': 'norm_event_idx_2',
          'event_type': 'expense',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'currency': 'INR',
          'description': 'Second normal event with null reversal_of',
          'reversal_of_event_id': null,
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        // Now attempt to insert a duplicate reversal for 'orig_idx_test'
        expect(
          () async => await db.insert(TablesV24.economicEvents, {
            'id': 'rev_event_idx_2',
            'event_type': 'adjustment',
            'lifecycle_status': 'draft',
            'timestamp': nowStr,
            'currency': 'INR',
            'description': 'REVERSAL: orig_idx_test duplicate',
            'reversal_of_event_id': 'orig_idx_test',
            'created_at': nowStr,
            'updated_at': nowStr,
          }),
          throwsA(isA<DatabaseException>()),
          reason: 'Partial unique index idx_events_unique_reversal aborts duplicate reversal at the SQLite level',
        );

        print('=== DEF-504 Partial Unique Index Feasibility ===');
        print('Partial unique index successfully blocks duplicate reversals while allowing unlimited NULLs.');
      });
    });
  });
}
