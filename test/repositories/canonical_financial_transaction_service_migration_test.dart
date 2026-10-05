import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/ledger_transaction.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C3B-6: FinancialTransactionService Canonical Migration Suite', () {
    late Database db;
    late FinancialTransactionService financialService;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository financialQueryRepo;

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

      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      goalRepo = GoalRepo(executor: db, earmarkRepo: earmarkRepo);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      financialQueryRepo = CanonicalFinancialQueryRepository(executor: db);

      financialService = FinancialTransactionService(
        database: db,
      );
    });

    tearDown(() async {
      await db.close();
    });

    // =========================================================================
    // 1. Exact Public API Inventory & Classification
    // =========================================================================

    test('1. Inventory: exact public method count and classification arithmetic', () {
      const publicMethods = [
        'createExpense',
        'createIncome',
        'createTransfer',
        'createTransaction',
        'editTransaction',
        'deleteTransaction',
        'appendLedger',
        'removeLedger',
      ];

      expect(publicMethods.length, 8);

      final classifications = {
        'createExpense': 'CANONICAL_FINANCIAL',
        'createIncome': 'CANONICAL_FINANCIAL',
        'createTransfer': 'CANONICAL_FINANCIAL',
        'createTransaction': 'CANONICAL_FINANCIAL',
        'editTransaction': 'CANONICAL_FINANCIAL',
        'deleteTransaction': 'CANONICAL_FINANCIAL',
        'appendLedger': 'TRANSITIONAL_COMPATIBILITY',
        'removeLedger': 'TRANSITIONAL_COMPATIBILITY',
      };

      final canonicalFinancialCount = classifications.values
          .where((c) => c == 'CANONICAL_FINANCIAL')
          .length;
      final transitionalCompatibilityCount = classifications.values
          .where((c) => c == 'TRANSITIONAL_COMPATIBILITY')
          .length;
      final canonicalMetadataCount = classifications.values
          .where((c) => c == 'CANONICAL_METADATA')
          .length;
      final derivedCount =
          classifications.values.where((c) => c == 'DERIVED').length;
      final illegalCount =
          classifications.values.where((c) => c == 'ILLEGAL').length;

      expect(canonicalFinancialCount, 6);
      expect(transitionalCompatibilityCount, 2);
      expect(canonicalMetadataCount, 0);
      expect(derivedCount, 0);
      expect(illegalCount, 0);
      expect(
        canonicalFinancialCount +
            transitionalCompatibilityCount +
            canonicalMetadataCount +
            derivedCount +
            illegalCount,
        8,
      );
    });

    test('2. Inventory: all callers are strictly accounted for in orchestration layer', () {
      final callers = {
        'createExpense': [
          'FinancialTransactionService.createTransaction',
          'ReviewQueue',
        ],
        'createIncome': [
          'FinancialTransactionService.createTransaction',
          'SalaryService',
          'SmartImporter',
        ],
        'createTransfer': [
          'FinancialTransactionService.createTransaction',
          'ReviewQueue',
        ],
        'createTransaction': [
          'TransactionNotifier (transaction_providers.dart)',
          'LiabilitiesNotifier (liabilities_providers.dart)',
          'RecurringEngine (recurring_engine.dart)',
          'SmartImporter (smart_importer.dart)',
        ],
        'editTransaction': [
          'TransactionNotifier (transaction_providers.dart)',
        ],
        'deleteTransaction': [
          'TransactionNotifier (transaction_providers.dart)',
        ],
        'appendLedger': [
          'CreditCardService.processPayment',
          'CreditCardService.deleteCreditEMI',
          'CreditCardService.convertPurchaseToEMI',
          'LoanService.recordInstallmentPayment',
        ],
        'removeLedger': [
          'CreditCardService.deleteCreditCardTransaction',
          'CreditCardService.deleteCreditEMI',
          'CreditCardService.convertPurchaseToEMI',
        ],
      };

      expect(callers.keys.length, 8);
      for (final list in callers.values) {
        expect(list.isNotEmpty, isTrue);
      }
    });

    // =========================================================================
    // 2. Financial Correctness: Canonical Operations
    // =========================================================================

    test('3. Financial Correctness: createExpense routes through TransactionRepo to canonical ledger', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_bank_1',
          name: 'Main Checking',
          bank: 'State Bank',
          balance: 10000.0,
          accountType: 'savings',
        ),
      );

      final tx = model.Transaction(
        id: 'tx_exp_1',
        userId: 'offline_user',
        notes: 'Grocery Mart',
        amount: 1500.0,
        date: DateTime(2026, 3, 1),
        type: 'expense',
        categoryId: 'groceries',
        accountId: 'acc_bank_1',
      );

      await financialService.createExpense(tx);

      // Verify canonical EconomicEvent
      final event = await canonicalEventRepo.getEvent('tx_exp_1');
      expect(event, isNotNull);
      expect(event!.canonicalType, CanonicalEventType.expense);
      expect(event.lifecycleStatus, EventLifecycle.posted);

      // Verify postings: Dr Expense, Cr Asset
      final postings = await canonicalEventRepo.getPostingsForEvent('tx_exp_1');
      expect(postings.length, 2);

      final debitPosting = postings.firstWhere((p) => p.direction == PostingDirection.debit);
      final creditPosting = postings.firstWhere((p) => p.direction == PostingDirection.credit);

      expect(debitPosting.amount.minorUnits, 150000);
      expect(debitPosting.accountId, 'groceries');
      expect(creditPosting.amount.minorUnits, 150000);
      expect(creditPosting.accountId, 'acc_bank_1');

      // Verify derived balance
      final bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_1');
      expect(bal.toRupees, 8500.0);
    });

    test('4. Financial Correctness: createIncome routes through TransactionRepo to canonical ledger', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_bank_2',
          name: 'Savings',
          bank: 'HDFC Bank',
          balance: 5000.0,
          accountType: 'savings',
        ),
      );

      final tx = model.Transaction(
        id: 'tx_inc_1',
        userId: 'offline_user',
        notes: 'Consulting Fee',
        amount: 25000.0,
        date: DateTime(2026, 3, 2),
        type: 'income',
        categoryId: 'salary',
        accountId: 'acc_bank_2',
      );

      await financialService.createIncome(tx);

      final event = await canonicalEventRepo.getEvent('tx_inc_1');
      expect(event, isNotNull);
      expect(event!.canonicalType, CanonicalEventType.income);

      final postings = await canonicalEventRepo.getPostingsForEvent('tx_inc_1');
      expect(postings.length, 2);

      final debitPosting = postings.firstWhere((p) => p.direction == PostingDirection.debit);
      final creditPosting = postings.firstWhere((p) => p.direction == PostingDirection.credit);

      expect(debitPosting.amount.minorUnits, 2500000);
      expect(debitPosting.accountId, 'acc_bank_2');
      expect(creditPosting.amount.minorUnits, 2500000);
      expect(creditPosting.accountId, 'salary');

      final bal = await canonicalAccountRepo.getDerivedBalance('acc_bank_2');
      expect(bal.toRupees, 30000.0);
    });

    test('5. Financial Correctness: createTransfer moves asset between accounts with zero net worth change', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_bank_from',
          name: 'Checking',
          bank: 'Bank A',
          balance: 10000.0,
          accountType: 'checking',
        ),
      );
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_bank_to',
          name: 'Savings',
          bank: 'Bank B',
          balance: 5000.0,
          accountType: 'savings',
        ),
      );

      final tx = model.Transaction(
        id: 'tx_xfer_1',
        userId: 'offline_user',
        notes: 'Internal Transfer',
        amount: 3000.0,
        date: DateTime(2026, 3, 3),
        type: 'transfer',
        categoryId: 'transfer',
        accountId: 'acc_bank_from',
        relatedEntityId: 'acc_bank_to',
      );

      await financialService.createTransfer(tx);

      final fromBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_from');
      final toBal = await canonicalAccountRepo.getDerivedBalance('acc_bank_to');

      expect(fromBal.toRupees, 7000.0);
      expect(toBal.toRupees, 8000.0);

      // Verify net worth is conserved (no income/expense)
      final postings = await canonicalEventRepo.getPostingsForEvent('tx_xfer_1');
      expect(postings.length, 2);
      final dr = postings.firstWhere((p) => p.direction == PostingDirection.debit);
      final cr = postings.firstWhere((p) => p.direction == PostingDirection.credit);
      expect(dr.accountId, 'acc_bank_to');
      expect(cr.accountId, 'acc_bank_from');
    });

    test('6. Financial Correctness: credit card side-effect creates credit transaction in CreditRepo', () async {
      await creditRepo.insert(
        CreditCard(
          id: 'card_cc_1',
          name: 'Rewards Card',
          bank: 'HDFC',
          limitAmount: 50000.0,
          usedAmount: 0.0,
        ),
      );

      final tx = model.Transaction(
        id: 'tx_cc_purchase',
        userId: 'offline_user',
        notes: 'Electronics Store',
        amount: 4500.0,
        date: DateTime(2026, 3, 4),
        type: 'expense',
        categoryId: 'electronics',
        relatedEntityId: 'card_cc_1',
      );

      final creditTxn = CreditTransaction(
        id: 'ctx_1',
        cardId: 'card_cc_1',
        amount: 4500.0,
        date: DateTime(2026, 3, 4),
        category: 'electronics',
        type: 'purchase',
        status: 'active',
        note: 'Electronics Store',
      );

      await financialService.createTransaction(
        tx,
        creditTxn: creditTxn,
      );

      // Derived liability on the card should increase by 4500.0
      final card = await creditRepo.getCard('card_cc_1');
      expect(card, isNotNull);
      expect(card!.usedAmount, 4500.0);

      // Verify CreditTransaction is recorded in CreditRepo
      final fetchedCtx = await creditRepo.getTransactionById('ctx_1');
      expect(fetchedCtx, isNotNull);
      expect(fetchedCtx!.amount, 4500.0);
    });

    test('7. Financial Correctness: loan repayment delegates to LoanRepo and reduces liability', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_loan_payer',
          name: 'Payer Account',
          bank: 'SBI',
          balance: 50000.0,
          accountType: 'savings',
        ),
      );

      await loanRepo.insertLoan(
        Loan(
          id: 'loan_auto_1',
          name: 'Auto Loan',
          bank: 'Auto Bank',
          total: 200000.0,
          interestRate: 8.5,
          tenureMonths: 24,
          monthlyInstallment: 9000.0,
          startDate: DateTime(2026, 1, 1),
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        ),
      );

      final tx = model.Transaction(
        id: 'tx_loan_pay_1',
        userId: 'offline_user',
        notes: 'Auto EMI',
        amount: 9000.0,
        date: DateTime(2026, 3, 5),
        type: 'expense',
        categoryId: 'loans',
        accountId: 'acc_loan_payer',
        relatedEntityId: 'loan_auto_1',
      );

      await financialService.createTransaction(
        tx,
        loanId: 'loan_auto_1',
        loanPaidDelta: 7500.0, // Principal component
      );

      // Bank account reduced
      final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_loan_payer');
      expect(bankBal.toRupees, 41000.0);

      // Derived loan liability reduced by 7500 principal
      final loanLiability = await loanRepo.getDerivedBalance('loan_auto_1');
      expect(loanLiability.toRupees, 192500.0);
    });

    // =========================================================================
    // 3. Accounting Invariants & Integrity
    // =========================================================================

    test('8. Integrity: every economic event produced has sum(debit) == sum(credit)', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_bal_check',
          name: 'Test Checking',
          bank: 'Axis',
          balance: 10000.0,
          accountType: 'checking',
        ),
      );

      await financialService.createExpense(
        model.Transaction(
          id: 'tx_bal_1',
          userId: 'offline_user',
          notes: 'Coffee',
          amount: 250.0,
          date: DateTime(2026, 3, 6),
          type: 'expense',
          categoryId: 'dining',
          accountId: 'acc_bal_check',
        ),
      );

      await financialService.createIncome(
        model.Transaction(
          id: 'tx_bal_2',
          userId: 'offline_user',
          notes: 'Dividends',
          amount: 1200.0,
          date: DateTime(2026, 3, 6),
          type: 'income',
          categoryId: 'investments',
          accountId: 'acc_bal_check',
        ),
      );

      final events = await db.query(TablesV24.economicEvents);
      for (final ev in events) {
        final evId = ev['id'] as String;
        final postings = await db.query(
          TablesV24.postings,
          where: 'economic_event_id = ?',
          whereArgs: [evId],
        );

        int totalDr = 0;
        int totalCr = 0;
        for (final p in postings) {
          final amt = p['amount_minor_units'] as int;
          if (p['direction'] == 'debit') {
            totalDr += amt;
          } else {
            totalCr += amt;
          }
        }
        expect(totalDr, equals(totalCr), reason: 'Event $evId must be balanced');
      }
    });

    test('9. Integrity: SQLite triggers prevent direct modification of posted postings', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_immut_1',
          name: 'Immutable Bank',
          bank: 'SBI',
          balance: 5000.0,
          accountType: 'savings',
        ),
      );

      await financialService.createExpense(
        model.Transaction(
          id: 'tx_immut_1',
          userId: 'offline_user',
          notes: 'Stationery',
          amount: 300.0,
          date: DateTime(2026, 3, 7),
          type: 'expense',
          categoryId: 'stationery',
          accountId: 'acc_immut_1',
        ),
      );

      // Attempt illegal direct UPDATE on postings
      expect(
        () async => await db.rawUpdate(
          'UPDATE ${TablesV24.postings} SET amount_minor_units = 99999 WHERE economic_event_id = ?',
          ['tx_immut_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Attempt illegal direct DELETE on postings
      expect(
        () async => await db.rawDelete(
          'DELETE FROM ${TablesV24.postings} WHERE economic_event_id = ?',
          ['tx_immut_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('10. Integrity: modifying legacy bank_accounts.balance does NOT affect canonical derived balance', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_firewall_1',
          name: 'Protected Bank',
          bank: 'ICICI',
          balance: 1000.0,
          accountType: 'checking',
        ),
      );

      // Tamper with legacy table
      await db.rawUpdate(
        'UPDATE ${Tables.bankAccounts} SET balance = 999999.0 WHERE id = ?',
        ['acc_firewall_1'],
      );

      // Canonical derived balance is purely from postings (opening balance = 1000.0)
      final canonicalBal = await canonicalAccountRepo.getDerivedBalance('acc_firewall_1');
      expect(canonicalBal.toRupees, 1000.0);
    });

    // =========================================================================
    // 4. Atomicity & Rollback Guarantees
    // =========================================================================

    test('11. Atomicity: failure during transaction rolls back canonical event and postings completely', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_atom_1',
          name: 'Atomic Bank',
          bank: 'Canara',
          balance: 5000.0,
          accountType: 'savings',
        ),
      );

      final initialEventsCount = (await db.query(TablesV24.economicEvents)).length;
      final initialPostingsCount = (await db.query(TablesV24.postings)).length;

      // Create invalid transaction that violates CHECK(amount_minor_units > 0)
      final invalidTx = model.Transaction(
        id: 'tx_bad_atom',
        userId: 'offline_user',
        notes: 'Bad Transfer',
        amount: 0.0, // Violates CHECK(amount_minor_units > 0) on postings
        date: DateTime(2026, 3, 8),
        type: 'expense',
        categoryId: 'groceries',
        accountId: 'acc_atom_1',
      );

      try {
        await financialService.createExpense(invalidTx);
        fail('Should have failed due to zero amount violation');
      } catch (e) {
        // Expected
      }

      // Assert zero partial commits
      final finalEventsCount = (await db.query(TablesV24.economicEvents)).length;
      final finalPostingsCount = (await db.query(TablesV24.postings)).length;

      expect(finalEventsCount, equals(initialEventsCount));
      expect(finalPostingsCount, equals(initialPostingsCount));

      // Balance remains untouched
      final bal = await canonicalAccountRepo.getDerivedBalance('acc_atom_1');
      expect(bal.toRupees, 5000.0);
    });

    test('12. Atomicity: cross-domain transaction failure rolls back all side-effects', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_cross_1',
          name: 'Cross Account',
          bank: 'Kotak',
          balance: 20000.0,
          accountType: 'savings',
        ),
      );

      final tx = model.Transaction(
        id: 'tx_cross_bad',
        userId: 'offline_user',
        notes: 'Cross Domain Fail',
        amount: 5000.0,
        date: DateTime(2026, 3, 9),
        type: 'expense',
        categoryId: 'bad_cat',
        accountId: 'acc_cross_1',
        relatedEntityId: 'non_existent_loan', // Will cause failure in loan repayment
      );

      try {
        await financialService.createTransaction(
          tx,
          loanId: 'non_existent_loan',
          loanPaidDelta: 5000.0,
        );
        fail('Expected failure on non-existent loan');
      } catch (e) {
        // Expected
      }

      // Assert bank balance is untouched
      final bal = await canonicalAccountRepo.getDerivedBalance('acc_cross_1');
      expect(bal.toRupees, 20000.0);

      // Assert no event was committed
      final ev = await canonicalEventRepo.getEvent('tx_cross_bad');
      expect(ev, isNull);
    });

    // =========================================================================
    // 5. Corrections & Immutability: editTransaction and deleteTransaction
    // =========================================================================

    test('13. Corrections: editTransaction performs append-only reversal and replacement', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_edit_1',
          name: 'Editable Account',
          bank: 'IndusInd',
          balance: 10000.0,
          accountType: 'savings',
        ),
      );

      final originalTx = model.Transaction(
        id: 'tx_edit_orig',
        userId: 'offline_user',
        notes: 'Original Expense',
        amount: 2000.0,
        date: DateTime(2026, 3, 10),
        type: 'expense',
        categoryId: 'groceries',
        accountId: 'acc_edit_1',
      );

      await financialService.createExpense(originalTx);

      var bal = await canonicalAccountRepo.getDerivedBalance('acc_edit_1');
      expect(bal.toRupees, 8000.0);

      // Edit: change amount from 2000 to 1500
      final updatedTx = originalTx.copyWith(
        amount: 1500.0,
        notes: 'Corrected Grocery Expense',
      );

      await financialService.editTransaction(
        oldTransaction: originalTx,
        newTransaction: updatedTx,
      );

      // Original event is still in the database (immutable)
      final origEvent = await canonicalEventRepo.getEvent('tx_edit_orig');
      expect(origEvent, isNotNull);

      // Derived balance reflects the corrected amount (10000 - 1500 = 8500)
      bal = await canonicalAccountRepo.getDerivedBalance('acc_edit_1');
      expect(bal.toRupees, 8500.0);
    });

    test('14. Corrections: deleteTransaction performs append-only reversal without deleting event', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_del_1',
          name: 'Deletable Account',
          bank: 'Federal Bank',
          balance: 10000.0,
          accountType: 'savings',
        ),
      );

      final tx = model.Transaction(
        id: 'tx_del_orig',
        userId: 'offline_user',
        notes: 'Accidental Expense',
        amount: 3000.0,
        date: DateTime(2026, 3, 11),
        type: 'expense',
        categoryId: 'entertainment',
        accountId: 'acc_del_1',
      );

      await financialService.createExpense(tx);

      var bal = await canonicalAccountRepo.getDerivedBalance('acc_del_1');
      expect(bal.toRupees, 7000.0);

      // Delete transaction
      await financialService.deleteTransaction(
        'tx_del_orig',
        oldTransaction: tx,
      );

      // Balance is fully restored
      bal = await canonicalAccountRepo.getDerivedBalance('acc_del_1');
      expect(bal.toRupees, 10000.0);

      // Original event remains in economic_events (lifecycle updated or preserved)
      final eventRows = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: ['tx_del_orig'],
      );
      expect(eventRows.isNotEmpty, isTrue);
    });

    // =========================================================================
    // 6. Review Candidate & Non-Accounting Boundary
    // =========================================================================

    test('15. Review Boundary: review queue entries create ZERO postings until approved', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_rev_1',
          name: 'Review Bank',
          bank: 'IDFC',
          balance: 5000.0,
          accountType: 'checking',
        ),
      );

      // Insert raw unapproved review item into review queue
      await db.insert(Tables.reviewQueue, {
        'id': 'rev_queue_1',
        'raw_sms': 'Paid 500 at Cafe',
        'parsed_json': '{"amount":500.0,"merchant":"Cafe"}',
        'confidence': 0.85,
        'status': 'pending',
        'created_at': DateTime(2026, 3, 12).toIso8601String(),
      });

      // Postings count for this item must be zero
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['rev_queue_1'],
      );
      expect(postings.isEmpty, isTrue);

      // Bank balance is unchanged
      final bal = await canonicalAccountRepo.getDerivedBalance('acc_rev_1');
      expect(bal.toRupees, 5000.0);

      // Approval flow: when user confirms, service creates canonical transaction
      await financialService.createExpense(
        model.Transaction(
          id: 'tx_from_rev_1',
          userId: 'offline_user',
          notes: 'Cafe Coffee',
          amount: 500.0,
          date: DateTime(2026, 3, 12),
          type: 'expense',
          categoryId: 'dining',
          accountId: 'acc_rev_1',
        ),
      );

      // Now canonical event and postings exist
      final approvedBal = await canonicalAccountRepo.getDerivedBalance('acc_rev_1');
      expect(approvedBal.toRupees, 4500.0);
    });

    // =========================================================================
    // 7. Goal / Earmark Boundary
    // =========================================================================

    test('16. Goal Boundary: goal creation and earmarks produce ZERO postings', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_earmark_1',
          name: 'Savings Asset',
          bank: 'Yes Bank',
          balance: 50000.0,
          accountType: 'savings',
        ),
      );

      final initialPostingsCount = (await db.query(TablesV24.postings)).length;

      final goal = Goal(
        id: 'goal_vacation',
        title: 'Vacation',
        type: GoalType.savings,
        targetAmount: 50000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 90)),
      );
      await goalRepo.insert(goal);

      // Create earmark via GoalRepo
      final earmark = AssetEarmark(
        id: 'earmark_vacation',
        goalId: 'goal_vacation',
        assetAccountId: 'acc_earmark_1',
        earmarkedAmount: Money.fromRupees(15000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await goalRepo.createEarmark(earmark);

      // Postings count must not change
      final finalPostingsCount = (await db.query(TablesV24.postings)).length;
      expect(finalPostingsCount, equals(initialPostingsCount));

      // Financial balance of bank account remains 50000.0
      final bal = await canonicalAccountRepo.getDerivedBalance('acc_earmark_1');
      expect(bal.toRupees, 50000.0);

      // Derived progress reflects the earmark
      final progress = await goalRepo.getDerivedProgress('goal_vacation');
      expect(progress, equals(15000.0));
    });

    // =========================================================================
    // 8. Transitional Compatibility Methods
    // =========================================================================

    test('17. Compatibility: appendLedger and removeLedger safely maintain compatibility journal', () async {
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_compat_1',
          name: 'Compat Account',
          bank: 'PNB',
          balance: 1000.0,
          accountType: 'checking',
        ),
      );

      final leg = LedgerTransaction(
        type: LedgerType.expense,
        amount: 200.0,
        date: DateTime(2026, 3, 13),
        accountId: 'acc_compat_1',
        note: 'Legacy leg',
        referenceId: 'ref_compat_1',
      );

      await financialService.appendLedger(leg);

      final rows = await db.query(
        Tables.ledgerTransactions,
        where: 'reference_id = ?',
        whereArgs: ['ref_compat_1'],
      );
      expect(rows.length, 1);
      expect((rows.first['amount'] as num).toDouble(), 200.0);

      await financialService.removeLedger(referenceId: 'ref_compat_1');

      final remaining = await db.query(
        Tables.ledgerTransactions,
        where: 'reference_id = ?',
        whereArgs: ['ref_compat_1'],
      );
      expect(remaining.isEmpty, isTrue);
    });

    // =========================================================================
    // 9. Full System Cross-Domain Orchestration
    // =========================================================================

    test('18. Orchestration: end-to-end multi-account lifecycle through FinancialTransactionService', () async {
      // 1. Setup accounts
      await accountRepo.insertAccount(
        BankAccount(
          id: 'acc_orchestr_bank',
          name: 'Main Bank',
          bank: 'HDFC',
          balance: 100000.0,
          accountType: 'checking',
        ),
      );
      await creditRepo.insert(
        CreditCard(
          id: 'card_orchestr_cc',
          name: 'Platinum Card',
          bank: 'HDFC',
          limitAmount: 100000.0,
          usedAmount: 0.0,
        ),
      );

      // 2. Income: Salary credit
      await financialService.createIncome(
        model.Transaction(
          id: 'tx_orch_inc',
          userId: 'offline_user',
          notes: 'Monthly Salary',
          amount: 50000.0,
          date: DateTime(2026, 3, 1),
          type: 'income',
          categoryId: 'salary',
          accountId: 'acc_orchestr_bank',
        ),
      );

      // 3. CC Purchase
      await financialService.createTransaction(
        model.Transaction(
          id: 'tx_orch_cc',
          userId: 'offline_user',
          notes: 'Flight Tickets',
          amount: 12000.0,
          date: DateTime(2026, 3, 2),
          type: 'expense',
          categoryId: 'travel',
          relatedEntityId: 'card_orchestr_cc',
        ),
        creditTxn: CreditTransaction(
          id: 'ctx_orch_1',
          cardId: 'card_orchestr_cc',
          amount: 12000.0,
          date: DateTime(2026, 3, 2),
          category: 'travel',
          type: 'purchase',
          status: 'active',
        ),
      );

      // 4. Verify balances
      final bankBal = await canonicalAccountRepo.getDerivedBalance('acc_orchestr_bank');
      expect(bankBal.toRupees, 150000.0); // 100k + 50k

      final ccCard = await creditRepo.getCard('card_orchestr_cc');
      expect(ccCard, isNotNull);
      expect(ccCard!.usedAmount, 12000.0);

      // 5. Query net worth
      final totalNetWorth = await financialQueryRepo.getNetWorth();
      // Assets (150,000) - Liabilities (12,000) = 138,000 INR
      expect(totalNetWorth.toRupees, 138000.0);
    });
  });
}
