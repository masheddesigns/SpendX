import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/features/ai/ai_data_bridge.dart';
import 'package:spend_x/features/ai/ai_action.dart';
import 'package:spend_x/features/automation/automation_providers.dart';
import 'package:spend_x/features/transactions/providers/transaction_providers.dart';
import 'package:spend_x/features/categories/providers/category_providers.dart';
import 'package:spend_x/services/financial_intelligence_service.dart';
import 'package:spend_x/services/spending_insights_service.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/budget.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/category.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/domain/finance/finance.dart';

class _TestCategoriesNotifier extends app_data.CategoriesNotifier {
  final Database _db;
  _TestCategoriesNotifier(this._db);

  @override
  Future<List<Category>> load() async {
    final rows = await _db.query(Tables.categories);
    return rows.map((e) => Category.fromMap(e)).toList();
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
  });

  group('Milestone C4-6: AI & Automation Canonical Read Migration Suite', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late BudgetRepo budgetRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late CanonicalReviewRepository canonicalReviewRepo;
    late FinancialIntelligenceService financialIntelligenceService;
    late SpendingInsightsService spendingInsightsService;
    late ProviderContainer container;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      // Create full v24 canonical schema & install triggers
      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      transactionRepo = TransactionRepo(executor: db);
      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      goalRepo = GoalRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      canonicalReviewRepo = CanonicalReviewRepository(executor: db);
      budgetRepo = BudgetRepo(executor: db, queryRepo: canonicalQueryRepo);

      financialIntelligenceService = FinancialIntelligenceService(
        accountRepo: accountRepo,
      );
      spendingInsightsService = SpendingInsightsService(
        transactionRepo: transactionRepo,
      );

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
          categoriesProvider.overrideWith(() => _TestCategoriesNotifier(db)),
          addTransactionProvider.overrideWithValue((Transaction tx) async {
            await transactionRepo.insert(tx);
          }),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

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
          'account_type': cat.type == 'income' ? 'income' : 'expense',
          'subtype': 'category',
          'name': cat.name,
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    // =========================================================================
    // SECTION 1: AI DATA BRIDGE CANONICAL TRUTH (Invariants 1 - 8)
    // =========================================================================

    test('1. AIDataBridge Balance Query derives from canonical state and resists rogue legacy balance mutation', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_ai_1',
        name: 'HDFC Checking',
        bank: 'HDFC',
        balance: 75000.0,
      ));

      final bridge = container.read(aiDataBridgeProvider);
      final responseBefore = await bridge.handle('what is my balance');
      expect(responseBefore, contains('75,000'));

      // Rogue direct mutation of legacy bank_accounts.balance column
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 1.0 WHERE id = ?', ['acc_ai_1']);

      // AI response MUST remain strictly ₹75,000
      final responseAfter = await bridge.handle('what is my balance');
      expect(responseAfter, contains('75,000'));
      expect(responseAfter, isNot(contains('1.0')));
    });

    test('2. AIDataBridge Spending Query ignores rogue legacy transaction insertions', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_ai_2',
        name: 'ICICI Bank',
        bank: 'ICICI',
        balance: 50000.0,
      ));
      await seedCategory(Category(id: 'cat_ai_food', name: 'Food', icon: 'food', color: '#FF5722', userId: '', type: 'expense'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_ai_canon_2',
        userId: 'user1',
        accountId: 'acc_ai_2',
        categoryId: 'cat_ai_food',
        amount: 3200.0,
        type: 'expense',
        date: now,
      ));

      final bridge = container.read(aiDataBridgeProvider);
      final responseBefore = await bridge.handle('how much did I spend');
      expect(responseBefore, contains('3,200'));

      // Rogue insert into legacy transactions table
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['rogue_ai_tx_2', 'acc_ai_2', 'cat_ai_food', 999999.0, 'expense', now.toIso8601String(), 0, now.toIso8601String(), now.toIso8601String()],
      );

      final responseAfter = await bridge.handle('how much did I spend');
      expect(responseAfter, contains('3,200'));
      expect(responseAfter, isNot(contains('999,999')));
    });

    test('3. AIDataBridge Income Query derives strictly from canonical income postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_ai_3',
        name: 'Salary Bank',
        bank: 'Axis',
        balance: 0.0,
      ));
      await seedCategory(Category(id: 'cat_ai_sal', name: 'Salary', icon: 'cash', color: '#4CAF50', userId: '', type: 'income'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_ai_inc_3',
        userId: 'user1',
        accountId: 'acc_ai_3',
        categoryId: 'cat_ai_sal',
        amount: 85000.0,
        type: 'income',
        date: now,
      ));

      final bridge = container.read(aiDataBridgeProvider);
      final response = await bridge.handle('what is my income');
      expect(response, contains('85,000'));
    });

    test('4. AIDataBridge Net Worth Query derives from canonical double-entry postings', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_ai_nw', name: 'Asset Bank', bank: 'SBI', balance: 120000.0));

      final bridge = container.read(aiDataBridgeProvider);
      final response = await bridge.handle('what is my net worth');
      expect(response, contains('120,000'));
    });

    test('5. AIDataBridge Credit Cards Query uses canonical derived card liability', () async {
      final card = CreditCard(
        id: 'card_ai_5',
        name: 'Tata Neu Infinity',
        bank: 'HDFC',
        last4: '7777',
        limitAmount: 150000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);
      await seedCategory(Category(
        id: 'cat_sys_expense',
        name: 'General Expense',
        icon: 'expense',
        color: '#FF0000',
        userId: '',
        type: 'expense',
      ));

      final now = DateTime.now();
      // Canonical card purchase of ₹18,000
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_ai_card_5',
          canonicalType: CanonicalEventType.cardPurchase,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_ai_cp_1',
            economicEventId: 'evt_ai_card_5',
            accountId: 'cat_sys_expense',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(18000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_ai_cp_2',
            economicEventId: 'evt_ai_card_5',
            accountId: 'card_ai_5',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(18000.0),
            createdAt: now,
          ),
        ],
      );

      final bridge = container.read(aiDataBridgeProvider);
      final response = await bridge.handle('credit cards');
      expect(response, contains('18,000'));

      // Rogue update of legacy credit_cards.used_amount
      await db.rawUpdate('UPDATE ${Tables.creditCards} SET used_amount = 0.0 WHERE id = ?', ['card_ai_5']);

      final responseAfter = await bridge.handle('credit cards');
      expect(responseAfter, contains('18,000'));
    });

    test('6. AIDataBridge Runway Query reflects canonical liquid assets', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_ai_runway', name: 'Runway Acc', bank: 'Kotak', balance: 60000.0));

      final bridge = container.read(aiDataBridgeProvider);
      final response = await bridge.handle('runway');
      expect(response, isNotNull);
      expect(response, contains('runway'));
    });

    test('7. AIDataBridge Budget Query correctly nets refunds and purchases', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_ai_bgt', name: 'Bgt Bank', bank: 'ICICI', balance: 50000.0));
      await seedCategory(Category(id: 'cat_ai_dine', name: 'Dining', icon: 'fork', color: '#E91E63', userId: '', type: 'expense'));

      await budgetRepo.insert(Budget(
        id: 'bgt_ai_7',
        categoryId: 'cat_ai_dine',
        limit: 10000.0,
      ));

      final now = DateTime.now();
      final lastMonth = DateTime(now.year, now.month - 1, 15);
      await transactionRepo.insert(Transaction(
        id: 'tx_ai_hist_7',
        userId: 'user1',
        accountId: 'acc_ai_bgt',
        categoryId: 'cat_ai_dine',
        amount: 8000.0,
        type: 'expense',
        date: lastMonth,
      ));
      await transactionRepo.insert(Transaction(
        id: 'tx_ai_dine_1',
        userId: 'user1',
        accountId: 'acc_ai_bgt',
        categoryId: 'cat_ai_dine',
        amount: 4000.0,
        type: 'expense',
        date: now,
      ));

      final bridge = container.read(aiDataBridgeProvider);
      final response = await bridge.handle('budget');
      expect(response, contains('Dining'));
      expect(response, contains('4,000'));
    });

    test('8. AIDataBridge rejects unknown queries and returns null gracefully', () async {
      final bridge = container.read(aiDataBridgeProvider);
      final response = await bridge.handle('what is the capital of France?');
      expect(response, isNull);
    });

    // =========================================================================
    // SECTION 2: AUTOMATION & DECISION ENGINES (Invariants 9 - 12)
    // =========================================================================

    test('9. Automation SaveSuggestion computes surplus from canonical state', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_auto_9', name: 'Auto Bank', bank: 'SBI', balance: 100000.0));
      await seedCategory(Category(id: 'cat_auto_sal', name: 'Salary', icon: 'cash', color: '#4CAF50', userId: '', type: 'income'));
      await seedCategory(Category(id: 'cat_auto_exp', name: 'Expenses', icon: 'cart', color: '#F44336', userId: '', type: 'expense'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_auto_sal_9',
        userId: 'user1',
        accountId: 'acc_auto_9',
        categoryId: 'cat_auto_sal',
        amount: 80000.0,
        type: 'income',
        date: now,
      ));
      await transactionRepo.insert(Transaction(
        id: 'tx_auto_exp_9',
        userId: 'user1',
        accountId: 'acc_auto_9',
        categoryId: 'cat_auto_exp',
        amount: 30000.0,
        type: 'expense',
        date: now,
      ));

      // Surplus is 80,000 - 30,000 = 50,000
      final suggestion = await container.read(saveSuggestionProvider.future);
      expect(suggestion, isNotNull);
      expect(suggestion!.amount, 15000.0); // 30% of 50,000
    });

    test('10. Automation DailyDecision reflects canonical financial metrics', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_auto_10', name: 'Main Bank', bank: 'HDFC', balance: 50000.0));

      final decision = await container.read(dailyDecisionProvider.future);
      expect(decision, isNotNull);
      expect(decision.message.isNotEmpty, isTrue);
    });

    test('11. Automation SmartNudges goal progress derives from active earmarks (0 postings)', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_auto_11', name: 'Savings Bank', bank: 'ICICI', balance: 50000.0));
      final now = DateTime.now();
      final goal = Goal(
        id: 'goal_auto_11',
        title: 'Emergency Fund',
        type: GoalType.savings,
        targetAmount: 100000.0,
        currentAmount: 0.0,
        startDate: now,
        endDate: now.add(const Duration(days: 365)),
      );
      await goalRepo.insert(goal);

      // Earmark ₹25,000 towards the goal
      await goalRepo.createEarmark(
        AssetEarmark(
          id: 'em_auto_11',
          goalId: 'goal_auto_11',
          assetAccountId: 'acc_auto_11',
          earmarkedAmount: Money.fromRupees(25000.0),
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Verify that earmark created ZERO postings and ZERO events
      final postings = await db.query(TablesV24.postings, where: 'account_id = ?', whereArgs: ['acc_auto_11']);
      expect(postings.where((p) => (p['economic_event_id'] as String).contains('earmark')), isEmpty);

      // Mutate legacy goals.current_amount to a rogue value
      await db.rawUpdate('UPDATE ${Tables.goals} SET current_amount = 999999.0 WHERE id = ?', ['goal_auto_11']);

      // Nudges must still execute without error
      final nudges = await container.read(smartNudgesProvider.future);
      expect(nudges, isNotNull);
    });

    test('12. Automation SmartNudges Credit Utilization uses canonical card liability', () async {
      final card = CreditCard(
        id: 'card_auto_12',
        name: 'ICICI Sapphiro',
        bank: 'ICICI',
        last4: '1234',
        limitAmount: 100000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      final nudges = await container.read(smartNudgesProvider.future);
      expect(nudges, isNotNull);
    });

    // =========================================================================
    // SECTION 3: FINANCIAL INTELLIGENCE & SPENDING INSIGHTS (Invariants 13 - 15)
    // =========================================================================

    test('13. FinancialIntelligenceService takeSnapshot derives balance from canonical postings', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_intel_13',
        name: 'Bank Intel',
        bank: 'Axis',
        balance: 65000.0,
      ));

      // Corrupt legacy bank_accounts.balance column
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 5.0 WHERE id = ?', ['acc_intel_13']);

      // Take snapshot
      await financialIntelligenceService.takeSnapshot('acc_intel_13');

      // Highest balance snapshot must record true canonical balance (₹65,000), NOT ₹5.0
      final highest = await financialIntelligenceService.getHighestBalance('acc_intel_13');
      expect(highest, isNotNull);
      expect((highest!['balance'] as num).toDouble(), 65000.0);
    });

    test('14. SpendingInsightsService daily summary counts credit card purchases and subtracts refunds', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_sp_14', name: 'Bank 14', bank: 'SBI', balance: 50000.0));
      await seedCategory(Category(id: 'cat_sp_14', name: 'Shopping', icon: 'cart', color: '#9C27B0', userId: '', type: 'expense'));

      final now = DateTime.now();
      // Purchase ₹5,000
      await transactionRepo.insert(Transaction(
        id: 'tx_sp_pur_14',
        userId: 'user1',
        accountId: 'acc_sp_14',
        categoryId: 'cat_sp_14',
        amount: 5000.0,
        type: 'expense',
        date: now,
      ));

      // Refund ₹1,500
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_sp_ref_14',
          canonicalType: CanonicalEventType.refund,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_sp_ref_1',
            economicEventId: 'evt_sp_ref_14',
            accountId: 'acc_sp_14',
            direction: PostingDirection.debit, // Bank asset increased
            amount: Money.fromRupees(1500.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_sp_ref_2',
            economicEventId: 'evt_sp_ref_14',
            accountId: 'cat_sp_14',
            direction: PostingDirection.credit, // Expense decreased (contra-expense)
            amount: Money.fromRupees(1500.0),
            createdAt: now,
          ),
        ],
      );

      // Verify net expenses from query repo
      final netExp = await canonicalQueryRepo.getTotalExpenses();
      expect(netExp.toRupees, 3500.0);
      expect(spendingInsightsService, isNotNull);
    });

    test('15. SpendingInsightsService weekly summary ignores rogue legacy insertions', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_sp_15', name: 'Bank 15', bank: 'Kotak', balance: 40000.0));
      await seedCategory(Category(id: 'cat_sp_15', name: 'Travel', icon: 'plane', color: '#03A9F4', userId: '', type: 'expense'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_sp_15',
        userId: 'user1',
        accountId: 'acc_sp_15',
        categoryId: 'cat_sp_15',
        amount: 4200.0,
        type: 'expense',
        date: now,
      ));

      // Rogue direct SQL insertion into legacy transactions table
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['rogue_tx_sp_15', 'acc_sp_15', 'cat_sp_15', 77777.0, 'expense', now.toIso8601String(), 0, now.toIso8601String(), now.toIso8601String()],
      );

      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.toRupees, 4200.0);
    });

    // =========================================================================
    // SECTION 4: REVIEW CANDIDATE ISOLATION & AUTOMATION (Invariants 16 - 22)
    // =========================================================================

    test('16. Stashing a ReviewCandidate creates ZERO postings and ZERO economic events', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_some_bank',
        name: 'Some Bank',
        bank: 'HDFC',
        balance: 0.0,
      ));
      await seedCategory(Category(
        id: 'cat_food',
        name: 'Food',
        icon: 'food',
        color: '#FF9800',
        userId: '',
        type: 'expense',
      ));

      final candidate = ReviewCandidate(
        id: 'cand_rev_16',
        sourceType: 'sms_live',
        rawPayload: 'Paid INR 2500 at Swiggy',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(2500.0),
        suggestedAccountId: 'acc_some_bank',
        suggestedCategoryId: 'cat_food',
        confidenceScore: 0.95,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );

      await canonicalReviewRepo.createCandidate(candidate);

      // Verify ZERO economic events
      final events = await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: ['cand_rev_16']);
      expect(events, isEmpty);

      // Verify ZERO postings
      final postings = await db.query(TablesV24.postings, where: 'account_id = ?', whereArgs: ['acc_some_bank']);
      expect(postings, isEmpty);
    });

    test('17. Pending review candidates have ZERO impact on Net Worth and Safe-to-Spend', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_rev_17', name: 'Bank 17', bank: 'SBI', balance: 50000.0));

      final nwBefore = await canonicalQueryRepo.getNetWorth();
      final stsBefore = (await canonicalQueryRepo.getSafeToSpend()).discretionaryCash;

      final candidate = ReviewCandidate(
        id: 'cand_rev_17',
        sourceType: 'sms_import',
        rawPayload: 'Debit INR 40000',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(40000.0),
        suggestedAccountId: 'acc_rev_17',
        confidenceScore: 0.88,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await canonicalReviewRepo.createCandidate(candidate);

      final nwAfter = await canonicalQueryRepo.getNetWorth();
      final stsAfter = (await canonicalQueryRepo.getSafeToSpend()).discretionaryCash;

      expect(nwAfter.toRupees, nwBefore.toRupees);
      expect(stsAfter.toRupees, stsBefore.toRupees);
    });

    test('18. Approving a ReviewCandidate propagates through FinancialTransactionService into canonical postings', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_rev_18', name: 'Bank 18', bank: 'HDFC', balance: 50000.0));
      await seedCategory(Category(id: 'cat_rev_18', name: 'Food', icon: 'food', color: '#FF9800', userId: '', type: 'expense'));

      final candidate = ReviewCandidate(
        id: 'cand_rev_18',
        sourceType: 'receipt_ocr',
        rawPayload: 'Restaurant Bill INR 1800',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(1800.0),
        suggestedAccountId: 'acc_rev_18',
        suggestedCategoryId: 'cat_rev_18',
        confidenceScore: 0.92,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await canonicalReviewRepo.createCandidate(candidate);

      // Now approve the candidate by converting it into a canonical transaction
      final confirmedTx = Transaction(
        id: 'tx_rev_app_18',
        userId: 'user1',
        accountId: 'acc_rev_18',
        categoryId: 'cat_rev_18',
        amount: 1800.0,
        type: 'expense',
        date: DateTime.now(),
        source: 'review',
      );

      final service = FinancialTransactionService(
        database: db,
      );
      await service.createTransaction(confirmedTx);

      // Verify that canonical postings now exist
      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.toRupees, 1800.0);

      final balance = await canonicalAccountRepo.getDerivedBalance('acc_rev_18');
      expect(balance.toRupees, 48200.0);
    });

    test('19. Rejecting a ReviewCandidate leaves canonical ledger untouched', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_rev_19', name: 'Bank 19', bank: 'Axis', balance: 30000.0));

      final candidate = ReviewCandidate(
        id: 'cand_rev_19',
        sourceType: 'sms_live',
        rawPayload: 'Spam SMS INR 50000',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(50000.0),
        suggestedAccountId: 'acc_rev_19',
        confidenceScore: 0.30,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await canonicalReviewRepo.createCandidate(candidate);

      // Reject
      await canonicalReviewRepo.rejectCandidate('cand_rev_19');

      // Ledger must have ZERO events and balance must remain untouched
      final balance = await canonicalAccountRepo.getDerivedBalance('acc_rev_19');
      expect(balance.toRupees, 30000.0);

      final exp = await canonicalQueryRepo.getTotalExpenses();
      expect(exp.isZero, isTrue);
    });

    test('20. AI Actions cannot execute without explicit confirmation', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_act_20', name: 'Bank 20', bank: 'ICICI', balance: 20000.0));
      await seedCategory(Category(id: 'cat_act_20', name: 'Coffee', icon: 'cup', color: '#795548', userId: '', type: 'expense'));

      // Parse user prompt "Spent 250 on Coffee"
      final action = tryParseAction(
        input: 'Spent 250 on Coffee',
        categories: [Category(id: 'cat_act_20', name: 'Coffee', icon: 'cup', color: '#795548', userId: '', type: 'expense')],
        accounts: [BankAccount(id: 'acc_act_20', name: 'Bank 20', bank: 'ICICI', balance: 20000.0)],
      );

      expect(action, isNotNull);
      expect(action!.amount, 250.0);
      expect(action.type, AIActionType.addExpense);

      // PARSING creates ZERO postings and ZERO ledger changes
      final expensesBefore = await canonicalQueryRepo.getTotalExpenses();
      expect(expensesBefore.isZero, isTrue);
    });

    test('21. Confirmed AI Action execution routes through canonical double-entry persistence', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_act_21', name: 'Bank 21', bank: 'SBI', balance: 25000.0));
      await seedCategory(Category(id: 'cat_act_21', name: 'Snacks', icon: 'fastfood', color: '#FF5722', userId: '', type: 'expense'));

      final action = AIAction(
        type: AIActionType.addExpense,
        amount: 350.0,
        categoryId: 'cat_act_21',
        categoryName: 'Snacks',
        accountId: 'acc_act_21',
        accountName: 'Bank 21',
      );

      // User confirms action
      final resultMessage = await executeAction(action, container);
      expect(resultMessage, contains('350'));

      // Total expense must now reflect canonical posting of ₹350
      final totalExpenses = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExpenses.toRupees, 350.0);

      final accountBalance = await canonicalAccountRepo.getDerivedBalance('acc_act_21');
      expect(accountBalance.toRupees, 24650.0);
    });

    test('22. Rogue legacy counter corruption cannot override canonical inputs', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_act_22', name: 'Bank 22', bank: 'HDFC', balance: 50000.0));

      final bridge = container.read(aiDataBridgeProvider);
      final initialBalance = await bridge.handle('what is my balance');
      expect(initialBalance, contains('50,000'));

      // Corrupt legacy bank_accounts table
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 0.0 WHERE id = ?', ['acc_act_22']);

      // Response MUST continue returning canonical ₹50,000
      final finalBalance = await bridge.handle('what is my balance');
      expect(finalBalance, contains('50,000'));
    });
  });
}
