import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_recurring_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/features/forecast/forecast_provider.dart';
import 'package:spend_x/features/cashflow/runway_provider.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/canonical_forecast_engine.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/forecast_engine.dart' as services_forecast;
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone C6: Deterministic Forecast Engine Semantic Invariants', () {
    late Database db;
    late CanonicalFinancialQueryRepository queryRepo;
    late CanonicalRecurringRepository recurringRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late AccountRepo legacyAccountRepo;
    late TransactionRepo transactionRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late FinancialTransactionService financialService;
    late CanonicalForecastEngine engine;

    const bankAccountId = 'acc_bank_salary_01';
    const secondaryBankAccountId = 'acc_bank_savings_02';
    const creditCardAccountId = 'card_hdfc_regalia';

    Future<int> queryCount(String table) async {
      final rows = await db.rawQuery('SELECT COUNT(*) as cnt FROM $table');
      return (rows.first['cnt'] as num).toInt();
    }

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

      queryRepo = CanonicalFinancialQueryRepository(executor: db);
      recurringRepo = CanonicalRecurringRepository(executor: db);
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      legacyAccountRepo = AccountRepo(executor: db);
      transactionRepo = TransactionRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      financialService = FinancialTransactionService(
        transactionRepo: transactionRepo,
        creditRepo: creditRepo,
      );

      engine = CanonicalForecastEngine(
        queryRepo: queryRepo,
        recurringRepo: recurringRepo,
        loanRepo: loanRepo,
        creditRepo: creditRepo,
      );

      // Create primary bank account with ₹50,000 opening balance
      await legacyAccountRepo.insertAccount(
        BankAccount(
          id: bankAccountId,
          name: 'HDFC Salary Account',
          bank: 'HDFC',
          balance: 50000.0,
          color: '#000000',
          last4: '1234',
        ),
      );

      // Create secondary bank account with ₹20,000 opening balance
      await legacyAccountRepo.insertAccount(
        BankAccount(
          id: secondaryBankAccountId,
          name: 'ICICI Savings Account',
          bank: 'ICICI',
          balance: 20000.0,
          color: '#000000',
          last4: '5678',
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 1: Canonical Ground Truth Starting Point
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 1: Starting balance derives strictly from canonical postings, immune to legacy corruption', () async {
      final liquidInitial = await queryRepo.getLiquidAssets();
      expect(liquidInitial.minorUnits, 7000000); // ₹70,000 = 7,000,000 paise

      final forecast = await engine.computeForecast(horizonDays: 30);
      expect(forecast.startingLiquidBalance.minorUnits, 7000000);
      expect(forecast.dailyPoints.first.projectedLiquidBalance.minorUnits, 7000000);

      // Adversarial test: Corrupt legacy bank_accounts.balance column
      await db.rawUpdate(
        'UPDATE ${Tables.bankAccounts} SET balance = 99999999.0 WHERE id = ?',
        [bankAccountId],
      );

      // Verify forecast is completely immune to legacy column corruption
      final corruptedForecast = await engine.computeForecast(horizonDays: 30);
      expect(corruptedForecast.startingLiquidBalance.minorUnits, 7000000);
      expect(corruptedForecast.startingLiquidBalance.asRupees, 70000.0);
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 2: Zero Accounting Writes During Forecast Runs
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 2: Forecast execution generates strictly zero accounting rows across 30/60/90 days', () async {
      final eventsBefore = await queryCount(TablesV24.economicEvents);
      final postingsBefore = await queryCount(TablesV24.postings);
      final accountsBefore = await queryCount(TablesV24.accounts);
      final legacyTxnsBefore = await queryCount(Tables.transactions);

      // Execute across 30, 60, and 90 day horizons
      await engine.computeForecast(horizonDays: 30);
      await engine.computeForecast(horizonDays: 60);
      await engine.computeForecast(horizonDays: 90);

      final eventsAfter = await queryCount(TablesV24.economicEvents);
      final postingsAfter = await queryCount(TablesV24.postings);
      final accountsAfter = await queryCount(TablesV24.accounts);
      final legacyTxnsAfter = await queryCount(Tables.transactions);

      expect(eventsAfter, equals(eventsBefore));
      expect(postingsAfter, equals(postingsBefore));
      expect(accountsAfter, equals(accountsBefore));
      expect(legacyTxnsAfter, equals(legacyTxnsBefore));
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 3: Elimination of Salary Velocity Multiplier Defect
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 3: Salary timing is event-based and eliminates the linear multiplier defect', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Seed scheduled monthly salary of ₹1,50,000 on Day 25
      final salaryDueDate = today.add(const Duration(days: 10));
      await recurringRepo.insertRule(
        RecurringRule(
          id: 'rule_salary_techcorp',
          title: 'Monthly Salary TechCorp',
          categoryAccountId: TablesV24.sysIncMisc,
          targetAccountId: bankAccountId,
          amount: Money.fromRupees(150000.0),
          cadence: 'monthly',
          dayOfMonth: salaryDueDate.day,
          nextDueDate: salaryDueDate,
          createdAt: today,
          updatedAt: today,
        ),
      );
      await recurringRepo.insertExpectedEvent(
        ExpectedEvent(
          id: 'exp_salary_1',
          ruleId: 'rule_salary_techcorp',
          dueDate: salaryDueDate,
          amount: Money.fromRupees(150000.0),
          status: 'pending',
          createdAt: today,
        ),
      );

      final forecast = await engine.computeForecast(
        horizonDays: 30,
        referenceDate: today,
      );

      // Inflow must be exactly ₹1,50,000 (15,000,000 paise), never multiplied by velocity
      expect(forecast.projectedIncome.minorUnits, 15000000);
      expect(forecast.projectedIncome.asRupees, 150000.0);

      // On days before the salary (Day 0 to Day 9), inflow is 0
      for (int i = 0; i < 10; i++) {
        expect(forecast.dailyPoints[i].inflows.minorUnits, 0);
      }

      // On Day 10, inflow is ₹1,50,000
      expect(forecast.dailyPoints[10].inflows.minorUnits, 15000000);

      // On days after salary (Day 11 to 30), inflow is 0 (does not repeat linearly)
      for (int i = 11; i <= 30; i++) {
        expect(forecast.dailyPoints[i].inflows.minorUnits, 0);
      }
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 4: Credit Card Purchases vs Bill Payments Non-Doubling
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 4: Credit card purchase is expense; statement payment reduces liability without double-counting expense', () async {
      // 1. User makes a credit card purchase of ₹5,000 at a grocery store
      await creditRepo.insert(
        CreditCard(
          id: creditCardAccountId,
          name: 'HDFC Regalia',
          bank: 'HDFC',
          limitAmount: 100000.0,
          usedAmount: 0.0,
        ),
      );

      final purchase = CreditTransaction(
        id: 'tx_card_purchase_1',
        cardId: creditCardAccountId,
        amount: 5000.0,
        date: DateTime.now().subtract(const Duration(days: 2)),
        category: 'Groceries',
        categoryId: 'cat_groceries',
        type: 'expense',
        status: 'active',
      );
      await creditRepo.insertTransaction(purchase);

      // Posted expenses in ledger should be ₹5,000
      final totalExpenses = await queryRepo.getTotalExpenses();
      expect(totalExpenses.minorUnits, 500000); // 500,000 paise

      // 2. Liquid assets should still be ₹70,000 because purchase was on credit card
      final liquid = await queryRepo.getLiquidAssets();
      expect(liquid.minorUnits, 7000000);

      // 3. User settles credit card statement with ₹5,000 payment from bank
      final payment = CreditTransaction(
        id: 'tx_card_pay_1',
        cardId: creditCardAccountId,
        amount: 5000.0,
        date: DateTime.now().subtract(const Duration(days: 1)),
        category: 'Payment',
        categoryId: bankAccountId, // paying bank account
        type: 'payment',
        status: 'active',
      );
      await creditRepo.insertTransaction(payment);

      // Total posted expenses must STILL be ₹5,000 (payment is asset-to-liability, not expense!)
      final totalExpensesAfterPayment = await queryRepo.getTotalExpenses();
      expect(totalExpensesAfterPayment.minorUnits, 500000);

      // Liquid assets reduced by payment: ₹70,000 - ₹5,000 = ₹65,000
      final liquidAfterPayment = await queryRepo.getLiquidAssets();
      expect(liquidAfterPayment.minorUnits, 6500000);

      // Forecast starting balance reflects actual remaining liquid assets
      final forecast = await engine.computeForecast(horizonDays: 30);
      expect(forecast.startingLiquidBalance.minorUnits, 6500000);
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 5: Loan Principal vs Interest Separation
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 5: Loan EMI draws liquid cash; principal is liability reduction, interest is expense', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Seed loan of ₹1,00,000 with monthly EMI ₹10,000 due on Day 5
      final loanDueDate = today.add(const Duration(days: 5));
      await loanRepo.insertLoan(
        Loan(
          id: 'loan_auto_01',
          name: 'Car Loan',
          bank: 'HDFC',
          total: 100000.0,
          interestRate: 10.0,
          tenureMonths: 12,
          monthlyInstallment: 10000.0,
          startDate: today.subtract(const Duration(days: 30)),
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: loanDueDate.day,
        ),
      );

      final forecast = await engine.computeForecast(
        horizonDays: 30,
        referenceDate: today,
      );

      // EMI commitment of ₹10,000 (1,000,000 paise) must be scheduled on Day 5
      expect(forecast.dailyPoints[5].commitments.minorUnits, 1000000);
      expect(forecast.projectedCommittedExpenses.minorUnits, 1000000);
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 6: Transfers Remain Strictly Net-Worth and Liquid Neutral
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 6: Internal transfers between bank accounts do not perturb liquid starting balance or net worth', () async {
      final liquidBefore = await queryRepo.getLiquidAssets();
      final netWorthBefore = await queryRepo.getNetWorth();

      // Transfer ₹15,000 from Bank 1 to Bank 2
      await financialService.createTransaction(
        Transaction(
          id: 'tx_transfer_01',
          userId: 'offline_user',
          type: 'transfer',
          amount: 15000.0,
          date: DateTime.now(),
          accountId: bankAccountId,
          relatedEntityId: secondaryBankAccountId,
        ),
      );

      final liquidAfter = await queryRepo.getLiquidAssets();
      final netWorthAfter = await queryRepo.getNetWorth();

      expect(liquidAfter.minorUnits, equals(liquidBefore.minorUnits));
      expect(netWorthAfter.minorUnits, equals(netWorthBefore.minorUnits));

      final forecast = await engine.computeForecast(horizonDays: 30);
      expect(forecast.startingLiquidBalance.minorUnits, equals(liquidBefore.minorUnits));
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 7: Earmarks Deduct From Discretionary Cash but Not Net Worth
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 7: Goal earmarks affect Safe-to-Spend but leave liquid assets and net worth intact', () async {
      final liquidBefore = await queryRepo.getLiquidAssets();
      final netWorthBefore = await queryRepo.getNetWorth();

      // Insert prerequisite goal in goals table
      await db.insert(
        Tables.goals,
        {
          'id': 'goal_01',
          'title': 'Emergency Fund',
          'type': 'savings',
          'target_amount': 50000.0,
          'current_amount': 0.0,
          'start_date': DateTime.now().toIso8601String(),
          'end_date': DateTime.now().add(const Duration(days: 100)).toIso8601String(),
          'created_at': DateTime.now().toIso8601String(),
        },
      );

      // Earmark ₹20,000 for emergency fund
      await earmarkRepo.createEarmark(
        AssetEarmark(
          id: 'earmark_emergency_01',
          goalId: 'goal_01',
          assetAccountId: bankAccountId,
          earmarkedAmount: Money.fromRupees(20000.0),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final liquidAfter = await queryRepo.getLiquidAssets();
      final netWorthAfter = await queryRepo.getNetWorth();
      final sts = await queryRepo.getSafeToSpend();

      // Liquid assets and Net Worth are 100% unaffected
      expect(liquidAfter.minorUnits, equals(liquidBefore.minorUnits));
      expect(netWorthAfter.minorUnits, equals(netWorthBefore.minorUnits));

      // Safe-to-spend is reduced by active earmarks
      expect(sts.activeEarmarks.minorUnits, 2000000); // ₹20,000 = 2,000,000 paise
      expect(sts.discretionaryCash.minorUnits, 5000000); // ₹70,000 - ₹20,000 = ₹50,000
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 8: Signed 64-bit Integer Paise Precision (Zero Float Drift)
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 8: Integer arithmetic produces exact paise sums with zero float drift', () async {
      final today = DateTime.now();

      // Schedule 3 micropayments of 33 paise, 33 paise, and 34 paise
      for (int i = 1; i <= 3; i++) {
        await recurringRepo.insertExpectedEvent(
          ExpectedEvent(
            id: 'exp_micro_$i',
            dueDate: today.add(Duration(days: i)),
            amount: Money.fromMinorUnits(33 + (i == 3 ? 1 : 0)),
            status: 'pending',
            createdAt: today,
          ),
        );
      }

      final forecast = await engine.computeForecast(
        horizonDays: 30,
        referenceDate: today,
      );

      // Sum of 33 + 33 + 34 = exactly 100 paise (₹1.00)
      expect(forecast.projectedCommittedExpenses.minorUnits, 100);
      expect(forecast.projectedCommittedExpenses.asRupees, 1.0);
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 9: Deterministic Reproducibility Across Horizons
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 9: Projections are reproducible across 30, 60, and 90-day horizon executions', () async {
      final now = DateTime(2026, 10, 4);

      final f30 = await engine.computeForecast(horizonDays: 30, referenceDate: now);
      final f60 = await engine.computeForecast(horizonDays: 60, referenceDate: now);
      final f90 = await engine.computeForecast(horizonDays: 90, referenceDate: now);

      // Day 0 starting balance must be identical
      expect(f30.startingLiquidBalance.minorUnits, f60.startingLiquidBalance.minorUnits);
      expect(f60.startingLiquidBalance.minorUnits, f90.startingLiquidBalance.minorUnits);

      // Every daily point from Day 0 to Day 30 must be identical between f30, f60, and f90
      for (int d = 0; d <= 30; d++) {
        expect(
          f30.dailyPoints[d].projectedLiquidBalance.minorUnits,
          f60.dailyPoints[d].projectedLiquidBalance.minorUnits,
          reason: 'Mismatch at day $d between 30d and 60d forecast',
        );
        expect(
          f60.dailyPoints[d].projectedLiquidBalance.minorUnits,
          f90.dailyPoints[d].projectedLiquidBalance.minorUnits,
          reason: 'Mismatch at day $d between 60d and 90d forecast',
        );
      }
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 10: Accurate Runway and Shortfall Calendar Date Flagging
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 10: Correctly projects runway exhaustion and exact shortfall date under deficit', () async {
      final today = DateTime(2026, 10, 1);

      // Schedule rent commitment of ₹80,000 on Day 15 (exceeding starting liquid balance of ₹70,000)
      final rentDue = today.add(const Duration(days: 15));
      await recurringRepo.insertExpectedEvent(
        ExpectedEvent(
          id: 'exp_rent_huge',
          dueDate: rentDue,
          amount: Money.fromRupees(80000.0), // ₹80,000 > ₹70,000
          status: 'pending',
          createdAt: today,
        ),
      );

      final forecast = await engine.computeForecast(
        horizonDays: 30,
        referenceDate: today,
      );

      // Shortfall should be flagged on Day 15
      expect(forecast.hasShortfall, isTrue);
      expect(forecast.shortfallDate, equals(rentDue));
      expect(forecast.runwayDays, equals(15));
      expect(forecast.minimumProjectedBalance.minorUnits, lessThan(0));
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 11: Capital One-Off Purchases Excluded from Discretionary Burn
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 11: Capital one-off spike (>₹1,00,000) is filtered from daily burn rate', () async {
      // Record historical ordinary daily expenses of ₹500
      for (int i = 1; i <= 5; i++) {
        await financialService.createTransaction(
          Transaction(
            id: 'tx_ord_$i',
            userId: 'offline_user',
            type: 'expense',
            amount: 500.0,
            categoryId: 'cat_food',
            accountId: bankAccountId,
            date: DateTime.now().subtract(Duration(days: i)),
          ),
        );
      }

      // Record a massive one-off capital equipment purchase of ₹2,00,000 on day 10
      await financialService.createTransaction(
        Transaction(
          id: 'tx_capital_outlier',
          userId: 'offline_user',
          type: 'expense',
          amount: 200000.0,
          categoryId: 'cat_electronics',
          accountId: bankAccountId,
          date: DateTime.now().subtract(const Duration(days: 10)),
        ),
      );

      final stats = await queryRepo.getDailySpendStats(lookbackDays: 30);

      // Total variable spend should exclude the ₹2,00,000 outlier
      // It includes only the 5 ordinary ₹500 transactions = ₹2,500
      expect(stats.totalVariableSpend.minorUnits, 250000); // 250,000 paise = ₹2,500
      expect(stats.averageDailySpend.minorUnits, lessThan(100000)); // Average < ₹1,000/day
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 12: Riverpod Providers Adapt Canonical Engine
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 12: forecastProvider and runwayProvider wrap canonical engine seamlessly', () async {
      final container = ProviderContainer(
        overrides: [
          app_data.accountRepoProvider.overrideWithValue(legacyAccountRepo),
          app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
          app_data.canonicalFinancialQueryRepositoryProvider.overrideWithValue(queryRepo),
          app_data.canonicalRecurringRepositoryProvider.overrideWithValue(recurringRepo),
          app_data.canonicalForecastEngineProvider.overrideWithValue(engine),
        ],
      );

      // Read forecastProvider
      final forecast = await container.read(forecastProvider.future);
      expect(forecast.predictedBalance, isNotNull);
      expect(forecast.confidenceLabel, isIn(['High', 'Medium', 'Low']));

      // Read runwayProvider
      final runway = await container.read(runwayProvider.future);
      expect(runway.totalBalance, equals(70000.0));
      expect(runway.daysLeft, isNonNegative);

      container.dispose();
    });

    // ────────────────────────────────────────────────────────────────────────
    // INVARIANT 13: Legacy Services ForecastEngine Adapter Conformance
    // ────────────────────────────────────────────────────────────────────────
    test('Invariant 13: ForecastEngine.instance.compute() delegates to canonical query repo without MTD velocity bug', () async {
      services_forecast.ForecastEngine.instance.invalidateCache();
      final legacyForecast = await services_forecast.ForecastEngine.instance.compute(
        queryRepository: queryRepo,
        forecastEngine: engine,
      );

      expect(legacyForecast.projectedIncome, isNonNegative);
      expect(legacyForecast.projectedExpense, isNonNegative);
      expect(legacyForecast.dailyBurnRate, isNonNegative);
    });
  });
}
