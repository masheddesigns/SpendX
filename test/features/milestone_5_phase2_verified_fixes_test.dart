import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone 5.0 Phase 2 Verified Fixes Suite (DEF-505, DEF-506, DEF-507, DEF-508)', () {
    late Database db;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late AccountRepo accountRepo;

    CanonicalEventRepository _getEventRepo(DatabaseExecutor executor) =>
        CanonicalEventRepository(executor: executor);

    setUp(() async {
      DatabaseAccessGate.instance.resetForTesting();

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

      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);

      final now = DateTime(2026, 11, 1, 10, 0);
      final bank = BankAccount(
        id: 'acc_bank_test',
        userId: 'user_1',
        name: 'HDFC Bank',
        bank: 'HDFC',
        balance: 100000.0,
        accountType: 'checking',
        createdAt: now,
        updatedAt: now,
      );
      await accountRepo.insertAccount(bank);
    });

    tearDown(() async {
      await db.close();
      DatabaseAccessGate.instance.resetForTesting();
    });

    // =========================================================================
    // DEF-505 Verified Fix: Credit Card Transaction Projection
    // =========================================================================
    group('DEF-505: Credit Card Transaction Projection Fixes', () {
      test('1. Reversed original purchase does NOT appear in getTransactions; reversal event is excluded', () async {
        final card = CreditCard(
          id: 'card_505_fix_1',
          name: 'Amazon ICICI',
          bank: 'ICICI',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        final purchase = CreditTransaction(
          id: 'tx_p505_fix_1',
          cardId: 'card_505_fix_1',
          amount: 2500.0,
          date: DateTime(2026, 11, 2, 14, 0),
          category: 'Shopping',
          note: 'Monitor Stand',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        );
        await creditRepo.insertTransaction(purchase);

        // Before delete: 1 transaction visible
        var history = await creditRepo.getTransactions('card_505_fix_1');
        expect(history.length, 1);
        expect(history.first.id, 'tx_p505_fix_1');

        // Delete / reverse purchase
        await creditRepo.deleteTransaction('tx_p505_fix_1');

        // After delete: getTransactions must NOT show the reversed purchase,
        // and must NOT show the reversal event as a phantom purchase or payment.
        history = await creditRepo.getTransactions('card_505_fix_1');
        expect(history.isEmpty, isTrue, reason: 'Reversed purchase and reversal event are cleanly excluded');

        // Ledger liability must be exactly 0
        final bal = await creditRepo.getDerivedBalance('card_505_fix_1');
        expect(bal.toRupees, 0.0);

        // getTransactionById should reflect 'reversed' status
        final tx = await creditRepo.getTransactionById('tx_p505_fix_1');
        expect(tx, isNotNull);
        expect(tx!.status, 'reversed');
      });

      test('2. Legitimate payments and unreversed purchases remain visible with correct types', () async {
        final card = CreditCard(
          id: 'card_505_fix_2',
          name: 'Axis Ace',
          bank: 'Axis',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          dueDay: 20,
          billingDay: 5,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        // Purchase of ₹4,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_p505_fix_2',
          cardId: 'card_505_fix_2',
          amount: 4000.0,
          date: DateTime(2026, 11, 2),
          category: 'Electronics',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Payment of ₹1,500
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_pay505_fix_2',
          cardId: 'card_505_fix_2',
          amount: 1500.0,
          date: DateTime(2026, 11, 3),
          category: 'Payment',
          type: 'payment',
          status: 'active',
          categoryId: 'acc_bank_test',
        ));

        final history = await creditRepo.getTransactions('card_505_fix_2');
        expect(history.length, 2);

        final p = history.firstWhere((t) => t.id == 'tx_p505_fix_2');
        expect(p.type, 'purchase');
        expect(p.amount, 4000.0);
        expect(p.status, 'active');

        final pay = history.firstWhere((t) => t.id == 'tx_pay505_fix_2');
        expect(pay.type, 'payment');
        expect(pay.amount, 1500.0);
        expect(pay.status, 'active');

        final bal = await creditRepo.getDerivedBalance('card_505_fix_2');
        expect(bal.toRupees, 2500.0); // 4000 - 1500 = 2500
      });

      test('3. Repeated deletion attempts are rejected idempotently without balance drift', () async {
        final card = CreditCard(
          id: 'card_505_fix_3',
          name: 'OneCard',
          bank: 'Federal',
          limitAmount: 50000.0,
          usedAmount: 0.0,
          dueDay: 10,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_del_twice',
          cardId: 'card_505_fix_3',
          amount: 1000.0,
          date: DateTime(2026, 11, 2),
          category: 'Food',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // First deletion succeeds
        await creditRepo.deleteTransaction('tx_del_twice');
        expect((await creditRepo.getDerivedBalance('card_505_fix_3')).toRupees, 0.0);

        // Second deletion call: must be idempotent no-op
        await creditRepo.deleteTransaction('tx_del_twice');
        expect((await creditRepo.getDerivedBalance('card_505_fix_3')).toRupees, 0.0);

        // Count reversals: exactly 1 reversal exists
        final revCount = await db.rawQuery(
          'SELECT COUNT(*) as count FROM ${TablesV24.economicEvents} WHERE reversal_of_event_id = ?',
          ['tx_del_twice'],
        );
        expect(revCount.first['count'], 1);
      });
    });

    // =========================================================================
    // DEF-506 Verified Fix: Point-in-Time Statement Reconciliation
    // =========================================================================
    group('DEF-506: Point-in-Time Statement Reconciliation Fixes', () {
      test('1. Point-in-time statement reconciliation preserves post-statement transactions', () async {
        final card = CreditCard(
          id: 'card_506_fix_1',
          name: 'HDFC Millennia',
          bank: 'HDFC',
          limitAmount: 150000.0,
          usedAmount: 0.0,
          dueDay: 20,
          billingDay: 31,
          createdAt: DateTime(2026, 10, 1),
        );
        await creditRepo.insert(card);

        // Purchase up to Oct 31 (Statement period): ₹8,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_stmt_oct',
          cardId: 'card_506_fix_1',
          amount: 8000.0,
          date: DateTime(2026, 10, 25),
          category: 'Shopping',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Purchase in November (After statement date): ₹2,500
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_post_nov',
          cardId: 'card_506_fix_1',
          amount: 2500.0,
          date: DateTime(2026, 11, 2),
          category: 'Dining',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Real-time liability before reconciliation is ₹10,500
        expect((await creditRepo.getDerivedBalance('card_506_fix_1')).toRupees, 10500.0);

        // Reconcile statement balance of ₹8,000 as of October 31
        final statementClosingDate = DateTime.utc(2026, 10, 31, 23, 59, 59);
        await creditRepo.reconcileOutstanding(
          'card_506_fix_1',
          8000.0,
          statementClosingDate: statementClosingDate,
          reason: 'October Statement Balance',
        );

        // VERIFIED FIX:
        // Because derived liability as of Oct 31 was already ₹8,000, delta = 0!
        // No artificial equity adjustment is created, and the November purchase is PRESERVED!
        final balanceAfter = await creditRepo.getDerivedBalance('card_506_fix_1');
        expect(balanceAfter.toRupees, 10500.0,
            reason: 'November purchase is preserved; total liability remains ₹10,500');
      });

      test('2. Discrepancy in statement period is adjusted without affecting subsequent purchases', () async {
        final card = CreditCard(
          id: 'card_506_fix_2',
          name: 'HDFC Millennia',
          bank: 'HDFC',
          limitAmount: 150000.0,
          usedAmount: 0.0,
          dueDay: 20,
          billingDay: 31,
          createdAt: DateTime(2026, 10, 1),
        );
        await creditRepo.insert(card);

        // Purchase in October: ₹8,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_oct_2',
          cardId: 'card_506_fix_2',
          amount: 8000.0,
          date: DateTime(2026, 10, 20),
          category: 'Shopping',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Purchase in November: ₹2,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_nov_2',
          cardId: 'card_506_fix_2',
          amount: 2000.0,
          date: DateTime(2026, 11, 2),
          category: 'Groceries',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Statement says October closing was ₹8,500 (discrepancy of +₹500, e.g. unrecorded interest charge)
        final statementClosingDate = DateTime.utc(2026, 10, 31, 23, 59, 59);
        await creditRepo.reconcileOutstanding(
          'card_506_fix_2',
          8500.0,
          statementClosingDate: statementClosingDate,
          reason: 'October Statement Adjustment',
        );

        // VERIFIED FIX:
        // Adjustment of +₹500 is posted as of Oct 31.
        // Total liability becomes ₹8,500 + ₹2,000 (Nov) = ₹10,500!
        final balanceAfter = await creditRepo.getDerivedBalance('card_506_fix_2');
        expect(balanceAfter.toRupees, 10500.0,
            reason: 'Statement discrepancy adjusted (+₹500) while fully preserving November purchase (+₹2,000)');

        // Provenance metadata contains statement closing date
        final recRows = await db.query(TablesV24.openingBalanceReconciliations);
        expect(recRows.isNotEmpty, isTrue);
        expect(recRows.last['reconciliation_reason'], contains('2026-10-31'));
      });
    });

    // =========================================================================
    // DEF-507 Verified Fix: Indexed External Reference Deduplication
    // =========================================================================
    group('DEF-507: Indexed External Reference Deduplication Fixes', () {
      test('1. Disbursement populates external_reference column and rejects duplicate even with encrypted payload', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final loan = Loan(
          id: 'loan_507_fix',
          name: 'Home Loan',
          bank: 'SBI',
          total: 1000000.0,
          interestRate: 8.5,
          tenureMonths: 120,
          monthlyInstallment: 12500.0,
          startDate: now,
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        );
        await loanRepo.insertLoan(loan);

        // Record first disbursement with externalRef 'UTR_SBI_987654'
        await loanRepo.recordDisbursement(
          loanId: 'loan_507_fix',
          assetAccountId: 'acc_bank_test',
          amount: 500000.0,
          timestamp: now,
          externalRef: 'UTR_SBI_987654',
        );

        // Inspect evidence row: external_reference MUST be populated
        final evidenceRows = await db.query(
          TablesV24.evidence,
          where: 'external_reference = ?',
          whereArgs: ['UTR_SBI_987654'],
        );
        expect(evidenceRows.length, 1, reason: 'Indexed column external_reference is populated');

        // Simulate that the raw payload was encrypted in production
        await db.update(
          TablesV24.evidence,
          {'raw_payload_encrypted': 'AES256:GCM:aW52YWxpZF9jaXBoZXJ0ZXh0'},
          where: 'external_reference = ?',
          whereArgs: ['UTR_SBI_987654'],
        );

        // VERIFIED FIX:
        // Attempt duplicate disbursement: must be rejected via the indexed external_reference column!
        expect(
          () async => await loanRepo.recordDisbursement(
            loanId: 'loan_507_fix',
            assetAccountId: 'acc_bank_test',
            amount: 500000.0,
            timestamp: now.add(const Duration(minutes: 5)),
            externalRef: 'UTR_SBI_987654',
          ),
          throwsA(isA<AccountingInvariantException>()),
          reason: 'Duplicate external reference is rejected via indexed column',
        );
      });

      test('2. Repayment populates external_reference and rejects duplicate', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final loan = Loan(
          id: 'loan_507_repay',
          name: 'Bike Loan',
          bank: 'HDFC',
          total: 80000.0,
          interestRate: 11.0,
          tenureMonths: 24,
          monthlyInstallment: 4000.0,
          startDate: now,
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        );
        await loanRepo.insertLoan(loan);

        await loanRepo.recordRepayment(
          loanId: 'loan_507_repay',
          assetAccountId: 'acc_bank_test',
          principalAmount: 4000.0,
          timestamp: now,
          externalRef: 'UPI_REPAY_001',
        );

        expect(
          () async => await loanRepo.recordRepayment(
            loanId: 'loan_507_repay',
            assetAccountId: 'acc_bank_test',
            principalAmount: 4000.0,
            timestamp: now.add(const Duration(hours: 1)),
            externalRef: 'UPI_REPAY_001',
          ),
          throwsA(isA<AccountingInvariantException>()),
        );
      });

      test('3. Distinct and null external references succeed normally', () async {
        final now = DateTime(2026, 11, 1, 10, 0);
        final loan = Loan(
          id: 'loan_507_distinct',
          name: 'Education Loan',
          bank: 'ICICI',
          total: 200000.0,
          interestRate: 9.0,
          tenureMonths: 36,
          monthlyInstallment: 6500.0,
          startDate: now,
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        );
        await loanRepo.insertLoan(loan);

        // Distinct references succeed
        await loanRepo.recordDisbursement(
          loanId: 'loan_507_distinct',
          assetAccountId: 'acc_bank_test',
          amount: 50000.0,
          timestamp: now,
          externalRef: 'REF_DISTINCT_A',
        );
        await loanRepo.recordDisbursement(
          loanId: 'loan_507_distinct',
          assetAccountId: 'acc_bank_test',
          amount: 50000.0,
          timestamp: now.add(const Duration(minutes: 1)),
          externalRef: 'REF_DISTINCT_B',
        );

        // Null references succeed
        await loanRepo.recordDisbursement(
          loanId: 'loan_507_distinct',
          assetAccountId: 'acc_bank_test',
          amount: 25000.0,
          timestamp: now.add(const Duration(minutes: 2)),
          externalRef: null,
        );

        expect(
          (await loanRepo.getDerivedBalance('loan_507_distinct')).toRupees,
          325000.0, // 200k opening + 50k + 50k + 25k
        );
      });
    });

    // =========================================================================
    // DEF-508 Verified Fix: Credit Card Refund Ceiling & Association
    // =========================================================================
    group('DEF-508: Credit Card Refund Ceiling & Validation Fixes', () {
      test('1. Partial and successive refunds linked to purchase succeed within ceiling', () async {
        final card = CreditCard(
          id: 'card_508_fix_1',
          name: 'Flipkart Axis',
          bank: 'Axis',
          limitAmount: 50000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        // Original purchase: ₹1,000
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_orig_purchase_508',
          cardId: 'card_508_fix_1',
          amount: 1000.0,
          date: DateTime(2026, 11, 2),
          category: 'Shopping',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));
        expect((await creditRepo.getDerivedBalance('card_508_fix_1')).toRupees, 1000.0);

        // Partial refund 1: ₹400
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_refund_1',
          cardId: 'card_508_fix_1',
          amount: 400.0,
          date: DateTime(2026, 11, 3),
          category: 'Shopping',
          type: 'refund',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
          relatedEntityId: 'tx_orig_purchase_508',
        ));
        expect((await creditRepo.getDerivedBalance('card_508_fix_1')).toRupees, 600.0);

        // Partial refund 2: ₹600 (remaining ceiling is ₹600)
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_refund_2',
          cardId: 'card_508_fix_1',
          amount: 600.0,
          date: DateTime(2026, 11, 4),
          category: 'Shopping',
          type: 'refund',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
          relatedEntityId: 'tx_orig_purchase_508',
        ));
        expect((await creditRepo.getDerivedBalance('card_508_fix_1')).toRupees, 0.0);

        // Attempt excessive refund 3: ₹50 -> MUST BE REJECTED (remaining ceiling is ₹0)
        expect(
          () async => await creditRepo.insertTransaction(CreditTransaction(
            id: 'tx_refund_excess',
            cardId: 'card_508_fix_1',
            amount: 50.0,
            date: DateTime(2026, 11, 5),
            category: 'Shopping',
            type: 'refund',
            status: 'active',
            categoryId: TablesV24.sysExpMisc,
            relatedEntityId: 'tx_orig_purchase_508',
          )),
          throwsA(isA<AccountingInvariantException>()),
          reason: 'Excessive refund beyond original purchase amount is rejected',
        );

        expect((await creditRepo.getDerivedBalance('card_508_fix_1')).toRupees, 0.0);
      });

      test('2. Refund against deleted or reversed purchase is strictly rejected', () async {
        final card = CreditCard(
          id: 'card_508_fix_2',
          name: 'Flipkart Axis',
          bank: 'Axis',
          limitAmount: 50000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        // Purchase of ₹800
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_to_reverse_508',
          cardId: 'card_508_fix_2',
          amount: 800.0,
          date: DateTime(2026, 11, 2),
          category: 'Dining',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // Delete purchase
        await creditRepo.deleteTransaction('tx_to_reverse_508');
        expect((await creditRepo.getDerivedBalance('card_508_fix_2')).toRupees, 0.0);

        // Attempt refund against the reversed purchase -> REJECTED
        expect(
          () async => await creditRepo.insertTransaction(CreditTransaction(
            id: 'tx_refund_on_reversed',
            cardId: 'card_508_fix_2',
            amount: 800.0,
            date: DateTime(2026, 11, 3),
            category: 'Dining',
            type: 'refund',
            status: 'active',
            categoryId: TablesV24.sysExpMisc,
            relatedEntityId: 'tx_to_reverse_508',
          )),
          throwsA(isA<AccountingInvariantException>()),
          reason: 'Refund against reversed purchase is rejected',
        );
      });

      test('3. Refund against non-existent purchase ID is rejected', () async {
        final card = CreditCard(
          id: 'card_508_fix_3',
          name: 'Flipkart Axis',
          bank: 'Axis',
          limitAmount: 50000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        expect(
          () async => await creditRepo.insertTransaction(CreditTransaction(
            id: 'tx_refund_bogus',
            cardId: 'card_508_fix_3',
            amount: 200.0,
            date: DateTime(2026, 11, 3),
            category: 'Shopping',
            type: 'refund',
            status: 'active',
            categoryId: TablesV24.sysExpMisc,
            relatedEntityId: 'bogus_nonexistent_purchase_id',
          )),
          throwsA(isA<AccountingInvariantException>()),
        );
      });

      test('4. Refund retains related_entity_id in metadata while evidence externalReference is strictly statementId', () async {
        final card = CreditCard(
          id: 'card_508_fix_4',
          name: 'SBI Cashback',
          bank: 'SBI',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          dueDay: 15,
          billingDay: 1,
          createdAt: DateTime(2026, 11, 1),
        );
        await creditRepo.insert(card);

        // 1. Original purchase
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_orig_purchase_508_ev',
          cardId: 'card_508_fix_4',
          amount: 2000.0,
          date: DateTime(2026, 11, 2),
          category: 'Shopping',
          type: 'purchase',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
        ));

        // 2. Refund with null statementId: relatedEntityId must be in event metadata,
        // but evidence.external_reference MUST be null (never fall back to relatedEntityId)
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_refund_null_stmt',
          cardId: 'card_508_fix_4',
          amount: 500.0,
          date: DateTime(2026, 11, 3),
          category: 'Shopping',
          type: 'refund',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
          relatedEntityId: 'tx_orig_purchase_508_ev',
          statementId: null,
        ));

        final ev1 = await _getEventRepo(db).getEvent('tx_refund_null_stmt');
        expect(ev1, isNotNull);
        expect(ev1!.metadata['related_entity_id'], equals('tx_orig_purchase_508_ev'),
            reason: 'Refund retains original purchase relationship in event metadata');

        final eviRows1 = await db.query(
          TablesV24.evidence,
          where: 'economic_event_id = ?',
          whereArgs: ['tx_refund_null_stmt'],
        );
        expect(eviRows1.isNotEmpty, isTrue);
        expect(eviRows1.first['external_reference'], isNull,
            reason: 'Null statementId must produce null evidence.external_reference without falling back to related_entity_id');

        // 3. Refund with explicit statementId: evidence.external_reference MUST equal statementId
        await creditRepo.insertTransaction(CreditTransaction(
          id: 'tx_refund_with_stmt',
          cardId: 'card_508_fix_4',
          amount: 300.0,
          date: DateTime(2026, 11, 4),
          category: 'Shopping',
          type: 'refund',
          status: 'active',
          categoryId: TablesV24.sysExpMisc,
          relatedEntityId: 'tx_orig_purchase_508_ev',
          statementId: 'stmt_nov_2026_hdfc',
        ));

        final ev2 = await _getEventRepo(db).getEvent('tx_refund_with_stmt');
        expect(ev2, isNotNull);
        expect(ev2!.metadata['related_entity_id'], equals('tx_orig_purchase_508_ev'));

        final eviRows2 = await db.query(
          TablesV24.evidence,
          where: 'economic_event_id = ?',
          whereArgs: ['tx_refund_with_stmt'],
        );
        expect(eviRows2.isNotEmpty, isTrue);
        expect(eviRows2.first['external_reference'], equals('stmt_nov_2026_hdfc'),
            reason: 'Evidence.external_reference is populated strictly from statementId');

        // 4. Verify refund ceiling is still enforced (2000 - 500 - 300 = 1200 remaining)
        expect(
          () async => await creditRepo.insertTransaction(CreditTransaction(
            id: 'tx_refund_excess_check',
            cardId: 'card_508_fix_4',
            amount: 1500.0,
            date: DateTime(2026, 11, 5),
            category: 'Shopping',
            type: 'refund',
            status: 'active',
            categoryId: TablesV24.sysExpMisc,
            relatedEntityId: 'tx_orig_purchase_508_ev',
          )),
          throwsA(isA<AccountingInvariantException>()),
          reason: 'Refund ceiling calculation remains fully functional after field decoupling',
        );
      });

      test('5. Double-entry trial balance holds across all operations', () async {
        // Assert that the global ledger debits == credits
        final result = await db.rawQuery('''
          SELECT
            SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END) as total_debit,
            SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END) as total_credit
          FROM ${TablesV24.postings} p
          JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
          WHERE e.lifecycle_status = 'posted'
        ''');

        final totalDebit = result.first['total_debit'] as int? ?? 0;
        final totalCredit = result.first['total_credit'] as int? ?? 0;

        expect(totalDebit, equals(totalCredit), reason: 'Trial balance: total debits must equal total credits');
      });
    });
  });
}
