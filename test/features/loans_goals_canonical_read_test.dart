import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/features/liabilities/providers/liabilities_providers.dart';
import 'package:spend_x/features/goals/goal_providers.dart';
import 'package:spend_x/domain/loans/loan_service.dart';
import 'package:spend_x/services/net_worth_service.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C4-4: Loans & Goals Canonical Read Migration Test Suite', () {
    late Database db;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late AccountRepo accountRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late LoanService loanService;
    late NetWorthService netWorthService;
    late ProviderContainer container;

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
      goalRepo = GoalRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      loanService = LoanService(loanRepo: loanRepo);
      netWorthService = NetWorthService(accountRepo, loanRepo, queryRepo: canonicalQueryRepo);

      container = ProviderContainer(
        overrides: [
          app_data.loanRepoProvider.overrideWithValue(loanRepo),
          app_data.goalRepoProvider.overrideWithValue(goalRepo),
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.canonicalFinancialQueryRepositoryProvider
              .overrideWithValue(canonicalQueryRepo),
          app_data.netWorthServiceProvider.overrideWithValue(netWorthService),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // =========================================================================
    // LOANS ADVERSARIAL TESTS (Invariants 1 - 10)
    // =========================================================================

    // -------------------------------------------------------------------------
    // Invariant 1: Rogue loans.paid_amount mutation does not change canonical outstanding
    // -------------------------------------------------------------------------
    test('1. Rogue mutation of loans.paid_amount has ZERO effect on canonical outstanding', () async {
      final loan = Loan(
        id: 'loan_inv_1',
        name: 'Home Loan SBI',
        bank: 'SBI',
        total: 500000.0,
        interestRate: 8.5,
        tenureMonths: 120,
        monthlyInstallment: 6200.0,
        startDate: DateTime(2026, 1, 1),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 10,
      );
      await loanRepo.insertLoan(loan);

      // Verify canonical derived liability is ₹500,000
      final balanceBefore = await loanRepo.getDerivedBalance('loan_inv_1');
      expect(balanceBefore.toRupees, 500000.0);

      // Perform rogue direct SQL mutation to legacy loans.paid_amount
      await db.rawUpdate(
        'UPDATE ${Tables.loans} SET paid_amount = 450000.0 WHERE id = ?',
        ['loan_inv_1'],
      );

      // Verify legacy row now has corrupted paid_amount
      final rogueRow = await db.query(
        Tables.loans,
        where: 'id = ?',
        whereArgs: ['loan_inv_1'],
      );
      expect(rogueRow.first['paid_amount'], 450000.0);

      // 1. Verify LoanRepo.getLoanById (paidAmount is derived from postings: total - remaining)
      final loanFromRepo = await loanRepo.getLoanById('loan_inv_1');
      expect(loanFromRepo, isNotNull);
      expect(loanFromRepo!.total, 500000.0);
      expect(loanFromRepo.paidAmount, 0.0); // Derived from canonical liability!

      // 2. Verify LoanService.getRemainingBalance
      final remaining = await loanService.getRemainingBalance('loan_inv_1');
      expect(remaining, 500000.0);

      // 3. Verify app_data.loansProvider
      final loans = await container.read(app_data.loansProvider.future);
      final l = loans.firstWhere((x) => x.id == 'loan_inv_1');
      expect(l.total, 500000.0);
      expect(l.paidAmount, 0.0);

      // 4. Verify liabilitiesProvider (loansProvider synchronized)
      final liabilitiesLoans = await container.read(loansProvider.future);
      final l2 = liabilitiesLoans.firstWhere((x) => x.id == 'loan_inv_1');
      expect(l2.paidAmount, 0.0);

      // 5. Verify liabilitiesSummaryProvider
      final summary = await container.read(liabilitiesSummaryProvider.future);
      expect(summary.totalLoanOutstanding, 500000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 2: Canonical loan disbursement increases liability correctly
    // -------------------------------------------------------------------------
    test('2. Canonical loan disbursement increases liability with net worth unchanged', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_disb_bank',
        name: 'HDFC Current',
        bank: 'HDFC',
        balance: 50000.0,
      ));

      final loan = Loan(
        id: 'loan_inv_2',
        name: 'Car Loan HDFC',
        bank: 'HDFC Bank',
        total: 300000.0,
        interestRate: 9.0,
        tenureMonths: 36,
        monthlyInstallment: 9540.0,
        startDate: DateTime.now(),
        paidAmount: 300000.0, // Initial liability is 0 prior to disbursement
        loanStatus: 'active',
        dueDay: 5,
      );
      await loanRepo.insertLoan(loan);

      // Canonical disbursement event: Dr Bank Asset, Cr Loan Liability
      final now = DateTime.now();
      final event = EconomicEvent.draft(
        id: 'evt_disb_1',
        canonicalType: CanonicalEventType.loanDisbursement,
        occurredAt: now,
        createdAt: now,
        description: 'loan disbursement',
      );
      final amount = Money.fromRupees(300000.0);
      final postings = [
        Posting(
          id: 'pst_disb_1',
          economicEventId: event.id,
          accountId: 'acc_disb_bank',
          direction: PostingDirection.debit, // Bank asset increases
          amount: amount,
          createdAt: now,
        ),
        Posting(
          id: 'pst_disb_2',
          economicEventId: event.id,
          accountId: 'loan_inv_2',
          direction: PostingDirection.credit, // Loan liability increases
          amount: amount,
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(event, postings: postings);

      // 1. Bank asset increased from 50k to 350k
      final bankBalance = await canonicalAccountRepo.getDerivedBalance('acc_disb_bank');
      expect(bankBalance.toRupees, 350000.0);

      // 2. Loan liability increased by 300k
      final loanBalance = await loanRepo.getDerivedBalance('loan_inv_2');
      expect(loanBalance.toRupees, 300000.0);

      // 3. Net Worth impact: delta is ZERO (Assets +300k, Liabilities +300k)
      final nw = (await netWorthService.calculate()).netWorth;
      // Initial: bank 50k, net worth 50k
      // After disb: bank 350k, loan 300k -> net worth 50k
      expect(nw, 50000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 3: Principal repayment decreases liability
    // -------------------------------------------------------------------------
    test('3. Principal repayment decreases loan liability and bank balance', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_rep_bank',
        name: 'Salary Acc',
        bank: 'ICICI',
        balance: 100000.0,
      ));

      final loan = Loan(
        id: 'loan_inv_3',
        name: 'Personal Loan',
        bank: 'ICICI',
        total: 100000.0,
        interestRate: 12.0,
        tenureMonths: 12,
        monthlyInstallment: 8885.0,
        startDate: DateTime.now(),
        paidAmount: 0.0, // Initial liability is 100k
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Principal repayment of ₹40,000: Dr Loan Liability, Cr Bank Asset
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_rep_3',
          canonicalType: CanonicalEventType.loanRepayment,
          occurredAt: DateTime.now(),
          createdAt: DateTime.now(),
        ),
        postings: [
          Posting(
            id: 'pst_r_3_1',
            economicEventId: 'evt_rep_3',
            accountId: 'loan_inv_3',
            direction: PostingDirection.debit, // Debit liability reduces debt
            amount: Money.fromRupees(40000.0),
            createdAt: DateTime.now(),
          ),
          Posting(
            id: 'pst_r_3_2',
            economicEventId: 'evt_rep_3',
            accountId: 'acc_rep_bank',
            direction: PostingDirection.credit, // Credit asset reduces bank
            amount: Money.fromRupees(40000.0),
            createdAt: DateTime.now(),
          ),
        ],
      );

      // Loan liability drops from 100k to 60k
      final remaining = await loanService.getRemainingBalance('loan_inv_3');
      expect(remaining, 60000.0);

      // Paid amount dynamically derived as 100k - 60k = 40k
      final l = await loanRepo.getLoanById('loan_inv_3');
      expect(l!.paidAmount, 40000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 4: Principal repayment creates zero expense
    // -------------------------------------------------------------------------
    test('4. Principal repayment creates zero expense postings', () async {
      final loan = Loan(
        id: 'loan_inv_4',
        name: 'Education Loan',
        bank: 'Canara',
        total: 50000.0,
        interestRate: 7.0,
        tenureMonths: 24,
        monthlyInstallment: 2238.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 15,
      );
      await loanRepo.insertLoan(loan);

      // Principal repayment: Dr Loan Liability, Cr Bank
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_rep_4',
          canonicalType: CanonicalEventType.loanRepayment,
          occurredAt: DateTime.now(),
          createdAt: DateTime.now(),
        ),
        postings: [
          Posting(
            id: 'pst_r_4_1',
            economicEventId: 'evt_rep_4',
            accountId: 'loan_inv_4',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(15000.0),
            createdAt: DateTime.now(),
          ),
          Posting(
            id: 'pst_r_4_2',
            economicEventId: 'evt_rep_4',
            accountId: TablesV24.sysEquityOpening,
            direction: PostingDirection.credit,
            amount: Money.fromRupees(15000.0),
            createdAt: DateTime.now(),
          ),
        ],
      );

      // Total expense must be ZERO
      final expenses = await canonicalQueryRepo.getTotalExpenses();
      expect(expenses.isZero, isTrue);
    });

    // -------------------------------------------------------------------------
    // Invariant 5: Interest payment creates expense without reducing principal
    // -------------------------------------------------------------------------
    test('5. Interest payment creates expense without reducing principal liability', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_int_bank',
        name: 'Axis Bank',
        bank: 'Axis',
        balance: 50000.0,
      ));

      final loan = Loan(
        id: 'loan_inv_5',
        name: 'Business Loan',
        bank: 'Axis',
        total: 200000.0,
        interestRate: 10.0,
        tenureMonths: 12,
        monthlyInstallment: 17583.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Interest payment of ₹2,000: Dr Interest Expense, Cr Bank
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_int_5',
          canonicalType: CanonicalEventType.expense,
          occurredAt: DateTime.now(),
          createdAt: DateTime.now(),
        ),
        postings: [
          Posting(
            id: 'pst_i_5_1',
            economicEventId: 'evt_int_5',
            accountId: TablesV24.sysExpInterest,
            direction: PostingDirection.debit, // Expense increased
            amount: Money.fromRupees(2000.0),
            createdAt: DateTime.now(),
          ),
          Posting(
            id: 'pst_i_5_2',
            economicEventId: 'evt_int_5',
            accountId: 'acc_int_bank',
            direction: PostingDirection.credit, // Bank decreased
            amount: Money.fromRupees(2000.0),
            createdAt: DateTime.now(),
          ),
        ],
      );

      // 1. Expense is exactly ₹2,000
      final totalExpenses = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExpenses.toRupees, 2000.0);

      // 2. Loan principal liability is completely untouched (still ₹200,000)
      final remaining = await loanService.getRemainingBalance('loan_inv_5');
      expect(remaining, 200000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 6: Combined EMI splits principal and interest correctly
    // -------------------------------------------------------------------------
    test('6. Combined EMI splits principal reduction and interest expense correctly', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_emi_bank',
        name: 'Kotak Bank',
        bank: 'Kotak',
        balance: 100000.0,
      ));

      final loan = Loan(
        id: 'loan_inv_6',
        name: 'Vehicle Loan',
        bank: 'Kotak',
        total: 100000.0,
        interestRate: 9.5,
        tenureMonths: 12,
        monthlyInstallment: 8768.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 10,
      );
      await loanRepo.insertLoan(loan);

      // 3-leg balanced EMI event:
      // Dr Loan Liability: ₹7,000 (Principal component)
      // Dr sys_exp_interest: ₹1,768 (Interest component)
      // Cr Bank Asset: ₹8,768 (Total EMI cash outflow)
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_emi_6',
          canonicalType: CanonicalEventType.loanRepayment,
          occurredAt: DateTime.now(),
          createdAt: DateTime.now(),
        ),
        postings: [
          Posting(
            id: 'pst_emi_6_1',
            economicEventId: 'evt_emi_6',
            accountId: 'loan_inv_6',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(7000.0),
            createdAt: DateTime.now(),
          ),
          Posting(
            id: 'pst_emi_6_2',
            economicEventId: 'evt_emi_6',
            accountId: TablesV24.sysExpInterest,
            direction: PostingDirection.debit,
            amount: Money.fromRupees(1768.0),
            createdAt: DateTime.now(),
          ),
          Posting(
            id: 'pst_emi_6_3',
            economicEventId: 'evt_emi_6',
            accountId: 'acc_emi_bank',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(8768.0),
            createdAt: DateTime.now(),
          ),
        ],
      );

      // 1. Loan liability reduced by principal component ONLY (100k - 7k = 93k)
      final remaining = await loanService.getRemainingBalance('loan_inv_6');
      expect(remaining, 93000.0);

      // 2. Expense created for interest component ONLY (₹1,768)
      final expense = await canonicalQueryRepo.getTotalExpenses();
      expect(expense.toRupees, 1768.0);

      // 3. Bank balance reduced by total EMI (100k - 8,768 = 91,232)
      final bank = await canonicalAccountRepo.getDerivedBalance('acc_emi_bank');
      expect(bank.toRupees, 91232.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 7: Rogue legacy installment mutation cannot alter canonical liability
    // -------------------------------------------------------------------------
    test('7. Rogue direct SQL mutations to loan_installments cannot alter canonical liability', () async {
      final loan = Loan(
        id: 'loan_inv_7',
        name: 'Gadget Loan',
        bank: 'Bajaj Finance',
        total: 40000.0,
        interestRate: 0.0,
        tenureMonths: 4,
        monthlyInstallment: 10000.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 2,
      );
      await loanRepo.insertLoan(loan);

      // Insert rogue fake installment directly into transitional table
      await db.rawInsert(
        'INSERT INTO ${Tables.loanInstallments} (id, loanId, dueDate, amount, principalComponent, interestComponent, status) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['rogue_inst_1', 'loan_inv_7', DateTime.now().toIso8601String(), 39999.0, 39999.0, 0.0, 'paid'],
      );

      // Canonical liability remains strictly ₹40,000
      final balance = await loanRepo.getDerivedBalance('loan_inv_7');
      expect(balance.toRupees, 40000.0);

      final remaining = await loanService.getRemainingBalance('loan_inv_7');
      expect(remaining, 40000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 8: Loan deletion/archive preserves historical canonical postings
    // -------------------------------------------------------------------------
    test('8. Loan deletion soft-archives if postings exist, preserving immutable ledger', () async {
      final loan = Loan(
        id: 'loan_inv_8',
        name: 'Mortgage Loan',
        bank: 'PNB',
        total: 800000.0,
        interestRate: 8.0,
        tenureMonths: 240,
        monthlyInstallment: 6692.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      // Verify active
      var activeLoans = await loanRepo.getLoans();
      expect(activeLoans.any((l) => l.id == 'loan_inv_8'), isTrue);

      // Delete loan
      await loanRepo.deleteLoan('loan_inv_8');

      // 1. Must be soft-archived (is_active = 0 in accounts)
      final row = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: ['loan_inv_8'],
      );
      expect(row.first['is_active'], 0);

      // 2. Postings preserved
      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['loan_inv_8'],
      );
      expect(postings.isNotEmpty, isTrue);

      // 3. Excluded from active loans
      container.invalidate(app_data.loansProvider);
      final loansAfter = await container.read(loansProvider.future);
      expect(loansAfter.any((l) => l.id == 'loan_inv_8'), isFalse);
    });

    // -------------------------------------------------------------------------
    // Invariant 9: Loan providers and services agree on outstanding liability
    // -------------------------------------------------------------------------
    test('9. All loan providers and services agree on canonical outstanding liability', () async {
      final loan = Loan(
        id: 'loan_inv_9',
        name: 'Gold Loan',
        bank: 'Muthoot',
        total: 150000.0,
        interestRate: 11.0,
        tenureMonths: 12,
        monthlyInstallment: 13258.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 15,
      );
      await loanRepo.insertLoan(loan);

      final repoBalance = (await loanRepo.getDerivedBalance('loan_inv_9')).toRupees;
      final svcBalance = await loanService.getRemainingBalance('loan_inv_9');
      final loanById = await loanRepo.getLoanById('loan_inv_9');
      final loanRemaining = loanById!.total - loanById.paidAmount;

      final loansFromProvider = await container.read(app_data.loansProvider.future);
      final providerLoan = loansFromProvider.firstWhere((l) => l.id == 'loan_inv_9');
      final providerRemaining = providerLoan.total - providerLoan.paidAmount;

      expect(repoBalance, 150000.0);
      expect(svcBalance, 150000.0);
      expect(loanRemaining, 150000.0);
      expect(providerRemaining, 150000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 10: Net worth reflects canonical loan liability only
    // -------------------------------------------------------------------------
    test('10. Net worth reflects canonical loan liability and is immune to legacy columns', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_loan',
        name: 'Savings',
        bank: 'SBI',
        balance: 200000.0,
      ));

      final loan = Loan(
        id: 'loan_inv_10',
        name: 'Auto Loan',
        bank: 'SBI',
        total: 50000.0,
        interestRate: 9.0,
        tenureMonths: 12,
        monthlyInstallment: 4373.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 5,
      );
      await loanRepo.insertLoan(loan);

      // Initial net worth: 200k asset - 50k liability = 150k
      expect((await netWorthService.calculate()).netWorth, 150000.0);

      // Corrupt legacy paid_amount
      await db.rawUpdate('UPDATE ${Tables.loans} SET paid_amount = 49000.0 WHERE id = ?', ['loan_inv_10']);

      // Net worth MUST remain strictly 150k
      expect((await netWorthService.calculate()).netWorth, 150000.0);
    });

    // =========================================================================
    // GOALS ADVERSARIAL TESTS (Invariants 11 - 18)
    // =========================================================================

    // -------------------------------------------------------------------------
    // Invariant 11: Rogue goals.current_amount mutation does not change goal progress
    // -------------------------------------------------------------------------
    test('11. Rogue goals.current_amount mutation has ZERO effect on goal progress', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_goal_11',
        name: 'Savings Acc',
        bank: 'HDFC',
        balance: 100000.0,
      ));

      final goal = Goal(
        id: 'goal_inv_11',
        title: 'Europe Vacation',
        type: GoalType.savings,
        targetAmount: 200000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 180)),
      );
      await goalRepo.insert(goal);

      // Earmark ₹45,000
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_inv_11',
        goalId: 'goal_inv_11',
        assetAccountId: 'acc_goal_11',
        earmarkedAmount: Money.fromRupees(45000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Rogue direct update to legacy table
      await db.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = 999999.0 WHERE id = ?',
        ['goal_inv_11'],
      );

      // 1. Verify GoalRepo.getDerivedProgress
      final derivedProgress = await goalRepo.getDerivedProgress('goal_inv_11');
      expect(derivedProgress, 45000.0);

      // 2. Verify GoalRepo.getGoalById
      final fetched = await goalRepo.getGoalById('goal_inv_11');
      expect(fetched!.currentAmount, 45000.0);

      // 3. Verify goalsProvider
      final allGoals = await container.read(goalsProvider.future);
      final g = allGoals.firstWhere((x) => x.id == 'goal_inv_11');
      expect(g.currentAmount, 45000.0);

      // 4. Verify goalByIdProvider
      final byId = container.read(goalByIdProvider('goal_inv_11'));
      expect(byId!.currentAmount, 45000.0);

      // 5. Verify goalDerivedProgressProvider
      final progressFromProvider = await container.read(goalDerivedProgressProvider('goal_inv_11').future);
      expect(progressFromProvider, 45000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 12: Earmark creation changes goal progress but creates zero postings
    // -------------------------------------------------------------------------
    test('12. Earmark creation produces ZERO postings and ZERO economic events', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_goal_12',
        name: 'Liquid Bank',
        bank: 'ICICI',
        balance: 80000.0,
      ));

      final goal = Goal(
        id: 'goal_inv_12',
        title: 'Emergency Fund',
        type: GoalType.savings,
        targetAmount: 100000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 365)),
      );
      await goalRepo.insert(goal);

      final eventsBefore = (await db.rawQuery('SELECT COUNT(*) as c FROM ${TablesV24.economicEvents}')).first['c'] as int;
      final postingsBefore = (await db.rawQuery('SELECT COUNT(*) as c FROM ${TablesV24.postings}')).first['c'] as int;

      // Create earmark of ₹30,000
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_inv_12',
        goalId: 'goal_inv_12',
        assetAccountId: 'acc_goal_12',
        earmarkedAmount: Money.fromRupees(30000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      final eventsAfter = (await db.rawQuery('SELECT COUNT(*) as c FROM ${TablesV24.economicEvents}')).first['c'] as int;
      final postingsAfter = (await db.rawQuery('SELECT COUNT(*) as c FROM ${TablesV24.postings}')).first['c'] as int;

      // Invariant: 0 postings, 0 events
      expect(eventsAfter, eventsBefore);
      expect(postingsAfter, postingsBefore);

      // Progress updated
      expect(await goalRepo.getDerivedProgress('goal_inv_12'), 30000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 13: Earmark deletion releases the reservation
    // -------------------------------------------------------------------------
    test('13. Earmark deletion releases reservation with zero postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_goal_13',
        name: 'Reserve Acc',
        bank: 'Axis',
        balance: 60000.0,
      ));

      final goal = Goal(
        id: 'goal_inv_13',
        title: 'Gadget Goal',
        type: GoalType.savings,
        targetAmount: 50000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 60)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_inv_13',
        goalId: 'goal_inv_13',
        assetAccountId: 'acc_goal_13',
        earmarkedAmount: Money.fromRupees(20000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      expect(await goalRepo.getDerivedProgress('goal_inv_13'), 20000.0);

      // Delete earmark
      await goalRepo.deleteEarmark('em_inv_13');

      // Progress drops back to 0.0
      expect(await goalRepo.getDerivedProgress('goal_inv_13'), 0.0);

      final totalEarmarked = await goalRepo.getTotalEarmarkedForAccount('acc_goal_13');
      expect(totalEarmarked.toRupees, 0.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 14: Multiple earmarks aggregate correctly
    // -------------------------------------------------------------------------
    test('14. Multiple earmarks across multiple accounts aggregate accurately', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_14_a', name: 'Bank A', bank: 'A', balance: 50000.0));
      await accountRepo.insertAccount(BankAccount(id: 'acc_14_b', name: 'Bank B', bank: 'B', balance: 50000.0));

      final goal = Goal(
        id: 'goal_inv_14',
        title: 'Wedding Fund',
        type: GoalType.savings,
        targetAmount: 100000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 90)),
      );
      await goalRepo.insert(goal);

      // Earmark 1: 15k on Bank A
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_14_1',
        goalId: 'goal_inv_14',
        assetAccountId: 'acc_14_a',
        earmarkedAmount: Money.fromRupees(15000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Earmark 2: 25k on Bank B
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_14_2',
        goalId: 'goal_inv_14',
        assetAccountId: 'acc_14_b',
        earmarkedAmount: Money.fromRupees(25000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Goal progress: 15k + 25k = 40k
      expect(await goalRepo.getDerivedProgress('goal_inv_14'), 40000.0);

      // Account-level earmark queries
      expect(await container.read(accountEarmarkedTotalProvider('acc_14_a').future), 15000.0);
      expect(await container.read(accountEarmarkedTotalProvider('acc_14_b').future), 25000.0);

      // Goal-level earmarks list
      final earmarks = await container.read(goalEarmarksProvider('goal_inv_14').future);
      expect(earmarks.length, 2);
    });

    // -------------------------------------------------------------------------
    // Invariant 15: Goal deletion releases/removes its earmarks
    // -------------------------------------------------------------------------
    test('15. Deleting a goal automatically releases all its active earmarks', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_15', name: 'Bank 15', bank: 'SBI', balance: 40000.0));

      final goal = Goal(
        id: 'goal_inv_15',
        title: 'Temporary Goal',
        type: GoalType.savings,
        targetAmount: 30000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      );
      await goalRepo.insert(goal);

      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_15',
        goalId: 'goal_inv_15',
        assetAccountId: 'acc_15',
        earmarkedAmount: Money.fromRupees(18000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      expect(await goalRepo.getDerivedProgress('goal_inv_15'), 18000.0);

      // Delete goal
      await goalRepo.delete('goal_inv_15');

      // Earmarks for goal must be 0
      final earmarksAfter = await goalRepo.getEarmarks('goal_inv_15');
      expect(earmarksAfter.isEmpty, isTrue);

      // Account earmarked total is 0
      final accountEarmarked = await goalRepo.getTotalEarmarkedForAccount('acc_15');
      expect(accountEarmarked.toRupees, 0.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 16: Goal progress cannot alter net worth by itself
    // -------------------------------------------------------------------------
    test('16. Goal earmarks have ZERO impact on Net Worth', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_goal',
        name: 'Wealth Acc',
        bank: 'HDFC',
        balance: 500000.0,
      ));

      final nwBefore = (await netWorthService.calculate()).netWorth;
      expect(nwBefore, 500000.0);

      final goal = Goal(
        id: 'goal_inv_16',
        title: 'Retirement Seed',
        type: GoalType.savings,
        targetAmount: 1000000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 365)),
      );
      await goalRepo.insert(goal);

      // Earmark ₹200,000
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_16',
        goalId: 'goal_inv_16',
        assetAccountId: 'acc_nw_goal',
        earmarkedAmount: Money.fromRupees(200000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Net Worth MUST remain strictly ₹500,000
      final nwAfter = (await netWorthService.calculate()).netWorth;
      expect(nwAfter, 500000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 17: Goal earmarks affect Safe-to-Spend correctly
    // -------------------------------------------------------------------------
    test('17. Safe-to-Spend is reduced by active earmarks, immune to legacy current_amount', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_sts_goal',
        name: 'Primary Bank',
        bank: 'Axis',
        balance: 100000.0,
      ));

      final goal = Goal(
        id: 'goal_inv_17',
        title: 'New Bike',
        type: GoalType.savings,
        targetAmount: 80000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 60)),
      );
      await goalRepo.insert(goal);

      // Safe-to-Spend before earmark: ₹100,000
      var sts = await canonicalQueryRepo.getSafeToSpend();
      expect(sts.safeToSpend.toRupees, 100000.0);

      // Earmark ₹35,000
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_17',
        goalId: 'goal_inv_17',
        assetAccountId: 'acc_sts_goal',
        earmarkedAmount: Money.fromRupees(35000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Safe-to-Spend after earmark: 100k - 35k = ₹65,000
      sts = await canonicalQueryRepo.getSafeToSpend();
      expect(sts.safeToSpend.toRupees, 65000.0);
      expect(sts.activeEarmarks.toRupees, 35000.0);

      // Direct rogue update to legacy current_amount
      await db.rawUpdate('UPDATE ${Tables.goals} SET current_amount = 999999.0 WHERE id = ?', ['goal_inv_17']);

      // Safe-to-Spend remains strictly ₹65,000
      sts = await canonicalQueryRepo.getSafeToSpend();
      expect(sts.safeToSpend.toRupees, 65000.0);
    });

    // -------------------------------------------------------------------------
    // Invariant 18: Legacy goal logs cannot override canonical goal progress
    // -------------------------------------------------------------------------
    test('18. Legacy goal_logs entries cannot override canonical earmark progress', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_log_18',
        name: 'Bank 18',
        bank: 'Kotak',
        balance: 50000.0,
      ));

      final goal = Goal(
        id: 'goal_inv_18',
        title: 'Fitness Gear',
        type: GoalType.savings,
        targetAmount: 30000.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 45)),
      );
      await goalRepo.insert(goal);

      // Active earmark of ₹12,000
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_18',
        goalId: 'goal_inv_18',
        assetAccountId: 'acc_log_18',
        earmarkedAmount: Money.fromRupees(12000.0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

      // Rogue entry in goal_logs table directly via SQL
      await db.rawInsert(
        'INSERT INTO ${Tables.goalLogs} (id, goal_id, amount, note, created_at) VALUES (?, ?, ?, ?, ?)',
        ['rogue_log_1', 'goal_inv_18', 77777.0, 'Rogue log insertion', DateTime.now().toIso8601String()],
      );

      // Goal progress remains strictly canonical: ₹12,000
      final progress = await goalRepo.getDerivedProgress('goal_inv_18');
      expect(progress, 12000.0);

      final g = await goalRepo.getGoalById('goal_inv_18');
      expect(g!.currentAmount, 12000.0);
    });
  });
}
