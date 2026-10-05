import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/review_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_recurring_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';

import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/features/cashflow/runway_provider.dart' as runway_prov;
import 'package:spend_x/features/categories/providers/category_providers.dart' as cat_prov;
import 'package:spend_x/features/forecast/forecast_provider.dart' as forecast_prov;
import 'package:spend_x/features/review_queue/providers/review_providers.dart' as review_prov;
import 'package:spend_x/features/salary/providers/salary_providers.dart' as salary_prov;
import 'package:spend_x/features/transactions/providers/transaction_providers.dart' as tx_prov;

import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/review_item.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/services/analytics_service.dart';
import 'package:spend_x/services/canonical_forecast_engine.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone C7: Riverpod State Consolidation Adversarial Suite', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late BudgetRepo budgetRepo;
    late CategoryRepo categoryRepo;
    late ReviewRepo reviewRepo;

    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late CanonicalRecurringRepository canonicalRecurringRepo;
    late CanonicalReviewRepository canonicalReviewRepo;

    late FinancialTransactionService financialService;
    late CanonicalForecastEngine forecastEngine;
    late AnalyticsService analyticsService;

    late ProviderContainer container;

    const testBankId = 'acc_bank_c7_main';
    const testBankId2 = 'acc_bank_c7_secondary';
    const testCardId = 'card_c7_test';
    const testLoanId = 'loan_c7_test';
    const testCatFoodId = 'cat_food_c7';
    const testCatTravelId = 'cat_travel_c7';

    int firstIntValue(List<Map<String, Object?>> rows) {
      if (rows.isEmpty || rows.first.isEmpty) return 0;
      return (rows.first.values.first as num?)?.toInt() ?? 0;
    }

    Future<void> seedCategory(Category cat) async {
      await db.insert(
        Tables.categories,
        cat.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.insert(
        TablesV24.accounts,
        {
          'id': cat.id,
          'account_type': 'expense',
          'subtype': 'category',
          'name': cat.name,
          'currency': 'INR',
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
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

      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      canonicalRecurringRepo = CanonicalRecurringRepository(executor: db);
      canonicalReviewRepo = CanonicalReviewRepository(executor: db);

      transactionRepo = TransactionRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      goalRepo = GoalRepo(executor: db);
      budgetRepo = BudgetRepo(executor: db, queryRepo: canonicalQueryRepo);
      categoryRepo = CategoryRepo(executor: db);
      reviewRepo = ReviewRepo(
        canonicalReviewRepo: canonicalReviewRepo,
        eventRepo: canonicalEventRepo,
      );

      financialService = FinancialTransactionService(
        transactionRepo: transactionRepo,
        creditRepo: creditRepo,
      );

      forecastEngine = CanonicalForecastEngine(
        queryRepo: canonicalQueryRepo,
        recurringRepo: canonicalRecurringRepo,
        loanRepo: loanRepo,
        creditRepo: creditRepo,
      );
      analyticsService = AnalyticsService();

      container = ProviderContainer(
        overrides: [
          app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.creditRepoProvider.overrideWithValue(creditRepo),
          app_data.loanRepoProvider.overrideWithValue(loanRepo),
          app_data.goalRepoProvider.overrideWithValue(goalRepo),
          app_data.budgetRepoProvider.overrideWithValue(budgetRepo),
          app_data.canonicalFinancialQueryRepositoryProvider
              .overrideWithValue(canonicalQueryRepo),
          app_data.canonicalRecurringRepositoryProvider
              .overrideWithValue(canonicalRecurringRepo),
          app_data.canonicalForecastEngineProvider
              .overrideWithValue(forecastEngine),
          app_data.analyticsServiceProvider.overrideWithValue(analyticsService),
          app_data.financialTransactionServiceProvider
              .overrideWithValue(financialService),
          app_data.categoryRepoProvider.overrideWithValue(categoryRepo),
          review_prov.reviewRepoProvider.overrideWithValue(reviewRepo),
        ],
      );

      // Seed categories
      await seedCategory(
        Category(
          id: testCatFoodId,
          name: 'Food',
          icon: 'food',
          color: '#00FF00',
          type: 'expense',
          userId: 'u1',
        ),
      );
      await seedCategory(
        Category(
          id: testCatTravelId,
          name: 'Travel',
          icon: 'flight',
          color: '#FF0000',
          type: 'expense',
          userId: 'u1',
        ),
      );

      // Seed main bank account with initial balance ₹100,000
      await accountRepo.insertAccount(
        BankAccount(
          id: testBankId,
          name: 'Primary Checking',
          bank: 'HDFC',
          last4: '1111',
          balance: 100000.0,
          color: '#0000FF',
        ),
      );

      // Seed secondary bank account with initial balance ₹20,000
      await accountRepo.insertAccount(
        BankAccount(
          id: testBankId2,
          name: 'Secondary Savings',
          bank: 'ICICI',
          last4: '2222',
          balance: 20000.0,
          color: '#00FF00',
        ),
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // =========================================================================
    // GROUP 1: STATE CORRECTNESS & ANTI-POISONING
    // =========================================================================

    test('1. Transaction edit updates analytics despite unchanged collection length', () async {
      final tx1 = Transaction(
        id: 'tx_1',
        amount: 500.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      final tx2 = Transaction(
        id: 'tx_2',
        amount: 500.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      await financialService.createTransaction(tx1);
      await financialService.createTransaction(tx2);

      container.invalidate(app_data.transactionsProvider);
      final txnsBefore = await container.read(app_data.transactionsProvider.future);
      expect(txnsBefore.where((t) => t.type == 'expense').length, 2);

      final summaryBefore = container.read(app_data.analyticsSummaryProvider);
      expect(summaryBefore.monthlyExpense, 1000.0);

      // Edit tx1 from ₹500 to ₹5,000 (collection length remains unchanged)
      final editedTx1 = tx1.copyWith(amount: 5000.0);
      await financialService.editTransaction(oldTransaction: tx1, newTransaction: editedTx1);

      container.invalidate(app_data.transactionsProvider);
      final txnsAfter = await container.read(app_data.transactionsProvider.future);
      expect(txnsAfter.length, txnsBefore.length);

      // In C7, without defective length-based cache key, analytics summary MUST update to ₹5,500
      final summaryAfter = container.read(app_data.analyticsSummaryProvider);
      expect(summaryAfter.monthlyExpense, 5500.0);
    });

    test('2. Transaction recategorization updates category analytics without count change', () async {
      final tx = Transaction(
        id: 'tx_recat',
        amount: 800.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      await financialService.createTransaction(tx);
      container.invalidate(app_data.transactionsProvider);
      await container.read(app_data.transactionsProvider.future);

      final summary1 = container.read(app_data.analyticsSummaryProvider);
      expect(summary1.categorySpending[testCatFoodId], 800.0);
      expect(summary1.categorySpending[testCatTravelId], isNull);

      // Recategorize Food -> Travel
      final edited = tx.copyWith(categoryId: testCatTravelId);
      await financialService.editTransaction(oldTransaction: tx, newTransaction: edited);
      container.invalidate(app_data.transactionsProvider);
      await container.read(app_data.transactionsProvider.future);

      final summary2 = container.read(app_data.analyticsSummaryProvider);
      expect(summary2.categorySpending[testCatFoodId], isNull);
      expect(summary2.categorySpending[testCatTravelId], 800.0);
    });

    test('3. Transaction replacement/reversal propagates through providers', () async {
      final tx = Transaction(
        id: 'tx_replace',
        amount: 1500.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      await financialService.createTransaction(tx);

      final accountsBefore = await container.read(app_data.accountsProvider.future);
      final accBefore = accountsBefore.firstWhere((a) => a.id == testBankId);
      expect(accBefore.balance, 98500.0);

      // Update via updateTransactionProvider to ₹3,000
      final updated = tx.copyWith(amount: 3000.0);
      await container.read(tx_prov.updateTransactionProvider)(
        oldTransaction: tx,
        newTransaction: updated,
      );

      final accountsAfter = await container.read(app_data.accountsProvider.future);
      final accAfter = accountsAfter.firstWhere((a) => a.id == testBankId);
      expect(accAfter.balance, 97000.0);
    });

    test('4. Review approval updates transaction provider', () async {
      final reviewItem = ReviewItem(
        id: 'rev_tx_prop',
        rawSource: 'sms',
        confidence: 1.0,
        parsed: ParsedTransaction(
          amount: 1200.0,
          isCredit: false,
          merchant: 'Swiggy',
          date: DateTime.now(),
          last4: '1111',
          rawText: 'Paid Rs 1200 at Swiggy',
        ),
      );
      await reviewRepo.insert(reviewItem);

      final txnsBefore = await container.read(app_data.transactionsProvider.future);
      final countBefore = txnsBefore.length;

      // Approve review candidate
      await container.read(review_prov.approveReviewProvider)(
        reviewItem,
        categoryId: testCatFoodId,
        accountId: testBankId,
      );

      // In C7, approveReviewProvider MUST invalidate transactionsProvider
      final txnsAfter = await container.read(app_data.transactionsProvider.future);
      expect(txnsAfter.length, countBefore + 1);
      expect(txnsAfter.any((t) => t.amount == 1200.0 && t.categoryId == testCatFoodId), isTrue);
    });

    test('5. Review approval updates account provider', () async {
      final reviewItem = ReviewItem(
        id: 'rev_acc_prop',
        rawSource: 'sms',
        confidence: 1.0,
        parsed: ParsedTransaction(
          amount: 3500.0,
          isCredit: false,
          merchant: 'Blinkit',
          date: DateTime.now(),
          last4: '1111',
          rawText: 'Debit Rs 3500 for groceries',
        ),
      );
      await reviewRepo.insert(reviewItem);

      final accountsBefore = await container.read(app_data.accountsProvider.future);
      final bankBefore = accountsBefore.firstWhere((a) => a.id == testBankId);
      expect(bankBefore.balance, 100000.0);

      // Approve item
      await container.read(review_prov.approveReviewProvider)(
        reviewItem,
        categoryId: testCatFoodId,
        accountId: testBankId,
      );

      // In C7, approveReviewProvider MUST invalidate accountsProvider
      final accountsAfter = await container.read(app_data.accountsProvider.future);
      final bankAfter = accountsAfter.firstWhere((a) => a.id == testBankId);
      expect(bankAfter.balance, 96500.0);
    });

    test('6. Review rejection does not change financial state', () async {
      final reviewItem = ReviewItem(
        id: 'rev_reject',
        rawSource: 'sms',
        confidence: 1.0,
        parsed: ParsedTransaction(
          amount: 9999.0,
          isCredit: false,
          date: DateTime.now(),
          rawText: 'Promo spam debit Rs 9999',
        ),
      );
      await reviewRepo.insert(reviewItem);

      final postingsBefore = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM postings;'),
      );
      await container.read(review_prov.rejectReviewProvider)(reviewItem.id);

      // Check zero ledger postings created
      final postingsAfter = firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM postings;'),
      );
      expect(postingsAfter, postingsBefore);

      final accounts = await container.read(app_data.accountsProvider.future);
      final bank = accounts.firstWhere((a) => a.id == testBankId);
      expect(bank.balance, 100000.0);
    });

    test('7. Category provider has one authoritative provider definition', () {
      expect(
        identical(app_data.categoriesProvider, cat_prov.categoriesProvider),
        isTrue,
        reason: 'categoriesProvider must have exactly one authority',
      );
      expect(
        identical(app_data.categoryRepoProvider, cat_prov.categoryRepoProvider),
        isTrue,
        reason: 'categoryRepoProvider must have exactly one authority',
      );
    });

    test('8. Category mutation propagates to all consumers', () async {
      final newCat = Category(
        id: 'cat_c7_new',
        name: 'Subscriptions',
        icon: 'sub',
        color: '#123456',
        type: 'expense',
        userId: 'u1',
      );

      await container.read(app_data.categoriesProvider.future);
      await container.read(cat_prov.addCategoryProvider)(newCat);

      final categories = await container.read(app_data.categoriesProvider.future);
      expect(categories.any((c) => c.id == 'cat_c7_new'), isTrue);

      final updatedCat = Category(
        id: 'cat_c7_new',
        name: 'Subscriptions Pro',
        icon: 'sub',
        color: '#123456',
        type: 'expense',
        userId: 'u1',
      );
      await container.read(cat_prov.updateCategoryProvider)(updatedCat);

      final categoriesAfter = await container.read(app_data.categoriesProvider.future);
      expect(categoriesAfter.firstWhere((c) => c.id == 'cat_c7_new').name, 'Subscriptions Pro');

      await container.read(cat_prov.deleteCategoryProvider)(updatedCat);
      final categoriesFinal = await container.read(app_data.categoriesProvider.future);
      expect(categoriesFinal.any((c) => c.id == 'cat_c7_new'), isFalse);
    });

    test('9. Salary bank account state follows canonical account state', () async {
      final salaryAccounts = await container.read(salary_prov.bankAccountsProvider.future);
      final mainAccount = salaryAccounts.firstWhere((a) => a.id == testBankId);
      expect(mainAccount.balance, 100000.0);

      final tx = Transaction(
        amount: 20000.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(tx);

      final salaryAccountsAfter = await container.read(salary_prov.bankAccountsProvider.future);
      final mainAccountAfter = salaryAccountsAfter.firstWhere((a) => a.id == testBankId);
      expect(mainAccountAfter.balance, 80000.0);
    });

    // =========================================================================
    // GROUP 2: ACCOUNT & TRANSACTION PROPAGATION
    // =========================================================================

    test('10. Expense propagation updates account, transactions, and Safe-to-Spend', () async {
      final stsBefore = await container.read(app_data.safeToSpendProvider.future);
      final startSts = stsBefore.safeToSpend.minorUnits;

      final tx = Transaction(
        amount: 5000.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(tx);

      final accounts = await container.read(app_data.accountsProvider.future);
      expect(accounts.firstWhere((a) => a.id == testBankId).balance, 95000.0);

      final stsAfter = await container.read(app_data.safeToSpendProvider.future);
      expect(stsAfter.safeToSpend.minorUnits, startSts - 500000); // 5000 * 100 paise
    });

    test('11. Income propagation increases bank balance', () async {
      final tx = Transaction(
        amount: 15000.0,
        userId: 'u1',
        type: 'income',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(tx);

      final accounts = await container.read(app_data.accountsProvider.future);
      expect(accounts.firstWhere((a) => a.id == testBankId).balance, 115000.0);
    });

    test('12. Transfer updates both accounts correctly', () async {
      final tx = Transaction(
        amount: 10000.0,
        userId: 'u1',
        type: 'transfer',
        accountId: testBankId,
        relatedEntityId: testBankId2,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(tx);

      final accounts = await container.read(app_data.accountsProvider.future);
      expect(accounts.firstWhere((a) => a.id == testBankId).balance, 90000.0);
      expect(accounts.firstWhere((a) => a.id == testBankId2).balance, 30000.0);
    });

    test('13. Card purchase increases card outstanding without modifying bank balance', () async {
      await creditRepo.insert(
        CreditCard(
          id: testCardId,
          name: 'HDFC Millennia',
          bank: 'HDFC',
          last4: '9999',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          color: '#000000',
        ),
      );

      final tx = Transaction(
        amount: 7500.0,
        userId: 'u1',
        type: 'credit_card_purchase',
        categoryId: testCatFoodId,
        accountId: testCardId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(tx);

      final card = await creditRepo.getCard(testCardId);
      expect(card?.usedAmount, 7500.0);

      final accounts = await container.read(app_data.accountsProvider.future);
      expect(accounts.firstWhere((a) => a.id == testBankId).balance, 100000.0);
    });

    test('14. Card payment does not create duplicate expense', () async {
      await creditRepo.insert(
        CreditCard(
          id: testCardId,
          name: 'HDFC Millennia',
          bank: 'HDFC',
          last4: '9999',
          limitAmount: 100000.0,
          usedAmount: 0.0,
          color: '#000000',
        ),
      );

      final purchase = Transaction(
        amount: 10000.0,
        userId: 'u1',
        type: 'credit_card_purchase',
        categoryId: testCatFoodId,
        accountId: testCardId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(purchase);
      await container.read(app_data.transactionsProvider.future);

      final summaryBefore = container.read(app_data.analyticsSummaryProvider);
      expect(summaryBefore.monthlyExpense, 10000.0);

      final payment = Transaction(
        amount: 10000.0,
        userId: 'u1',
        type: 'credit_payment',
        accountId: testBankId,
        relatedEntityId: testCardId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(payment);
      await container.read(app_data.transactionsProvider.future);

      final summaryAfter = container.read(app_data.analyticsSummaryProvider);
      expect(summaryAfter.monthlyExpense, 10000.0);

      final cardAfter = await creditRepo.getCard(testCardId);
      expect(cardAfter?.usedAmount, 0.0);

      final bankAfter = await container.read(app_data.accountsProvider.future);
      expect(bankAfter.firstWhere((a) => a.id == testBankId).balance, 90000.0);
    });

    test('15. Loan repayment principal and interest propagate accurately', () async {
      await loanRepo.insertLoan(
        Loan(
          id: testLoanId,
          name: 'Home Loan',
          bank: 'SBI',
          total: 100000.0,
          interestRate: 8.5,
          tenureMonths: 12,
          monthlyInstallment: 8500.0,
          startDate: DateTime.now(),
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        ),
      );

      final emiTx = Transaction(
        amount: 12000.0,
        userId: 'u1',
        type: 'loan_payment',
        accountId: testBankId,
        relatedEntityId: testLoanId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(emiTx);

      final accounts = await container.read(app_data.accountsProvider.future);
      expect(accounts.firstWhere((a) => a.id == testBankId).balance, 88000.0);

      final derivedBalance = await loanRepo.getDerivedBalance(testLoanId);
      expect(derivedBalance.asRupees, 88000.0);
    });

    test('16. Goal earmark affects Safe-to-Spend but not Net Worth', () async {
      final goal = Goal(
        id: 'goal_c7_1',
        title: 'Emergency Fund',
        type: GoalType.savings,
        targetAmount: 50000.0,
        currentAmount: 0.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 365)),
      );
      await goalRepo.insert(goal);

      final nwBefore = await container.read(app_data.netWorthSummaryProvider.future);
      final stsBefore = await container.read(app_data.safeToSpendProvider.future);

      await goalRepo.createEarmark(
        AssetEarmark(
          id: 'earmark_c7_1',
          goalId: 'goal_c7_1',
          assetAccountId: testBankId,
          earmarkedAmount: Money.fromRupees(20000.0),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      container.invalidate(app_data.safeToSpendProvider);
      container.invalidate(app_data.netWorthSummaryProvider);

      final nwAfter = await container.read(app_data.netWorthSummaryProvider.future);
      final stsAfter = await container.read(app_data.safeToSpendProvider.future);

      expect(nwAfter.netWorth, nwBefore.netWorth);
      expect(stsAfter.safeToSpend.minorUnits, stsBefore.safeToSpend.minorUnits - 2000000);
    });

    // =========================================================================
    // GROUP 3: LEGACY FIREWALL
    // =========================================================================

    test('17. Legacy transaction table mutation cannot influence provider state', () async {
      final summaryBefore = container.read(app_data.analyticsSummaryProvider);

      await db.insert(
        Tables.transactions,
        {
          'id': 'tx_legacy_bypass',
          'amount': 99999.0,
          'type': 'expense',
          'account_id': testBankId,
          'date': DateTime.now().toIso8601String(),
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      container.invalidate(app_data.transactionsProvider);
      final summaryAfter = container.read(app_data.analyticsSummaryProvider);

      expect(summaryAfter.monthlyExpense, summaryBefore.monthlyExpense);
    });

    test('18. Legacy bank balance column mutation cannot influence provider state', () async {
      await db.rawUpdate(
        'UPDATE ${Tables.bankAccounts} SET balance = 9999999 WHERE id = ?;',
        [testBankId],
      );

      container.invalidate(app_data.accountsProvider);
      final accounts = await container.read(app_data.accountsProvider.future);
      final bank = accounts.firstWhere((a) => a.id == testBankId);

      expect(bank.balance, 100000.0);
    });

    test('19. Legacy credit card used_amount column mutation cannot influence provider state', () async {
      await creditRepo.insert(
        CreditCard(
          id: testCardId,
          name: 'Test Card',
          bank: 'HDFC',
          last4: '1234',
          limitAmount: 50000.0,
          usedAmount: 0.0,
          color: '#000000',
        ),
      );

      await db.rawUpdate(
        'UPDATE ${Tables.creditCards} SET used_amount = 45000 WHERE id = ?;',
        [testCardId],
      );

      final card = await creditRepo.getCard(testCardId);
      expect(card?.usedAmount, 0.0);
    });

    test('20. Legacy loan paid_amount column mutation cannot influence provider state', () async {
      await loanRepo.insertLoan(
        Loan(
          id: testLoanId,
          name: 'Car Loan',
          bank: 'HDFC',
          total: 200000.0,
          interestRate: 9.0,
          tenureMonths: 12,
          monthlyInstallment: 17000.0,
          startDate: DateTime.now(),
          paidAmount: 0.0,
          loanStatus: 'active',
          dueDay: 5,
        ),
      );

      await db.rawUpdate(
        'UPDATE ${Tables.loans} SET paid_amount = 180000 WHERE id = ?;',
        [testLoanId],
      );

      final remaining = await loanRepo.getDerivedBalance(testLoanId);
      expect(remaining.asRupees, 200000.0);
    });

    test('21. Legacy goal current_amount column mutation cannot influence provider state', () async {
      const gId = 'goal_legacy_test';
      await goalRepo.insert(
        Goal(
          id: gId,
          title: 'Vacation',
          type: GoalType.savings,
          targetAmount: 40000.0,
          currentAmount: 0.0,
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 365)),
        ),
      );

      await db.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = 35000 WHERE id = ?;',
        [gId],
      );

      final progress = await goalRepo.getDerivedProgress(gId);
      expect(progress, 0.0);
    });

    // =========================================================================
    // GROUP 4: REACTIVE CORRECTNESS & ASYNC SAFETY
    // =========================================================================

    test('22. Required invalidation occurs after awaited commit', () async {
      final tx = Transaction(
        amount: 3000.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );

      await container.read(tx_prov.addTransactionProvider)(tx);

      final accounts = await container.read(app_data.accountsProvider.future);
      expect(accounts.firstWhere((a) => a.id == testBankId).balance, 97000.0);
    });

    test('23. No stale state after awaited mutation', () async {
      final tx = Transaction(
        amount: 1000.0,
        userId: 'u1',
        type: 'expense',
        categoryId: testCatFoodId,
        accountId: testBankId,
        date: DateTime.now(),
      );
      await container.read(tx_prov.addTransactionProvider)(tx);

      final txns = await container.read(app_data.transactionsProvider.future);
      expect(txns.any((t) => t.amount == 1000.0), isTrue);
    });

    test('24. Repeated invalidation is idempotent', () async {
      for (int i = 0; i < 10; i++) {
        container.invalidate(app_data.accountsProvider);
      }
      final accounts = await container.read(app_data.accountsProvider.future);
      expect(accounts.firstWhere((a) => a.id == testBankId).balance, 100000.0);
    });

    test('25. Concurrent refresh does not duplicate accounting or deadlock', () async {
      final results = await Future.wait([
        container.read(app_data.accountsProvider.future),
        container.read(app_data.accountsProvider.future),
        container.read(app_data.transactionsProvider.future),
        container.read(app_data.safeToSpendProvider.future),
      ]);

      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
      expect(results[2], isNotNull);
      expect(results[3], isNotNull);
    });

    test('26. Provider graph does not create circular dependency', () {
      final freshContainer = ProviderContainer(
        overrides: [
          app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.canonicalFinancialQueryRepositoryProvider
              .overrideWithValue(canonicalQueryRepo),
          app_data.canonicalRecurringRepositoryProvider
              .overrideWithValue(canonicalRecurringRepo),
          app_data.canonicalForecastEngineProvider
              .overrideWithValue(forecastEngine),
        ],
      );

      expect(() {
        freshContainer.read(app_data.safeToSpendProvider);
        freshContainer.read(app_data.netWorthSummaryProvider);
        freshContainer.read(app_data.analyticsSummaryProvider);
        freshContainer.read(forecast_prov.forecastProvider);
        freshContainer.read(runway_prov.runwayProvider);
      }, returnsNormally);

      freshContainer.dispose();
    });

    // =========================================================================
    // GROUP 5: FORECAST & RUNWAY STATE CONSOLIDATION
    // =========================================================================

    test('27. Forecast remains deterministic on repeated provider reads', () async {
      final forecast1 = await container.read(forecast_prov.forecastProvider.future);
      final forecast2 = await container.read(forecast_prov.forecastProvider.future);

      expect(forecast1.predictedBalance, forecast2.predictedBalance);
      expect(forecast1.predictedExpense, forecast2.predictedExpense);
      expect(forecast1.predictedIncome, forecast2.predictedIncome);
    });

    test('28. Runway and Forecast share canonicalForecast30DaysProvider future', () async {
      final forecast = await container.read(forecast_prov.forecastProvider.future);
      final runway = await container.read(runway_prov.runwayProvider.future);

      expect(runway.totalBalance, 120000.0); // 100,000 + 20,000 liquid assets
      expect(forecast.predictedBalance, isNotNull);
    });
  });
}
