import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/salary_repo.dart';
import 'package:spend_x/data/repositories/lending_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/features/accounts/providers/account_providers.dart';
import 'package:spend_x/features/dashboard/providers/dashboard_providers.dart';
import 'package:spend_x/features/home/providers/home_providers.dart';
import 'package:spend_x/services/net_worth_service.dart';
import 'package:spend_x/services/financial_health_service.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/transaction.dart' as model;
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C4-2: Dashboard & Net Worth Canonical Read Migration Test Suite', () {
    late Database db;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late TransactionRepo transactionRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late NetWorthService netWorthService;
    late FinancialHealthService financialHealthService;
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

      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      goalRepo = GoalRepo(executor: db);
      transactionRepo = TransactionRepo(executor: db);

      netWorthService = NetWorthService(
        accountRepo,
        loanRepo,
        queryRepo: canonicalQueryRepo,
      );

      financialHealthService = FinancialHealthService(
        transactionRepo: transactionRepo,
        accountRepo: accountRepo,
        loanRepo: loanRepo,
        salaryRepo: SalaryRepo(),
        lendingRepo: LendingRepo(),
        categoryRepo: CategoryRepo(),
        queryRepo: canonicalQueryRepo,
      );

      container = ProviderContainer(
        overrides: [
          app_data.canonicalFinancialQueryRepositoryProvider
              .overrideWithValue(canonicalQueryRepo),
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.creditRepoProvider.overrideWithValue(creditRepo),
          app_data.loanRepoProvider.overrideWithValue(loanRepo),
          app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
          app_data.netWorthServiceProvider.overrideWithValue(netWorthService),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Test 1: NetWorthService derives exact Assets, Liabilities, and Net Worth
    // -------------------------------------------------------------------------
    test('1. NetWorthService derives Assets, Liabilities, and Net Worth from canonical double-entry postings', () async {
      // 1. Bank Account (Asset: ₹10,000)
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_1',
        name: 'HDFC Savings',
        bank: 'HDFC',
        balance: 10000.0,
      ));

      // 2. Credit Card (Liability: ₹2,000)
      await creditRepo.insert(CreditCard(
        id: 'card_nw_1',
        name: 'HDFC Millennia',
        bank: 'HDFC',
        limitAmount: 50000.0,
        billingDay: 1,
        dueDay: 20,
        usedAmount: 2000.0,
      ));

      // 3. Loan (Liability: ₹5,000)
      await loanRepo.insertLoan(Loan(
        id: 'loan_nw_1',
        name: 'Personal Loan',
        bank: 'SBI',
        total: 5000.0,
        paidAmount: 0.0,
        loanStatus: 'active',
        startDate: DateTime.now(),
        tenureMonths: 12,
        interestRate: 10.0,
        monthlyInstallment: 450.0,
        dueDay: 5,
        type: LoanType.reducing,
      ));

      final summary = await netWorthService.calculate();
      expect(summary.assets, equals(10000.0));
      expect(summary.liabilities, equals(7000.0));
      expect(summary.netWorth, equals(3000.0));

      // Check Riverpod netWorthSummaryProvider
      final providerSummary = await container.read(app_data.netWorthSummaryProvider.future);
      expect(providerSummary.assets, equals(10000.0));
      expect(providerSummary.liabilities, equals(7000.0));
      expect(providerSummary.netWorth, equals(3000.0));

      // Check netWorthProvider
      final netWorth = container.read(app_data.netWorthProvider);
      expect(netWorth, equals(3000.0));
    });

    // -------------------------------------------------------------------------
    // Test 2: Adversarial Rogue bank_accounts.balance update has ZERO effect
    // -------------------------------------------------------------------------
    test('2. Adversarial: Rogue UPDATE bank_accounts.balance has ZERO effect on Net Worth', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_2',
        name: 'Axis Bank',
        bank: 'Axis',
        balance: 15000.0,
      ));

      // Attacker executes raw SQL corrupting transitional balance column
      await db.execute("UPDATE bank_accounts SET balance = 999999.0 WHERE id = 'acc_nw_2';");

      final summary = await netWorthService.calculate();
      expect(summary.assets, equals(15000.0), reason: 'Rogue bank_accounts.balance was ignored');
      expect(summary.netWorth, equals(15000.0));

      final providerSummary = await container.read(app_data.netWorthSummaryProvider.future);
      expect(providerSummary.assets, equals(15000.0));
      expect(providerSummary.netWorth, equals(15000.0));
    });

    // -------------------------------------------------------------------------
    // Test 3: Adversarial Rogue credit_cards.used_amount update has ZERO effect
    // -------------------------------------------------------------------------
    test('3. Adversarial: Rogue UPDATE credit_cards.used_amount has ZERO effect on Net Worth', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_3',
        name: 'ICICI Bank',
        bank: 'ICICI',
        balance: 20000.0,
      ));
      await creditRepo.insert(CreditCard(
        id: 'card_nw_3',
        name: 'ICICI Coral',
        bank: 'ICICI',
        limitAmount: 100000.0,
        billingDay: 1,
        dueDay: 15,
        usedAmount: 3000.0,
      ));

      // Attacker executes raw SQL corrupting legacy used_amount
      await db.execute("UPDATE credit_cards SET used_amount = 888888.0 WHERE id = 'card_nw_3';");

      final summary = await netWorthService.calculate();
      expect(summary.liabilities, equals(3000.0), reason: 'Rogue credit_cards.used_amount was ignored');
      expect(summary.netWorth, equals(17000.0));

      final providerSummary = await container.read(app_data.netWorthSummaryProvider.future);
      expect(providerSummary.liabilities, equals(3000.0));
      expect(providerSummary.netWorth, equals(17000.0));
    });

    // -------------------------------------------------------------------------
    // Test 4: Adversarial Rogue loans.paid_amount & total update has ZERO effect
    // -------------------------------------------------------------------------
    test('4. Adversarial: Rogue UPDATE loans (paid_amount, total) has ZERO effect on Net Worth', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_4',
        name: 'Kotak Bank',
        bank: 'Kotak',
        balance: 25000.0,
      ));
      await loanRepo.insertLoan(Loan(
        id: 'loan_nw_4',
        name: 'Car Loan',
        bank: 'Kotak',
        total: 10000.0,
        paidAmount: 0.0,
        loanStatus: 'active',
        startDate: DateTime.now(),
        tenureMonths: 24,
        interestRate: 8.5,
        monthlyInstallment: 450.0,
        dueDay: 10,
        type: LoanType.reducing,
      ));

      // Attacker executes raw SQL corrupting legacy loans columns
      await db.execute("UPDATE loans SET paid_amount = 0, total = 999999.0 WHERE id = 'loan_nw_4';");

      final summary = await netWorthService.calculate();
      expect(summary.liabilities, equals(10000.0), reason: 'Rogue loans columns were ignored');
      expect(summary.netWorth, equals(15000.0));

      final providerSummary = await container.read(app_data.netWorthSummaryProvider.future);
      expect(providerSummary.liabilities, equals(10000.0));
      expect(providerSummary.netWorth, equals(15000.0));
    });

    // -------------------------------------------------------------------------
    // Test 5: Adversarial Rogue goals.current_amount update produces zero postings
    // -------------------------------------------------------------------------
    test('5. Adversarial: Rogue UPDATE goals.current_amount has zero postings and zero net worth impact', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_5',
        name: 'SBI Bank',
        bank: 'SBI',
        balance: 30000.0,
      ));

      await goalRepo.insert(Goal(
        id: 'goal_nw_5',
        title: 'Vacation',
        targetAmount: 50000.0,
        currentAmount: 10000.0,
        type: GoalType.savings,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 90)),
        isActive: true,
      ));

      // Attacker updates goals legacy current_amount
      await db.execute("UPDATE goals SET current_amount = 777777.0 WHERE id = 'goal_nw_5';");

      final summary = await netWorthService.calculate();
      expect(summary.assets, equals(30000.0));
      expect(summary.liabilities, equals(0.0));
      expect(summary.netWorth, equals(30000.0));
    });

    // -------------------------------------------------------------------------
    // Test 6: Adversarial Rogue legacy transactions table insert is IGNORED by dashboard
    // -------------------------------------------------------------------------
    test('6. Adversarial: Rogue INSERT into legacy transactions table is ignored by homeSummaryProvider', () async {
      final now = DateTime.now();

      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_6',
        name: 'Bank 6',
        bank: 'HDFC',
        balance: 10000.0,
      ));

      // Insert legitimate canonical expense via TransactionRepo
      await transactionRepo.insert(model.Transaction(
        id: 'canonical_exp_1',
        userId: 'user_1',
        amount: 2500.0,
        date: now,
        type: 'expense',
        categoryId: 'groceries',
        accountId: 'acc_nw_6',
      ));

      // Attacker inserts directly into legacy transactions table with raw SQL
      await db.execute('''
        INSERT INTO transactions (id, user_id, type, category_id, account_id, amount, date, notes, created_at, updated_at)
        VALUES ('rogue_tx_1', 'user_1', 'expense', 'other', 'acc_nw_6', 50000.0, '${now.toIso8601String()}', 'Rogue Hack', '${now.toIso8601String()}', '${now.toIso8601String()}');
      ''');

      // Refresh Riverpod state
      await container.read(app_data.transactionsProvider.future);
      final homeSummary = container.read(homeSummaryProvider);

      expect(homeSummary.expense, equals(2500.0), reason: 'Rogue legacy transaction must be ignored');
      expect(homeSummary.currentMonthExpense, equals(2500.0));
    });

    // -------------------------------------------------------------------------
    // Test 7: Adversarial Rogue ledger_transactions table insert is IGNORED by Net Worth
    // -------------------------------------------------------------------------
    test('7. Adversarial: Rogue INSERT into ledger_transactions is ignored by NetWorthService', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_7',
        name: 'PNB Bank',
        bank: 'PNB',
        balance: 40000.0,
      ));

      // Attacker inserts directly into ledger_transactions
      await db.execute('''
        INSERT INTO ledger_transactions (id, type, amount, date, note, created_at)
        VALUES ('rogue_ltx_1', 'expense', 20000.0, '${now.toIso8601String()}', 'Fake Drain', '${now.toIso8601String()}');
      ''');

      final summary = await netWorthService.calculate();
      expect(summary.assets, equals(40000.0), reason: 'Rogue ledger_transactions row had zero posting effect');
      expect(summary.netWorth, equals(40000.0));
    });

    // -------------------------------------------------------------------------
    // Test 8: Dashboard Income, Expense, and Balance calculation from canonical events
    // -------------------------------------------------------------------------
    test('8. Dashboard summary accurately aggregates canonical Income, Expense, and Balance', () async {
      final now = DateTime.now();

      await accountRepo.insertAccount(BankAccount(
        id: 'acc_nw_8',
        name: 'Bank 8',
        bank: 'SBI',
        balance: 0.0,
      ));

      await transactionRepo.insert(model.Transaction(
        id: 'tx_inc_1',
        userId: 'user_1',
        amount: 80000.0,
        date: now,
        type: 'income',
        categoryId: 'salary',
        accountId: 'acc_nw_8',
      ));

      await transactionRepo.insert(model.Transaction(
        id: 'tx_exp_1',
        userId: 'user_1',
        amount: 3200.0,
        date: now,
        type: 'expense',
        categoryId: 'utilities',
        accountId: 'acc_nw_8',
      ));

      await container.read(app_data.transactionsProvider.future);

      final homeSummary = container.read(homeSummaryProvider);
      expect(homeSummary.income, equals(80000.0));
      expect(homeSummary.expense, equals(3200.0));
      expect(homeSummary.balance, equals(76800.0));

      final dashSummary = container.read(dashboardSummaryProvider);
      expect(dashSummary.income, equals(80000.0));
      expect(dashSummary.expense, equals(3200.0));
      expect(dashSummary.balance, equals(76800.0));
    });

    // -------------------------------------------------------------------------
    // Test 9: Safe-to-Spend locked formula calculation
    // -------------------------------------------------------------------------
    test('9. Safe-to-Spend derives: Liquid Assets - Active Earmarks - Commitments floored at zero', () async {
      // 1. Liquid Asset Account: ₹50,000
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_sts_1',
        name: 'Liquid Account',
        bank: 'HDFC',
        balance: 50000.0,
      ));

      // 2. Goal with Asset Earmark of ₹15,000 on this account
      await goalRepo.insert(Goal(
        id: 'goal_sts_1',
        title: 'Emergency Fund',
        targetAmount: 50000.0,
        currentAmount: 0.0,
        type: GoalType.savings,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 180)),
        isActive: true,
      ));

      await goalRepo.createEarmark(
        AssetEarmark(
          id: 'em_sts_1',
          goalId: 'goal_sts_1',
          assetAccountId: 'acc_sts_1',
          earmarkedAmount: Money.fromRupees(15000.0),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final safeToSpend = await container.read(app_data.safeToSpendProvider.future);
      expect(safeToSpend.liquidAssets.toRupees, equals(50000.0));
      expect(safeToSpend.activeEarmarks.toRupees, equals(15000.0));
      expect(safeToSpend.discretionaryCash.toRupees, equals(35000.0));
      expect(safeToSpend.safeToSpend.toRupees, equals(35000.0));
      expect(safeToSpend.cashflowShortfall.toRupees, equals(0.0));
    });

    // -------------------------------------------------------------------------
    // Test 10: Safe-to-Spend floor at zero and shortfall deficit capture
    // -------------------------------------------------------------------------
    test('10. Safe-to-Spend floors at ₹0 and preserves shortfall when commitments exceed liquid assets', () async {
      // 1. Liquid Asset Account: ₹10,000
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_sts_def',
        name: 'Low Balance Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));

      // 2. High commitments: calculate with ₹15,000 commitments
      final safeToSpend = await canonicalQueryRepo.getSafeToSpend(
        knownCommitments14d: Money.fromRupees(15000.0),
      );

      expect(safeToSpend.liquidAssets.toRupees, equals(10000.0));
      expect(safeToSpend.discretionaryCash.toRupees, equals(-5000.0));
      expect(safeToSpend.safeToSpend.toRupees, equals(0.0), reason: 'safe_to_spend is floored at 0');
      expect(safeToSpend.cashflowShortfall.toRupees, equals(5000.0), reason: 'shortfall preserves deficit magnitude');
    });

    // -------------------------------------------------------------------------
    // Test 11: FinancialHealthService derives metrics immune to stale legacy columns
    // -------------------------------------------------------------------------
    test('11. FinancialHealthService debt ratio and net worth are immune to rogue legacy columns', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_fh_1',
        name: 'HDFC Bank',
        bank: 'HDFC',
        balance: 50000.0,
      ));
      await creditRepo.insert(CreditCard(
        id: 'card_fh_1',
        name: 'HDFC Card',
        bank: 'HDFC',
        limitAmount: 50000.0,
        billingDay: 1,
        dueDay: 20,
        usedAmount: 10000.0,
      ));

      // Corrupt legacy column
      await db.execute("UPDATE credit_cards SET used_amount = 999999.0 WHERE id = 'card_fh_1';");

      final metrics = await financialHealthService.calculateMetrics();
      // Assets = 50,000, Liabilities = 10,000 (from canonical postings)
      // Debt ratio = 10,000 / 50,000 = 0.2. Debt score = 1.0 - 0.2 = 0.8
      expect(metrics['debtRatio'], closeTo(0.8, 0.01));

      final histNw = await financialHealthService.getHistoricalNetWorth(DateTime.now());
      expect(histNw, equals(40000.0), reason: 'Net worth is 50,000 - 10,000 = 40,000');
    });

    // -------------------------------------------------------------------------
    // Test 12: End-to-end Riverpod invalidation updates dashboard and net worth reactively
    // -------------------------------------------------------------------------
    test('12. Reactive updates: adding a canonical transaction propagates to dashboard & net worth', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_react_1',
        name: 'ICICI Savings',
        bank: 'ICICI',
        balance: 20000.0,
      ));

      // Initial net worth
      var nwSummary = await container.read(app_data.netWorthSummaryProvider.future);
      expect(nwSummary.netWorth, equals(20000.0));

      // Post expense of ₹5,000 through TransactionRepo
      await transactionRepo.insert(model.Transaction(
        id: 'tx_react_1',
        userId: 'user_1',
        amount: 5000.0,
        date: DateTime.now(),
        type: 'expense',
        categoryId: 'shopping',
        accountId: 'acc_react_1',
      ));

      // Invalidate and refresh
      container.invalidate(accountsProvider);
      container.invalidate(app_data.transactionsProvider);
      container.invalidate(app_data.netWorthSummaryProvider);

      nwSummary = await container.read(app_data.netWorthSummaryProvider.future);
      expect(nwSummary.assets, equals(15000.0));
      expect(nwSummary.netWorth, equals(15000.0));
    });
  });
}
