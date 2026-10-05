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
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/features/ai/ai_data_bridge.dart';
import 'package:spend_x/features/automation/automation_providers.dart';
import 'package:spend_x/features/transactions/providers/transaction_providers.dart';
import 'package:spend_x/features/categories/providers/category_providers.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/category.dart';
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

  group('Milestone C4-7: Final Canonical Read Firewall & Exhaustive Audit Suite', () {
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
    late CanonicalEarmarkRepository canonicalEarmarkRepo;
    late ProviderContainer container;

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
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      goalRepo = GoalRepo(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      canonicalReviewRepo = CanonicalReviewRepository(executor: db);
      canonicalEarmarkRepo = CanonicalEarmarkRepository(executor: db);
      budgetRepo = BudgetRepo(executor: db, queryRepo: canonicalQueryRepo);

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
    // SECTION 1: ROGUE LEGACY MUTATION RESISTANCE (Invariants 1 - 7)
    // =========================================================================

    test('1. Rogue legacy bank_accounts.balance mutation has ZERO financial effect', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_fw_1',
        name: 'HDFC Savings',
        bank: 'HDFC',
        balance: 50000.0,
      ));

      // Direct SQL corruption of legacy balance column
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 999999.0 WHERE id = ?', ['acc_fw_1']);

      // 1. AccountRepo derived balance must remain 50,000.0
      final account = await accountRepo.getById('acc_fw_1');
      expect(account, isNotNull);
      expect(account!.balance, 50000.0);

      // 2. Canonical query repo net worth must remain 50,000.0
      final netWorth = await canonicalQueryRepo.getNetWorth();
      expect(netWorth.toRupees, 50000.0);

      // 3. Provider must report 50,000.0
      final providerNetWorth = await container.read(app_data.netWorthSummaryProvider.future);
      expect(providerNetWorth.netWorth, 50000.0);
    });

    test('2. Rogue legacy credit_cards.used_amount mutation has ZERO financial effect', () async {
      final card = CreditCard(
        id: 'card_fw_2',
        name: 'SBI Card',
        bank: 'SBI',
        last4: '4321',
        limitAmount: 100000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      // Post canonical purchase of 15,000.0
      final now = DateTime.now();
      await seedCategory(Category(id: 'cat_fw_2', name: 'Shopping', icon: 'cart', color: '#E91E63', userId: '', type: 'expense'));
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_card_fw_2',
          canonicalType: CanonicalEventType.cardPurchase,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_fw_2_1',
            economicEventId: 'evt_card_fw_2',
            accountId: 'cat_fw_2',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(15000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_fw_2_2',
            economicEventId: 'evt_card_fw_2',
            accountId: 'card_fw_2',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(15000.0),
            createdAt: now,
          ),
        ],
      );

      // Rogue update of legacy used_amount column
      await db.rawUpdate('UPDATE ${Tables.creditCards} SET used_amount = 0.0 WHERE id = ?', ['card_fw_2']);

      // Derived liability must remain 15,000.0
      final derivedCards = await creditRepo.getAll();
      final derivedCard = derivedCards.firstWhere((c) => c.id == 'card_fw_2');
      expect(derivedCard.usedAmount, 15000.0);

      final totalLiability = await canonicalAccountRepo.getDerivedBalance('card_fw_2');
      expect(totalLiability.toRupees, 15000.0);
    });

    test('3. Rogue legacy loans.paid_amount mutation has ZERO financial effect', () async {
      final loan = Loan(
        id: 'loan_fw_3',
        name: 'Car Loan',
        bank: 'HDFC',
        total: 300000.0,
        interestRate: 9.0,
        tenureMonths: 36,
        monthlyInstallment: 9540.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 10,
      );
      await loanRepo.insertLoan(loan);

      // Corrupt legacy paid_amount
      await db.rawUpdate('UPDATE ${Tables.loans} SET paid_amount = 299999.0 WHERE id = ?', ['loan_fw_3']);

      // Outstanding liability must remain 300,000.0
      final derivedLoan = await loanRepo.getLoanById('loan_fw_3');
      expect(derivedLoan, isNotNull);
      expect(derivedLoan!.paidAmount, 0.0);

      final liability = await loanRepo.getDerivedBalance('loan_fw_3');
      expect(liability.toRupees, 300000.0);
    });

    test('4. Rogue legacy goals.current_amount mutation has ZERO financial effect', () async {
      final now = DateTime.now();
      final goal = Goal(
        id: 'goal_fw_4',
        title: 'Europe Trip',
        type: GoalType.savings,
        targetAmount: 200000.0,
        currentAmount: 0.0,
        startDate: now,
        endDate: now.add(const Duration(days: 365)),
      );
      await goalRepo.insert(goal);

      // Corrupt legacy current_amount column
      await db.rawUpdate('UPDATE ${Tables.goals} SET current_amount = 180000.0 WHERE id = ?', ['goal_fw_4']);

      // Derived goal progress must remain 0.0 (since no active earmarks exist)
      final progress = await goalRepo.getDerivedProgress('goal_fw_4');
      expect(progress, 0.0);

      final derivedGoal = (await goalRepo.getAll()).firstWhere((g) => g.id == 'goal_fw_4');
      expect(derivedGoal.currentAmount, 0.0);
    });

    test('5. Rogue legacy transactions insertion has ZERO financial effect', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_fw_5',
        name: 'Salary Bank',
        bank: 'ICICI',
        balance: 100000.0,
      ));
      await seedCategory(Category(id: 'cat_fw_5', name: 'Food', icon: 'food', color: '#FF9800', userId: '', type: 'expense'));

      // Direct SQL insertion into legacy transactions table
      final now = DateTime.now();
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['rogue_tx_5', 'acc_fw_5', 'cat_fw_5', 45000.0, 'expense', now.toIso8601String(), 0, now.toIso8601String(), now.toIso8601String()],
      );

      // Total expense must remain 0.0
      final totalExpenses = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExpenses.isZero, isTrue);

      // Account balance must remain 100,000.0
      final balance = await canonicalAccountRepo.getDerivedBalance('acc_fw_5');
      expect(balance.toRupees, 100000.0);
    });

    test('6. Rogue legacy ledger_transactions insertion has ZERO financial effect', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_fw_6',
        name: 'Investment Bank',
        bank: 'Kotak',
        balance: 60000.0,
      ));

      // Direct SQL insertion into legacy ledger_transactions
      final now = DateTime.now();
      await db.insert(Tables.ledgerTransactions, {
        'id': 'rogue_ledger_6',
        'account_id': 'acc_fw_6',
        'amount': 25000.0,
        'type': 'expense',
        'date': now.toIso8601String(),
        'created_at': now.toIso8601String(),
      });

      // Net worth and balance must be completely immune
      final balance = await canonicalAccountRepo.getDerivedBalance('acc_fw_6');
      expect(balance.toRupees, 60000.0);

      final nw = await canonicalQueryRepo.getNetWorth();
      expect(nw.toRupees, 60000.0);
    });

    test('7. Rogue legacy credit_transactions insertion has ZERO financial effect', () async {
      final card = CreditCard(
        id: 'card_fw_7',
        name: 'Amazon ICICI',
        bank: 'ICICI',
        last4: '9999',
        limitAmount: 80000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      // Direct SQL insertion into legacy credit_transactions
      await db.insert(Tables.creditTransactions, {
        'id': 'rogue_credit_tx_7',
        'cardId': 'card_fw_7',
        'amount': 30000.0,
        'type': 'purchase',
        'category': 'General',
        'status': 'settled',
        'date': DateTime.now().toIso8601String(),
      });

      // Canonical liability must remain 0.0
      final liability = await canonicalAccountRepo.getDerivedBalance('card_fw_7');
      expect(liability.isZero, isTrue);
    });

    // =========================================================================
    // SECTION 2: CANONICAL ACCOUNTING PROPAGATION (Invariants 8 - 12)
    // =========================================================================

    test('8. Canonical posting changes propagate correctly to derived reads', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_fw_8',
        name: 'Axis Bank',
        bank: 'Axis',
        balance: 70000.0,
      ));
      await seedCategory(Category(id: 'cat_fw_8', name: 'Rent', icon: 'home', color: '#795548', userId: '', type: 'expense'));

      await transactionRepo.insert(Transaction(
        id: 'tx_fw_8',
        userId: 'user1',
        accountId: 'acc_fw_8',
        categoryId: 'cat_fw_8',
        amount: 20000.0,
        type: 'expense',
        date: DateTime.now(),
      ));

      final balance = await canonicalAccountRepo.getDerivedBalance('acc_fw_8');
      expect(balance.toRupees, 50000.0);

      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.toRupees, 20000.0);
    });

    test('9. Canonical reversal changes propagate correctly netting out to zero', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_fw_9',
        name: 'SBI Account',
        bank: 'SBI',
        balance: 40000.0,
      ));
      await seedCategory(Category(id: 'cat_fw_9', name: 'Bills', icon: 'receipt', color: '#607D8B', userId: '', type: 'expense'));

      final tx = Transaction(
        id: 'tx_fw_9',
        userId: 'user1',
        accountId: 'acc_fw_9',
        categoryId: 'cat_fw_9',
        amount: 5000.0,
        type: 'expense',
        date: DateTime.now(),
      );
      await transactionRepo.insert(tx);

      // Now reverse / delete the transaction
      await transactionRepo.delete('tx_fw_9');

      // Total expenses must net back to 0.0
      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.isZero, isTrue);

      // Balance must revert to 40,000.0
      final balance = await canonicalAccountRepo.getDerivedBalance('acc_fw_9');
      expect(balance.toRupees, 40000.0);
    });

    test('10. Canonical refund changes propagate correctly as contra-expense', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_10', name: 'Bank 10', bank: 'SBI', balance: 50000.0));
      await seedCategory(Category(id: 'cat_fw_10', name: 'Shopping', icon: 'cart', color: '#9C27B0', userId: '', type: 'expense'));

      final now = DateTime.now();
      // Purchase 6,000.0
      await transactionRepo.insert(Transaction(
        id: 'tx_fw_pur_10',
        userId: 'user1',
        accountId: 'acc_fw_10',
        categoryId: 'cat_fw_10',
        amount: 6000.0,
        type: 'expense',
        date: now,
      ));

      // Canonical refund 2,000.0
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_fw_ref_10',
          canonicalType: CanonicalEventType.refund,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_fw_ref_1',
            economicEventId: 'evt_fw_ref_10',
            accountId: 'acc_fw_10',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(2000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_fw_ref_2',
            economicEventId: 'evt_fw_ref_10',
            accountId: 'cat_fw_10',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(2000.0),
            createdAt: now,
          ),
        ],
      );

      // Net expense must be exactly 4,000.0 (NOT 6,000, NOT 8,000)
      final netExp = await canonicalQueryRepo.getTotalExpenses();
      expect(netExp.toRupees, 4000.0);

      // Income must remain 0.0
      final income = await canonicalQueryRepo.getTotalIncome();
      expect(income.isZero, isTrue);
    });

    test('11. Canonical card purchase/payment semantics remain correct (Zero double counting)', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_11', name: 'HDFC Pay', bank: 'HDFC', balance: 80000.0));
      final card = CreditCard(id: 'card_fw_11', name: 'Infinia', bank: 'HDFC', last4: '8888', limitAmount: 200000.0, usedAmount: 0.0);
      await creditRepo.insert(card);
      await seedCategory(Category(id: 'cat_fw_11', name: 'Dining', icon: 'food', color: '#FF5722', userId: '', type: 'expense'));

      final now = DateTime.now();
      // 1. Card Purchase 12,000.0
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_fw_cp_11',
          canonicalType: CanonicalEventType.cardPurchase,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(id: 'pst_cp_1', economicEventId: 'evt_fw_cp_11', accountId: 'cat_fw_11', direction: PostingDirection.debit, amount: Money.fromRupees(12000.0), createdAt: now),
          Posting(id: 'pst_cp_2', economicEventId: 'evt_fw_cp_11', accountId: 'card_fw_11', direction: PostingDirection.credit, amount: Money.fromRupees(12000.0), createdAt: now),
        ],
      );

      // 2. Card Payment 12,000.0 (Asset -> Liability settlement)
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_fw_pay_11',
          canonicalType: CanonicalEventType.cardPayment,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(id: 'pst_pay_1', economicEventId: 'evt_fw_pay_11', accountId: 'card_fw_11', direction: PostingDirection.debit, amount: Money.fromRupees(12000.0), createdAt: now),
          Posting(id: 'pst_pay_2', economicEventId: 'evt_fw_pay_11', accountId: 'acc_fw_11', direction: PostingDirection.credit, amount: Money.fromRupees(12000.0), createdAt: now),
        ],
      );

      // Card liability must be 0.0
      final liability = await canonicalAccountRepo.getDerivedBalance('card_fw_11');
      expect(liability.isZero, isTrue);

      // Total expense must be 12,000.0 (payment is NOT an expense)
      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.toRupees, 12000.0);

      // Bank account balance must be 68,000.0
      final balance = await canonicalAccountRepo.getDerivedBalance('acc_fw_11');
      expect(balance.toRupees, 68000.0);
    });

    test('12. Canonical loan disbursement/repayment/interest semantics remain correct', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_12', name: 'ICICI Loan Acc', bank: 'ICICI', balance: 50000.0));
      await seedCategory(Category(id: 'cat_fw_int_12', name: 'Loan Interest', icon: 'percent', color: '#795548', userId: '', type: 'expense'));

      final loan = Loan(
        id: 'loan_fw_12',
        name: 'Home Renovation',
        bank: 'ICICI',
        total: 100000.0,
        interestRate: 8.5,
        tenureMonths: 12,
        monthlyInstallment: 8768.0,
        startDate: DateTime.now(),
        paidAmount: 0.0,
        loanStatus: 'active',
        dueDay: 10,
      );
      await loanRepo.insertLoan(loan);

      // 3-leg balanced EMI event:
      // Dr Loan Liability: 10,000 (Principal component)
      // Dr sys_exp_interest: 2,000 (Interest component)
      // Cr Bank Asset: 12,000 (Total EMI cash outflow)
      final now = DateTime.now();
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_emi_12',
          canonicalType: CanonicalEventType.loanRepayment,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_emi_12_1',
            economicEventId: 'evt_emi_12',
            accountId: 'loan_fw_12',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(10000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_emi_12_2',
            economicEventId: 'evt_emi_12',
            accountId: TablesV24.sysExpInterest,
            direction: PostingDirection.debit,
            amount: Money.fromRupees(2000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_emi_12_3',
            economicEventId: 'evt_emi_12',
            accountId: 'acc_fw_12',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(12000.0),
            createdAt: now,
          ),
        ],
      );

      // 1. Outstanding liability reduced to 90,000.0
      final outstanding = await loanRepo.getDerivedBalance('loan_fw_12');
      expect(outstanding.toRupees, 90000.0);

      // 2. Total expenses must only include the interest portion (2,000.0)
      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.toRupees, 2000.0);

      // 3. Bank balance reduced by combined payment (12,000.0)
      final balance = await canonicalAccountRepo.getDerivedBalance('acc_fw_12');
      expect(balance.toRupees, 38000.0);
    });

    // =========================================================================
    // SECTION 3: EARMARK & REVIEW ISOLATION (Invariants 13 - 15)
    // =========================================================================

    test('13. Canonical goal earmarks affect Safe-to-Spend but not Net Worth', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_13', name: 'Savings 13', bank: 'SBI', balance: 100000.0));
      final now = DateTime.now();
      final goal = Goal(
        id: 'goal_fw_13',
        title: 'Emergency Reserve',
        type: GoalType.savings,
        targetAmount: 50000.0,
        currentAmount: 0.0,
        startDate: now,
        endDate: now.add(const Duration(days: 365)),
      );
      await goalRepo.insert(goal);

      final nwBefore = await canonicalQueryRepo.getNetWorth();
      final stsBefore = (await canonicalQueryRepo.getSafeToSpend()).discretionaryCash;

      // Create earmark of 30,000.0
      await canonicalEarmarkRepo.createEarmark(AssetEarmark(
        id: 'em_fw_13',
        goalId: 'goal_fw_13',
        assetAccountId: 'acc_fw_13',
        earmarkedAmount: Money.fromRupees(30000.0),
        createdAt: now,
        updatedAt: now,
      ));

      final nwAfter = await canonicalQueryRepo.getNetWorth();
      final stsAfter = (await canonicalQueryRepo.getSafeToSpend()).discretionaryCash;

      // Net worth is UNCHANGED
      expect(nwAfter.toRupees, nwBefore.toRupees);
      // Safe-to-Spend is REDUCED by 30,000.0
      expect(stsAfter.toRupees, stsBefore.toRupees - 30000.0);
    });

    test('14. Pending review candidates have ZERO accounting effect', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_14', name: 'Bank 14', bank: 'Axis', balance: 50000.0));

      final candidate = ReviewCandidate(
        id: 'cand_fw_14',
        sourceType: 'sms',
        rawPayload: 'Debit INR 25000',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(25000.0),
        suggestedAccountId: 'acc_fw_14',
        confidenceScore: 0.9,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await canonicalReviewRepo.createCandidate(candidate);

      // Verify ZERO postings created
      final postings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: ['cand_fw_14']);
      expect(postings, isEmpty);

      // Verify Net worth is untouched
      final nw = await canonicalQueryRepo.getNetWorth();
      expect(nw.toRupees, 50000.0);
    });

    test('15. Rejected review candidates have ZERO accounting effect', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_15', name: 'Bank 15', bank: 'HDFC', balance: 35000.0));

      final candidate = ReviewCandidate(
        id: 'cand_fw_15',
        sourceType: 'ocr',
        rawPayload: 'Spam Receipt INR 10000',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(10000.0),
        suggestedAccountId: 'acc_fw_15',
        confidenceScore: 0.4,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await canonicalReviewRepo.createCandidate(candidate);
      await canonicalReviewRepo.rejectCandidate('cand_fw_15');

      final balance = await canonicalAccountRepo.getDerivedBalance('acc_fw_15');
      expect(balance.toRupees, 35000.0);

      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.isZero, isTrue);
    });

    // =========================================================================
    // SECTION 4: AI & AUTOMATION BOUNDARY (Invariants 16 - 17)
    // =========================================================================

    test('16. AI context ignores legacy mutations and derives strictly from canonical state', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_16', name: 'AI Bank', bank: 'SBI', balance: 40000.0));

      final bridge = container.read(aiDataBridgeProvider);
      final initialBalance = await bridge.handle('what is my balance');
      expect(initialBalance, contains('40,000'));

      // Rogue corruption of legacy balance column
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 0.0 WHERE id = ?', ['acc_fw_16']);

      final finalBalance = await bridge.handle('what is my balance');
      expect(finalBalance, contains('40,000'));
    });

    test('17. Automation decisions ignore legacy mutations and consume canonical state', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_17', name: 'Main Checking', bank: 'ICICI', balance: 80000.0));

      final decision = await container.read(dailyDecisionProvider.future);
      expect(decision, isNotNull);
      expect(decision.message.isNotEmpty, isTrue);

      // Corrupt legacy column
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 0.0 WHERE id = ?', ['acc_fw_17']);

      final decisionAfter = await container.read(dailyDecisionProvider.future);
      expect(decisionAfter, isNotNull);
      expect(decisionAfter.message, decision.message);
    });

    // =========================================================================
    // SECTION 5: FALLBACK, CACHE & MIXED-SOURCE PURITY (Invariants 18 - 20)
    // =========================================================================

    test('18. No provider silently falls back to legacy financial truth', () async {
      // Create empty database without any transactions or accounts
      final nw = await container.read(app_data.netWorthSummaryProvider.future);
      expect(nw.netWorth, 0.0);
      expect(nw.assets, 0.0);
      expect(nw.liabilities, 0.0);

      final sts = await container.read(app_data.safeToSpendProvider.future);
      expect(sts.discretionaryCash.isZero, isTrue);

      // Inserting rogue legacy transactions must NOT trigger a fallback
      await db.insert(Tables.transactions, {
        'id': 'rogue_empty_fallback',
        'account_id': 'none',
        'amount': 99999.0,
        'type': 'income',
        'date': DateTime.now().toIso8601String(),
        'is_deleted': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // Still zero, strictly immune
      final nwCheck = await container.read(app_data.netWorthSummaryProvider.future);
      expect(nwCheck.netWorth, 0.0);
    });

    test('19. No cached financial metric overrides canonical truth', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_19', name: 'Cache Bank', bank: 'HDFC', balance: 60000.0));

      // Initial read
      final initialNw = await container.read(app_data.netWorthSummaryProvider.future);
      expect(initialNw.netWorth, 60000.0);

      // Post an authentic canonical expense
      await seedCategory(Category(id: 'cat_fw_19', name: 'Tech', icon: 'laptop', color: '#2196F3', userId: '', type: 'expense'));
      await transactionRepo.insert(Transaction(
        id: 'tx_fw_19',
        userId: 'user1',
        accountId: 'acc_fw_19',
        categoryId: 'cat_fw_19',
        amount: 15000.0,
        type: 'expense',
        date: DateTime.now(),
      ));

      // Invalidate and refresh
      container.invalidate(app_data.netWorthSummaryProvider);
      final refreshedNw = await container.read(app_data.netWorthSummaryProvider.future);
      expect(refreshedNw.netWorth, 45000.0);
    });

    test('20. No mixed canonical/legacy financial calculation exists', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_fw_20', name: 'Purity Bank', bank: 'SBI', balance: 100000.0));

      // Corrupt legacy bank_accounts table with huge number
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 500000.0 WHERE id = ?', ['acc_fw_20']);

      // Calculate Safe-to-Spend
      final sts = await canonicalQueryRepo.getSafeToSpend();
      // Must be 100,000.0, proving legacy balance is NOT added to or blended with canonical balance
      expect(sts.liquidAssets.toRupees, 100000.0);
      expect(sts.discretionaryCash.toRupees, 100000.0);
    });
  });
}
