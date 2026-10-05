import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_opening_balance_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/loan_installment.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C3B-4: LoanRepo Canonical Migration Suite', () {
    late Database db;
    late LoanRepo loanRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late TransactionRepo transactionRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalOpeningBalanceRepository canonicalOpeningBalanceRepo;
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

      loanRepo = LoanRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      transactionRepo = TransactionRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalOpeningBalanceRepo = CanonicalOpeningBalanceRepository(executor: db);
      financialQueryRepo = CanonicalFinancialQueryRepository(executor: db);
    });

    tearDown(() async {
      await db.close();
    });

    // 1. zero-balance loan creation
    test('1. zero_balance_loan_creation: Creates canonical liability account with 0 balance and 0 postings', () async {
      final loan = Loan(
        id: 'loan_zero',
        name: 'Zero Balance Loan',
        bank: 'HDFC',
        total: 0.0,
        interestRate: 10.5,
        tenureMonths: 12,
        monthlyInstallment: 0.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 5,
      );

      final returnedId = await loanRepo.insertLoan(loan);
      expect(returnedId, equals('loan_zero'));

      final accountRow = (await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['loan_zero'],
      )).first;
      expect(accountRow['account_type'], equals('liability'));
      expect(accountRow['subtype'], equals('loan'));
      expect(accountRow['name'], equals('Zero Balance Loan'));
      expect(accountRow['is_active'], equals(1));

      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['loan_zero'],
      );
      expect(postings, isEmpty);

      final derivedBalance = await loanRepo.getDerivedBalance('loan_zero');
      expect(derivedBalance.minorUnits, equals(0));

      final projected = await loanRepo.getLoanById('loan_zero');
      expect(projected, isNotNull);
      expect(projected!.total, equals(0.0));
      expect(projected.paidAmount, equals(0.0));
    });

    // 2. non-zero opening loan
    test('2. non_zero_opening_loan: Creates balanced opening event (Cr Loan, Dr sys_equity_opening) with provenance', () async {
      final loan = Loan(
        id: 'loan_opening',
        name: 'Car Loan',
        bank: 'SBI',
        total: 100000.0,
        interestRate: 8.5,
        tenureMonths: 36,
        monthlyInstallment: 3156.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 10,
      );

      await loanRepo.insertLoan(loan);

      final derivedBalance = await loanRepo.getDerivedBalance('loan_opening');
      expect(derivedBalance.toRupees, equals(100000.0));

      final event = await canonicalEventRepo.getEvent('evt_ob_loan_opening');
      expect(event, isNotNull);
      expect(event!.canonicalType, equals(CanonicalEventType.openingBalance));
      expect(event.lifecycleStatus, equals(EventLifecycle.posted));

      final postings = await canonicalEventRepo.getPostingsForEvent('evt_ob_loan_opening');
      expect(postings.length, equals(2));

      final loanPosting = postings.firstWhere((p) => p.accountId == 'loan_opening');
      expect(loanPosting.direction, equals(PostingDirection.credit));
      expect(loanPosting.amount.toRupees, equals(100000.0));

      final equityPosting = postings.firstWhere((p) => p.accountId == TablesV24.sysEquityOpening);
      expect(equityPosting.direction, equals(PostingDirection.debit));
      expect(equityPosting.amount.toRupees, equals(100000.0));

      final allRecs = await canonicalOpeningBalanceRepo.listReconciliations();
      final recs = allRecs.where((r) => r.accountId == 'loan_opening').toList();
      expect(recs.length, equals(1));
      expect(recs.first.provenanceSource, equals('manual_loan_creation'));
      expect(recs.first.legacyReportedBalance.toRupees, equals(100000.0));
    });

    // 3. loan disbursement
    test('3. loan_disbursement: Dr Bank Asset, Cr Loan Liability increases both; Net worth unchanged, 0 expense/income', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_disb',
        name: 'Checking',
        bank: 'HDFC',
        balance: 10000.0,
        last4: '1111',
      ));

      final loan = Loan(
        id: 'loan_disb',
        name: 'Personal Loan',
        bank: 'ICICI',
        total: 0.0,
        interestRate: 12.0,
        tenureMonths: 12,
        monthlyInstallment: 0.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      final netWorthBefore = (await accountRepo.getById('bank_disb'))!.balance -
          (await loanRepo.getDerivedBalance('loan_disb')).toRupees;
      expect(netWorthBefore, equals(10000.0));

      final eventId = await loanRepo.recordDisbursement(
        loanId: 'loan_disb',
        assetAccountId: 'bank_disb',
        amount: 50000.0,
        timestamp: DateTime(2026, 1, 2),
        description: 'Personal Loan Disbursement',
      );
      expect(eventId, isNotEmpty);

      final bankAfter = await accountRepo.getById('bank_disb');
      expect(bankAfter!.balance, equals(60000.0));

      final loanLiabilityAfter = await loanRepo.getDerivedBalance('loan_disb');
      expect(loanLiabilityAfter.toRupees, equals(50000.0));

      final netWorthAfter = bankAfter.balance - loanLiabilityAfter.toRupees;
      expect(netWorthAfter, equals(10000.0)); // Net worth preserved exactly

      final income = await financialQueryRepo.getTotalIncome(
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 1, 31),
      );
      final expense = await financialQueryRepo.getTotalExpenses(
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 1, 31),
      );
      expect(income.minorUnits, equals(0));
      expect(expense.minorUnits, equals(0));
    });

    // 4. principal repayment
    test('4. principal_repayment: Dr Loan Liability, Cr Bank Asset decreases liability and asset with 0 expense', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_repay',
        name: 'Checking',
        bank: 'SBI',
        balance: 100000.0,
        last4: '2222',
      ));

      final loan = Loan(
        id: 'loan_repay',
        name: 'Home Loan',
        bank: 'SBI',
        total: 200000.0,
        interestRate: 8.5,
        tenureMonths: 120,
        monthlyInstallment: 5000.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      await loanRepo.recordRepayment(
        loanId: 'loan_repay',
        assetAccountId: 'bank_repay',
        principalAmount: 30000.0,
        timestamp: DateTime(2026, 1, 15),
      );

      final loanBalance = await loanRepo.getDerivedBalance('loan_repay');
      expect(loanBalance.toRupees, equals(170000.0)); // 200000 - 30000

      final bankBalance = (await accountRepo.getById('bank_repay'))!.balance;
      expect(bankBalance, equals(70000.0)); // 100000 - 30000

      final expense = await financialQueryRepo.getTotalExpenses(
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 1, 31),
      );
      expect(expense.minorUnits, equals(0)); // Zero expense impact
    });

    // 5. interest payment
    test('5. interest_payment: Dr sys_exp_interest, Cr Bank Asset increases expense; principal unaffected', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_int',
        name: 'Checking',
        bank: 'Axis',
        balance: 50000.0,
        last4: '3333',
      ));

      final loan = Loan(
        id: 'loan_int',
        name: 'Education Loan',
        bank: 'Axis',
        total: 100000.0,
        interestRate: 9.0,
        tenureMonths: 24,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 5,
      );
      await loanRepo.insertLoan(loan);

      await loanRepo.recordInterestPayment(
        loanId: 'loan_int',
        assetAccountId: 'bank_int',
        interestAmount: 2500.0,
        timestamp: DateTime(2026, 1, 20),
      );

      final loanBalance = await loanRepo.getDerivedBalance('loan_int');
      expect(loanBalance.toRupees, equals(100000.0)); // Principal debt unaffected!

      final bankBalance = (await accountRepo.getById('bank_int'))!.balance;
      expect(bankBalance, equals(47500.0)); // 50000 - 2500

      final expense = await financialQueryRepo.getTotalExpenses(
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 1, 31),
      );
      expect(expense.toRupees, equals(2500.0)); // Expense recorded accurately
    });

    // 6. combined principal + interest EMI
    test('6. combined_emi_payment: Dr Loan (p), Dr Interest (i), Cr Bank (p+i) balances exactly', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_emi',
        name: 'Checking',
        bank: 'HDFC',
        balance: 80000.0,
        last4: '4444',
      ));

      final loan = Loan(
        id: 'loan_emi',
        name: 'Vehicle Loan',
        bank: 'HDFC',
        total: 150000.0,
        interestRate: 10.0,
        tenureMonths: 36,
        monthlyInstallment: 10000.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 5,
      );
      await loanRepo.insertLoan(loan);

      final eventId = await loanRepo.recordCombinedPayment(
        loanId: 'loan_emi',
        assetAccountId: 'bank_emi',
        principalAmount: 8500.0,
        interestAmount: 1500.0,
        timestamp: DateTime(2026, 1, 25),
      );

      final postings = await canonicalEventRepo.getPostingsForEvent(eventId);
      expect(postings.length, equals(3));

      final debits = postings.where((p) => p.direction == PostingDirection.debit).fold(
            Money.zero,
            (sum, p) => sum + p.amount,
          );
      final credits = postings.where((p) => p.direction == PostingDirection.credit).fold(
            Money.zero,
            (sum, p) => sum + p.amount,
          );
      expect(debits.toRupees, equals(10000.0));
      expect(credits.toRupees, equals(10000.0));
      expect(debits, equals(credits));

      final loanBalance = await loanRepo.getDerivedBalance('loan_emi');
      expect(loanBalance.toRupees, equals(141500.0)); // 150000 - 8500

      final bankBalance = (await accountRepo.getById('bank_emi'))!.balance;
      expect(bankBalance, equals(70000.0)); // 80000 - 10000

      final expense = await financialQueryRepo.getTotalExpenses(
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 1, 31),
      );
      expect(expense.toRupees, equals(1500.0));
    });

    // 7. multiple repayments
    test('7. multiple_repayments: Monotonically reduces liability balance across repeated repayments', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_multi',
        name: 'Checking',
        bank: 'SBI',
        balance: 100000.0,
        last4: '5555',
      ));

      final loan = Loan(
        id: 'loan_multi',
        name: 'Multi Repay Loan',
        bank: 'SBI',
        total: 90000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 8000.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      await loanRepo.recordRepayment(
        loanId: 'loan_multi',
        assetAccountId: 'bank_multi',
        principalAmount: 20000.0,
        timestamp: DateTime(2026, 1, 5),
      );
      expect((await loanRepo.getDerivedBalance('loan_multi')).toRupees, equals(70000.0));

      await loanRepo.recordRepayment(
        loanId: 'loan_multi',
        assetAccountId: 'bank_multi',
        principalAmount: 30000.0,
        timestamp: DateTime(2026, 1, 10),
      );
      expect((await loanRepo.getDerivedBalance('loan_multi')).toRupees, equals(40000.0));

      await loanRepo.recordRepayment(
        loanId: 'loan_multi',
        assetAccountId: 'bank_multi',
        principalAmount: 40000.0,
        timestamp: DateTime(2026, 1, 15),
      );
      expect((await loanRepo.getDerivedBalance('loan_multi')).toRupees, equals(0.0));
    });

    // 8. derived liability balance
    test('8. derived_liability_balance: Sums posted credits - posted debits dynamically from postings', () async {
      final loan = Loan(
        id: 'loan_der',
        name: 'Derived Balance Test',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      final balance = await canonicalAccountRepo.getDerivedBalance('loan_der');
      expect(balance.toRupees, equals(50000.0));
    });

    // 9. draft event isolation
    test('9. draft_event_isolation: Draft events contribute zero to derived loan liability balance', () async {
      final loan = Loan(
        id: 'loan_draft',
        name: 'Draft Isolation Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Create draft event with repayment posting
      final draftEvent = EconomicEvent(
        id: 'evt_draft_repay',
        canonicalType: CanonicalEventType.loanRepayment,
        lifecycleStatus: EventLifecycle.draft,
        occurredAt: DateTime.now(),
        description: 'Draft repayment',
        metadata: {},
        postings: [],
        createdAt: DateTime.now(),
      );

      await canonicalEventRepo.createDraftEvent(draftEvent);
      await canonicalEventRepo.attachPostings('evt_draft_repay', [
        Posting(
          id: 'pst_draft_1',
          economicEventId: 'evt_draft_repay',
          accountId: 'loan_draft',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(25000.0),
          createdAt: DateTime.now(),
        ),
        Posting(
          id: 'pst_draft_2',
          economicEventId: 'evt_draft_repay',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromRupees(25000.0),
          createdAt: DateTime.now(),
        ),
      ]);

      // Verify derived balance is unaffected by draft event
      final derivedBalance = await loanRepo.getDerivedBalance('loan_draft');
      expect(derivedBalance.toRupees, equals(50000.0));
    });

    // 10. posted-event immutability
    test('10. posted_event_immutability: SQLite triggers reject UPDATE and DELETE on posted events & postings', () async {
      final loan = Loan(
        id: 'loan_immut',
        name: 'Immutable Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Try updating immutable field of posted event
      expect(
        () async => await db.rawUpdate('''
          UPDATE ${TablesV24.economicEvents}
          SET timestamp = '2020-01-01T00:00:00.000'
          WHERE id = 'evt_ob_loan_immut'
        '''),
        throwsA(isA<DatabaseException>()),
      );

      // Try deleting posted event
      expect(
        () async => await db.rawDelete('''
          DELETE FROM ${TablesV24.economicEvents}
          WHERE id = 'evt_ob_loan_immut'
        '''),
        throwsA(isA<DatabaseException>()),
      );

      // Try updating posting
      expect(
        () async => await db.rawUpdate('''
          UPDATE ${TablesV24.postings}
          SET amount_minor_units = 999999
          WHERE economic_event_id = 'evt_ob_loan_immut'
        '''),
        throwsA(isA<DatabaseException>()),
      );
    });

    // 11. reversal/correction
    test('11. reversal_correction: Append-only reversal cancels financial impact while preserving history', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_rev',
        name: 'Checking',
        bank: 'Bank',
        balance: 100000.0,
        last4: '6666',
      ));

      final loan = Loan(
        id: 'loan_rev',
        name: 'Reversal Test Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      final repayEventId = await loanRepo.recordRepayment(
        loanId: 'loan_rev',
        assetAccountId: 'bank_rev',
        principalAmount: 20000.0,
        timestamp: DateTime(2026, 1, 10),
      );

      expect((await loanRepo.getDerivedBalance('loan_rev')).toRupees, equals(30000.0));
      expect((await accountRepo.getById('bank_rev'))!.balance, equals(80000.0));

      // Reverse the repayment
      final revId = await loanRepo.reverseLoanEvent(repayEventId);
      expect(revId, isNotEmpty);

      // Balance fully restored
      expect((await loanRepo.getDerivedBalance('loan_rev')).toRupees, equals(50000.0));
      expect((await accountRepo.getById('bank_rev'))!.balance, equals(100000.0));

      // Append-only reversal event exists in database with opposite postings
      final revEvent = await canonicalEventRepo.getEvent(revId);
      expect(revEvent, isNotNull);
      expect(revEvent!.lifecycleStatus, equals(EventLifecycle.posted));

      final revPostings = await canonicalEventRepo.getPostingsForEvent(revId);
      expect(revPostings.length, equals(2));
      final loanRevPosting = revPostings.firstWhere((p) => p.accountId == 'loan_rev');
      expect(loanRevPosting.direction, equals(PostingDirection.credit)); // Opposite of repayment's debit
      expect(loanRevPosting.amount.toRupees, equals(20000.0));
    });

    // 12. reconciliation
    test('12. reconciliation: Reconciles deltas against sys_equity_opening with provenance', () async {
      final loan = Loan(
        id: 'loan_reconcile',
        name: 'Reconcile Test Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Reconcile to 45,000 (delta: -5,000 paise)
      await loanRepo.reconcileBalance('loan_reconcile', 45000.0);

      final newBalance = await loanRepo.getDerivedBalance('loan_reconcile');
      expect(newBalance.toRupees, equals(45000.0));

      final allRecs = await canonicalOpeningBalanceRepo.listReconciliations();
      final recs = allRecs.where((r) => r.accountId == 'loan_reconcile').toList();
      expect(recs.length, equals(2)); // 1 opening + 1 reconciliation
      expect(recs.first.provenanceSource, equals('loan_reconciliation_delta'));
    });

    // 13. reconciliation rollback
    test('13. reconciliation_rollback: Injected transaction failure rolls back cleanly leaving 0 partial state', () async {
      final loan = Loan(
        id: 'loan_fail',
        name: 'Fail Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      final beforeEventsCount = (await db.rawQuery('SELECT COUNT(*) as count FROM ${TablesV24.economicEvents}')).first['count'];

      // Attempt disbursement targeting non-existent bank asset account with foreign key check enabled
      expect(
        () async => await loanRepo.recordDisbursement(
          loanId: 'loan_fail',
          assetAccountId: 'non_existent_bank_account_id',
          amount: 25000.0,
          timestamp: DateTime.now(),
        ),
        throwsA(isA<DatabaseException>()),
      );

      final afterEventsCount = (await db.rawQuery('SELECT COUNT(*) as count FROM ${TablesV24.economicEvents}')).first['count'];
      expect(afterEventsCount, equals(beforeEventsCount)); // Zero partial events committed

      final balance = await loanRepo.getDerivedBalance('loan_fail');
      expect(balance.toRupees, equals(50000.0));
    });

    // 14. duplicate loan creation/idempotency
    test('14. duplicate_loan_creation: Repeated insertLoan calls do not duplicate opening balance postings', () async {
      final loan = Loan(
        id: 'loan_idempotent',
        name: 'Idempotent Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );

      await loanRepo.insertLoan(loan);
      await loanRepo.insertLoan(loan); // Second invocation

      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['loan_idempotent'],
      );
      expect(postings.length, equals(1)); // 1 posting only!

      final balance = await loanRepo.getDerivedBalance('loan_idempotent');
      expect(balance.toRupees, equals(50000.0));
    });

    // 15. duplicate disbursement protection
    test('15. duplicate_disbursement_protection: Duplicate externalRef throws AccountingInvariantException', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_dup',
        name: 'Checking',
        bank: 'Bank',
        balance: 10000.0,
        last4: '7777',
      ));

      final loan = Loan(
        id: 'loan_dup',
        name: 'Dup Loan',
        bank: 'Bank',
        total: 0.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 0.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      await loanRepo.recordDisbursement(
        loanId: 'loan_dup',
        assetAccountId: 'bank_dup',
        amount: 20000.0,
        timestamp: DateTime(2026, 1, 2),
        externalRef: 'ext_disb_001',
      );

      expect(
        () async => await loanRepo.recordDisbursement(
          loanId: 'loan_dup',
          assetAccountId: 'bank_dup',
          amount: 20000.0,
          timestamp: DateTime(2026, 1, 2),
          externalRef: 'ext_disb_001',
        ),
        throwsA(isA<AccountingInvariantException>()),
      );
    });

    // 16. duplicate repayment protection
    test('16. duplicate_repayment_protection: Duplicate externalRef on repayment throws AccountingInvariantException', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_dup_r',
        name: 'Checking',
        bank: 'Bank',
        balance: 100000.0,
        last4: '8888',
      ));

      final loan = Loan(
        id: 'loan_dup_r',
        name: 'Dup Repay Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      await loanRepo.recordRepayment(
        loanId: 'loan_dup_r',
        assetAccountId: 'bank_dup_r',
        principalAmount: 10000.0,
        timestamp: DateTime(2026, 1, 10),
        externalRef: 'ext_repay_001',
      );

      expect(
        () async => await loanRepo.recordRepayment(
          loanId: 'loan_dup_r',
          assetAccountId: 'bank_dup_r',
          principalAmount: 10000.0,
          timestamp: DateTime(2026, 1, 10),
          externalRef: 'ext_repay_001',
        ),
        throwsA(isA<AccountingInvariantException>()),
      );
    });

    // 17. accounting equation
    test('17. accounting_equation: Assets = Liabilities + Equity holds across full loan lifecycle', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_eq',
        name: 'Checking',
        bank: 'Bank',
        balance: 50000.0,
        last4: '9999',
      ));

      final loan = Loan(
        id: 'loan_eq',
        name: 'Lifecycle Loan',
        bank: 'Bank',
        total: 100000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 10000.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Disbursement
      await loanRepo.recordDisbursement(
        loanId: 'loan_eq',
        assetAccountId: 'bank_eq',
        amount: 50000.0,
        timestamp: DateTime(2026, 1, 5),
      );

      // Repayment
      await loanRepo.recordRepayment(
        loanId: 'loan_eq',
        assetAccountId: 'bank_eq',
        principalAmount: 20000.0,
        timestamp: DateTime(2026, 1, 10),
      );

      // Combined EMI
      await loanRepo.recordCombinedPayment(
        loanId: 'loan_eq',
        assetAccountId: 'bank_eq',
        principalAmount: 10000.0,
        interestAmount: 2000.0,
        timestamp: DateTime(2026, 1, 15),
      );

      // Verify total Assets, Liabilities, Equity
      final allAccounts = await canonicalAccountRepo.listAccounts();
      var totalAssets = 0;
      var totalLiabilities = 0;
      var totalEquity = 0;
      var totalExpenses = 0;

      for (final acc in allAccounts) {
        final bal = (await canonicalAccountRepo.getDerivedBalance(acc.id)).minorUnits;
        switch (acc.type) {
          case AccountType.asset:
            totalAssets += bal;
            break;
          case AccountType.liability:
            totalLiabilities += bal;
            break;
          case AccountType.equity:
            totalEquity += bal;
            break;
          case AccountType.expense:
            totalExpenses += bal;
            break;
          default:
            break;
        }
      }

      // Accounting equation: Assets = Liabilities + Equity (where Equity includes opening equity - expenses)
      expect(totalAssets, equals(totalLiabilities + totalEquity - totalExpenses));
    });

    // 18. legacy financial-field write firewall
    test('18. legacy_write_firewall: Direct UPDATEs to loans.paid_amount do NOT alter canonical truth', () async {
      final loan = Loan(
        id: 'loan_firewall',
        name: 'Firewall Loan',
        bank: 'Bank',
        total: 60000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 5500.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Rogue write directly to legacy transitional table
      await db.rawUpdate('''
        UPDATE ${Tables.loans}
        SET paid_amount = 59999.0, total = 999999.0
        WHERE id = 'loan_firewall'
      ''');

      // Canonical derived balance remains 100% untouched
      final derivedBalance = await loanRepo.getDerivedBalance('loan_firewall');
      expect(derivedBalance.toRupees, equals(60000.0));
    });

    // 19. legacy compatibility projection
    test('19. legacy_compatibility_projection: getLoans and getLoanById project Loan with dynamically derived paidAmount', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_proj',
        name: 'Checking',
        bank: 'Bank',
        balance: 100000.0,
        last4: '1234',
      ));

      final loan = Loan(
        id: 'loan_proj',
        name: 'Projected Loan',
        bank: 'Bank',
        total: 100000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 9000.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      await loanRepo.recordRepayment(
        loanId: 'loan_proj',
        assetAccountId: 'bank_proj',
        principalAmount: 40000.0,
        timestamp: DateTime(2026, 1, 10),
      );

      final projected = await loanRepo.getLoanById('loan_proj');
      expect(projected, isNotNull);
      expect(projected!.total, equals(100000.0));
      expect(projected.paidAmount, equals(40000.0)); // Derived dynamically: 100000 - 60000
      expect(projected.principalAmount - projected.paidAmount, equals(60000.0));
    });

    // 20. schedule metadata isolation
    test('20. schedule_metadata_isolation: Operational schedule methods create ZERO accounting postings', () async {
      final loan = Loan(
        id: 'loan_sched',
        name: 'Schedule Loan',
        bank: 'Bank',
        total: 0.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 0.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      final beforePostings = (await db.rawQuery('SELECT COUNT(*) as count FROM ${TablesV24.postings}')).first['count'];

      await loanRepo.insertInstallment(LoanInstallment(
        id: 'inst_01',
        loanId: 'loan_sched',
        dueDate: DateTime(2026, 2, 1),
        amount: 5000.0,
        principalComponent: 4000.0,
        interestComponent: 1000.0,
        status: 'pending',
      ));

      await loanRepo.updateInstallmentStatus('inst_01', 'paid', DateTime(2026, 2, 1));
      await loanRepo.updateLoanProgress('loan_sched', 4000.0, 'active');

      final afterPostings = (await db.rawQuery('SELECT COUNT(*) as count FROM ${TablesV24.postings}')).first['count'];
      expect(afterPostings, equals(beforePostings)); // ZERO postings created by schedule operations!
    });

    // 21. expected-installment does not create accounting
    test('21. expected_installment_does_not_create_accounting: Amortization schedule entries generate zero financial impact', () async {
      for (int i = 1; i <= 12; i++) {
        await loanRepo.insertInstallment(LoanInstallment(
          id: 'inst_$i',
          loanId: 'loan_amort',
          dueDate: DateTime(2026, 1 + i, 1),
          amount: 5000.0,
          principalComponent: 4500.0,
          interestComponent: 500.0,
          status: 'pending',
        ));
      }

      final installments = await loanRepo.getInstallments('loan_amort');
      expect(installments.length, equals(12));

      final postingsCount = (await db.rawQuery('SELECT COUNT(*) as count FROM ${TablesV24.postings}')).first['count'];
      expect(postingsCount, equals(0));
    });

    // 22. C3B-1 regression
    test('22. c3b_1_regression: TransactionRepo operates seamlessly alongside LoanRepo', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_c3b1',
        name: 'Main Bank',
        bank: 'SBI',
        balance: 50000.0,
        last4: '9876',
      ));

      final loan = Loan(
        id: 'loan_c3b1',
        name: 'Interop Loan',
        bank: 'Bank',
        total: 50000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 5000.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Create generic transaction via TransactionRepo
      await transactionRepo.insert(model.Transaction(
        id: 'tx_c3b1_test',
        userId: 'offline_user',
        accountId: 'bank_c3b1',
        amount: 5000.0,
        type: 'expense',
        categoryId: 'Food',
        date: DateTime.now(),
        notes: 'Lunch',
      ));

      expect((await accountRepo.getById('bank_c3b1'))!.balance, equals(45000.0));
      expect((await loanRepo.getDerivedBalance('loan_c3b1')).toRupees, equals(50000.0));
    });

    // 23. C3B-2 regression
    test('23. c3b_2_regression: AccountRepo bank account balance accurately reflects loan disbursements & repayments', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_c3b2',
        name: 'Savings',
        bank: 'HDFC',
        balance: 20000.0,
        last4: '5432',
      ));

      final loan = Loan(
        id: 'loan_c3b2',
        name: 'Inter-Repo Loan',
        bank: 'Bank',
        total: 0.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 0.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      await loanRepo.recordDisbursement(
        loanId: 'loan_c3b2',
        assetAccountId: 'bank_c3b2',
        amount: 80000.0,
        timestamp: DateTime(2026, 1, 5),
      );
      expect((await accountRepo.getById('bank_c3b2'))!.balance, equals(100000.0));

      await loanRepo.recordRepayment(
        loanId: 'loan_c3b2',
        assetAccountId: 'bank_c3b2',
        principalAmount: 30000.0,
        timestamp: DateTime(2026, 1, 10),
      );
      expect((await accountRepo.getById('bank_c3b2'))!.balance, equals(70000.0));
    });

    // 24. C3B-3 regression
    test('24. c3b_3_regression: CreditRepo card operations operate concurrently without interference', () async {
      await creditRepo.insert(CreditCard(
        id: 'card_c3b3',
        userId: 'u1',
        name: 'Credit Card',
        bank: 'Axis',
        last4: '4321',
        limitAmount: 50000.0,
        billingDay: 1,
        dueDay: 20,
        cardType: 'visa',
        color: '#FFFFFF',
        usedAmount: 10000.0,
        createdAt: DateTime.now(),
      ));

      final loan = Loan(
        id: 'loan_c3b3',
        name: 'Concurrent Loan',
        bank: 'Bank',
        total: 40000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 4000.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      final cardLiability = (await creditRepo.getCard('card_c3b3'))!.usedAmount;
      final loanLiability = (await loanRepo.getDerivedBalance('loan_c3b3')).toRupees;

      expect(cardLiability, equals(10000.0));
      expect(loanLiability, equals(40000.0));
    });

    // 25. cross-repository loan → bank interaction
    test('25. cross_repository_interaction: Loan and bank accounts update in unison during full lifecycle', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'bank_x',
        name: 'Operational Account',
        bank: 'HDFC',
        balance: 10000.0,
        last4: '0001',
      ));

      final loan = Loan(
        id: 'loan_x',
        name: 'X-Repo Loan',
        bank: 'HDFC',
        total: 0.0,
        interestRate: 11.0,
        tenureMonths: 12,
        monthlyInstallment: 0.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 5,
      );
      await loanRepo.insertLoan(loan);

      // 1. Disbursement
      await loanRepo.recordDisbursement(
        loanId: 'loan_x',
        assetAccountId: 'bank_x',
        amount: 100000.0,
        timestamp: DateTime(2026, 1, 2),
      );

      expect((await accountRepo.getById('bank_x'))!.balance, equals(110000.0));
      expect((await loanRepo.getDerivedBalance('loan_x')).toRupees, equals(100000.0));

      // 2. Repayment
      await loanRepo.recordRepayment(
        loanId: 'loan_x',
        assetAccountId: 'bank_x',
        principalAmount: 50000.0,
        timestamp: DateTime(2026, 1, 10),
      );

      expect((await accountRepo.getById('bank_x'))!.balance, equals(60000.0));
      expect((await loanRepo.getDerivedBalance('loan_x')).toRupees, equals(50000.0));

      // 3. Combined EMI
      await loanRepo.recordCombinedPayment(
        loanId: 'loan_x',
        assetAccountId: 'bank_x',
        principalAmount: 50000.0,
        interestAmount: 5000.0,
        timestamp: DateTime(2026, 1, 20),
      );

      expect((await accountRepo.getById('bank_x'))!.balance, equals(5000.0));
      expect((await loanRepo.getDerivedBalance('loan_x')).toRupees, equals(0.0));

      // Projected loan status is now closed
      final loanProjected = await loanRepo.getLoanById('loan_x');
      expect(loanProjected!.loanStatus, equals('closed'));
    });
  });
}
