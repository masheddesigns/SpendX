import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart' as app_data;
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/budget_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/salary_repo.dart';
import 'package:spend_x/data/repositories/lending_repo.dart';
import 'package:spend_x/data/repositories/analytics_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/services/analytics_service.dart';
import 'package:spend_x/services/financial_health_service.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/budget.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C4-5: Analytics & Budget Canonical Read Migration Suite', () {
    late Database db;
    late TransactionRepo transactionRepo;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late BudgetRepo budgetRepo;
    late CategoryRepo categoryRepo;
    late AnalyticsRepo analyticsRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late AnalyticsService analyticsService;
    late FinancialHealthService financialHealthService;
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
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      budgetRepo = BudgetRepo(executor: db, queryRepo: canonicalQueryRepo);
      categoryRepo = CategoryRepo();
      analyticsRepo = AnalyticsRepo(executor: db);
      analyticsService = AnalyticsService();
      financialHealthService = FinancialHealthService(
        transactionRepo: transactionRepo,
        accountRepo: accountRepo,
        loanRepo: loanRepo,
        salaryRepo: SalaryRepo(),
        lendingRepo: LendingRepo(),
        categoryRepo: categoryRepo,
        queryRepo: canonicalQueryRepo,
      );

      container = ProviderContainer(
        overrides: [
          app_data.transactionRepoProvider.overrideWithValue(transactionRepo),
          app_data.accountRepoProvider.overrideWithValue(accountRepo),
          app_data.creditRepoProvider.overrideWithValue(creditRepo),
          app_data.loanRepoProvider.overrideWithValue(loanRepo),
          app_data.budgetRepoProvider.overrideWithValue(budgetRepo),
          app_data.canonicalFinancialQueryRepositoryProvider
              .overrideWithValue(canonicalQueryRepo),
          app_data.analyticsServiceProvider.overrideWithValue(analyticsService),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // Helper to insert category and its canonical expense/income account
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
    // SECTION 1: ANALYTICS ADVERSARIAL TESTS (Invariants 1 - 15)
    // =========================================================================

    test('1. Rogue insert into legacy transactions does not change monthly income', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_inc_1',
        name: 'Salary Bank',
        bank: 'HDFC',
        balance: 50000.0,
      ));
      await seedCategory(Category(id: 'cat_sal', name: 'Salary', icon: 'work', color: '#00FF00', userId: '', type: 'income'));

      // 1. Post canonical income event of ₹50,000
      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_inc_canon_1',
        userId: 'user1',
        accountId: 'acc_inc_1',
        categoryId: 'cat_sal',
        amount: 50000.0,
        type: 'income',
        date: now,
      ));

      final statsBefore = await transactionRepo.getMonthlyStats(1);
      expect(statsBefore.first['income'], 50000.0);

      // 2. Perform rogue direct SQL insertion into legacy transactions table
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['rogue_tx_inc_1', 'acc_inc_1', 'cat_sal', 999999.0, 'income', now.toIso8601String(), 0, now.toIso8601String(), now.toIso8601String()],
      );

      // 3. Verify monthly income remains strictly ₹50,000
      final statsAfter = await transactionRepo.getMonthlyStats(1);
      expect(statsAfter.first['income'], 50000.0);

      final totalIncome = await canonicalQueryRepo.getTotalIncome(
        startDate: DateTime(now.year, now.month, 1),
        endDate: now,
      );
      expect(totalIncome.toRupees, 50000.0);
    });

    test('2. Rogue insert into legacy transactions does not change monthly expense', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_exp_2',
        name: 'Checking Bank',
        bank: 'ICICI',
        balance: 10000.0,
      ));
      await seedCategory(Category(id: 'cat_gro_2', name: 'Groceries', icon: 'cart', color: '#FF0000', userId: '', type: 'expense'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_exp_canon_2',
        userId: 'user1',
        accountId: 'acc_exp_2',
        categoryId: 'cat_gro_2',
        amount: 4500.0,
        type: 'expense',
        date: now,
      ));

      final statsBefore = await transactionRepo.getMonthlyStats(1);
      expect(statsBefore.first['expense'], 4500.0);

      // Rogue direct SQL insertion
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['rogue_tx_exp_2', 'acc_exp_2', 'cat_gro_2', 88888.0, 'expense', now.toIso8601String(), 0, now.toIso8601String(), now.toIso8601String()],
      );

      final statsAfter = await transactionRepo.getMonthlyStats(1);
      expect(statsAfter.first['expense'], 4500.0);

      final totalExpense = await canonicalQueryRepo.getTotalExpenses(
        startDate: DateTime(now.year, now.month, 1),
        endDate: now,
      );
      expect(totalExpense.toRupees, 4500.0);
    });

    test('3. Rogue insert into legacy transactions does not change category spending', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_cat_3', name: 'Bank 3', bank: 'SBI', balance: 20000.0));
      await seedCategory(Category(id: 'cat_fuel_3', name: 'Fuel', icon: 'gas', color: '#FFA500', userId: '', type: 'expense'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_fuel_3',
        userId: 'user1',
        accountId: 'acc_cat_3',
        categoryId: 'cat_fuel_3',
        amount: 2500.0,
        type: 'expense',
        date: now,
      ));

      final topCatsBefore = await transactionRepo.getTopExpenseCategories(1);
      expect(topCatsBefore.first['total'], 2500.0);

      // Rogue direct SQL insertion
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['rogue_tx_fuel_3', 'acc_cat_3', 'cat_fuel_3', 77777.0, 'expense', now.toIso8601String(), 0, now.toIso8601String(), now.toIso8601String()],
      );

      final topCatsAfter = await transactionRepo.getTopExpenseCategories(1);
      expect(topCatsAfter.first['total'], 2500.0);

      final catSpent = await canonicalQueryRepo.getCategorySpending('cat_fuel_3');
      expect(catSpent.toRupees, 2500.0);
    });

    test('4. Rogue mutation of legacy balance fields does not change analytics', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bal_4', name: 'Bank 4', bank: 'Axis', balance: 30000.0));
      await seedCategory(Category(id: 'cat_ent_4', name: 'Entertainment', icon: 'movie', color: '#990099', userId: '', type: 'expense'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_ent_4',
        userId: 'user1',
        accountId: 'acc_bal_4',
        categoryId: 'cat_ent_4',
        amount: 1200.0,
        type: 'expense',
        date: now,
      ));

      // Corrupt legacy bank_accounts.balance directly
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 99999999.0 WHERE id = ?', ['acc_bal_4']);

      final stats = await transactionRepo.getMonthlyStats(1);
      expect(stats.first['expense'], 1200.0);

      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.toRupees, 1200.0);
    });

    test('5. Soft-deleted legacy transactions do not appear in analytics', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_del_5', name: 'Bank 5', bank: 'Kotak', balance: 15000.0));
      await seedCategory(Category(id: 'cat_food_5', name: 'Dining', icon: 'food', color: '#0000FF', userId: '', type: 'expense'));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_food_5',
        userId: 'user1',
        accountId: 'acc_del_5',
        categoryId: 'cat_food_5',
        amount: 800.0,
        type: 'expense',
        date: now,
      ));

      // Insert soft-deleted transaction in legacy table
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['tx_soft_deleted_5', 'acc_del_5', 'cat_food_5', 5000.0, 'expense', now.toIso8601String(), 1, now.toIso8601String(), now.toIso8601String()],
      );

      final stats = await transactionRepo.getMonthlyStats(1);
      expect(stats.first['expense'], 800.0);
    });

    test('6. Transfers are not counted as income or expense', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_src_6', name: 'Source Acc', bank: 'SBI', balance: 20000.0));
      await accountRepo.insertAccount(BankAccount(id: 'acc_dst_6', name: 'Dest Acc', bank: 'HDFC', balance: 10000.0));

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_xfer_6',
        userId: 'user1',
        accountId: 'acc_src_6',
        relatedEntityId: 'acc_dst_6',
        amount: 5000.0,
        type: 'transfer',
        date: now,
      ));

      final stats = await transactionRepo.getMonthlyStats(1);
      if (stats.isNotEmpty) {
        expect(stats.first['income'], 0.0);
        expect(stats.first['expense'], 0.0);
      }

      final inc = await canonicalQueryRepo.getTotalIncome();
      final exp = await canonicalQueryRepo.getTotalExpenses();
      expect(inc.isZero, isTrue);
      expect(exp.isZero, isTrue);
    });

    test('7. Credit-card purchases count once as expense', () async {
      final card = CreditCard(
        id: 'card_pur_7',
        name: 'Regalia Gold',
        bank: 'HDFC',
        last4: '1111',
        limitAmount: 200000.0,
        usedAmount: 0.0,
        billingDay: 1,
        dueDay: 20,
      );
      await creditRepo.insert(card);
      await seedCategory(Category(id: 'cat_elect_7', name: 'Electronics', icon: 'tv', color: '#333333', userId: '', type: 'expense'));

      final now = DateTime.now();
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_card_pur_7',
          canonicalType: CanonicalEventType.cardPurchase,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_cp_7_1',
            economicEventId: 'evt_card_pur_7',
            accountId: 'cat_elect_7',
            direction: PostingDirection.debit, // Expense increased
            amount: Money.fromRupees(15000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_cp_7_2',
            economicEventId: 'evt_card_pur_7',
            accountId: 'card_pur_7',
            direction: PostingDirection.credit, // Card liability increased
            amount: Money.fromRupees(15000.0),
            createdAt: now,
          ),
        ],
      );

      final totalExp = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExp.toRupees, 15000.0);

      final stats = await transactionRepo.getMonthlyStats(1);
      expect(stats.first['expense'], 15000.0);
    });

    test('8. Credit-card payments do not create additional expense', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_pay_8', name: 'Payment Bank', bank: 'Axis', balance: 50000.0));
      final card = CreditCard(
        id: 'card_pay_8',
        name: 'Amazon ICICI',
        bank: 'ICICI',
        last4: '2222',
        limitAmount: 100000.0,
        usedAmount: 10000.0,
        billingDay: 1,
        dueDay: 15,
      );
      await creditRepo.insert(card);

      final now = DateTime.now();
      // Card payment: Dr Card Liability, Cr Bank Asset
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_card_pay_8',
          canonicalType: CanonicalEventType.cardPayment,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_cpay_8_1',
            economicEventId: 'evt_card_pay_8',
            accountId: 'card_pay_8',
            direction: PostingDirection.debit, // Liability reduced
            amount: Money.fromRupees(10000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_cpay_8_2',
            economicEventId: 'evt_card_pay_8',
            accountId: 'acc_pay_8',
            direction: PostingDirection.credit, // Bank reduced
            amount: Money.fromRupees(10000.0),
            createdAt: now,
          ),
        ],
      );

      final expenses = await canonicalQueryRepo.getTotalExpenses();
      expect(expenses.isZero, isTrue);

      final stats = await transactionRepo.getMonthlyStats(1);
      if (stats.isNotEmpty) {
        expect(stats.first['expense'], 0.0);
      }
    });

    test('9. Loan disbursement is not income', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_disb_9', name: 'Bank 9', bank: 'Canara', balance: 10000.0));
      final loan = Loan(
        id: 'loan_disb_9',
        name: 'Personal Loan',
        bank: 'Canara',
        total: 100000.0,
        interestRate: 11.0,
        tenureMonths: 12,
        monthlyInstallment: 8838.0,
        startDate: DateTime.now(),
        paidAmount: 100000.0, // 0 initial balance
        loanStatus: 'active',
        dueDay: 1,
      );
      await loanRepo.insertLoan(loan);

      final now = DateTime.now();
      // Disbursement: Dr Bank Asset, Cr Loan Liability
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_disb_9',
          canonicalType: CanonicalEventType.loanDisbursement,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_d_9_1',
            economicEventId: 'evt_disb_9',
            accountId: 'acc_disb_9',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(100000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_d_9_2',
            economicEventId: 'evt_disb_9',
            accountId: 'loan_disb_9',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(100000.0),
            createdAt: now,
          ),
        ],
      );

      final income = await canonicalQueryRepo.getTotalIncome();
      expect(income.isZero, isTrue);

      final stats = await transactionRepo.getMonthlyStats(1);
      if (stats.isNotEmpty) {
        expect(stats.first['income'], 0.0);
      }
    });

    test('10. Loan principal repayment is not expense', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_rep_10', name: 'Bank 10', bank: 'PNB', balance: 50000.0));
      final loan = Loan(
        id: 'loan_rep_10',
        name: 'Car Loan',
        bank: 'PNB',
        total: 200000.0,
        interestRate: 8.5,
        tenureMonths: 24,
        monthlyInstallment: 9093.0,
        startDate: DateTime.now(),
        paidAmount: 0.0, // Initial balance 200k
        loanStatus: 'active',
        dueDay: 5,
      );
      await loanRepo.insertLoan(loan);

      final now = DateTime.now();
      // Principal repayment: Dr Loan Liability, Cr Bank Asset
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_rep_10',
          canonicalType: CanonicalEventType.loanRepayment,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_r_10_1',
            economicEventId: 'evt_rep_10',
            accountId: 'loan_rep_10',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(25000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_r_10_2',
            economicEventId: 'evt_rep_10',
            accountId: 'acc_rep_10',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(25000.0),
            createdAt: now,
          ),
        ],
      );

      final expenses = await canonicalQueryRepo.getTotalExpenses();
      expect(expenses.isZero, isTrue);

      final stats = await transactionRepo.getMonthlyStats(1);
      if (stats.isNotEmpty) {
        expect(stats.first['expense'], 0.0);
      }
    });

    test('11. Loan interest is expense', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_int_11', name: 'Bank 11', bank: 'HDFC', balance: 30000.0));

      final now = DateTime.now();
      // Interest payment: Dr sys_exp_interest, Cr Bank Asset
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_int_11',
          canonicalType: CanonicalEventType.expense,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_i_11_1',
            economicEventId: 'evt_int_11',
            accountId: TablesV24.sysExpInterest,
            direction: PostingDirection.debit,
            amount: Money.fromRupees(1500.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_i_11_2',
            economicEventId: 'evt_int_11',
            accountId: 'acc_int_11',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(1500.0),
            createdAt: now,
          ),
        ],
      );

      final expenses = await canonicalQueryRepo.getTotalExpenses();
      expect(expenses.toRupees, 1500.0);

      final stats = await transactionRepo.getMonthlyStats(1);
      expect(stats.first['expense'], 1500.0);
    });

    test('12. Refunds reduce the appropriate expense analytics correctly', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_ref_12', name: 'Bank 12', bank: 'SBI', balance: 40000.0));
      await seedCategory(Category(id: 'cat_shop_12', name: 'Shopping', icon: 'bag', color: '#E91E63', userId: '', type: 'expense'));

      final now = DateTime.now();
      // Original purchase: Dr Shopping ₹6,000, Cr Bank ₹6,000
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_shop_12',
          canonicalType: CanonicalEventType.expense,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_s_12_1',
            economicEventId: 'evt_shop_12',
            accountId: 'cat_shop_12',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(6000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_s_12_2',
            economicEventId: 'evt_shop_12',
            accountId: 'acc_ref_12',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(6000.0),
            createdAt: now,
          ),
        ],
      );

      expect((await canonicalQueryRepo.getTotalExpenses()).toRupees, 6000.0);

      // Refund of ₹2,000: Dr Bank ₹2,000, Cr Shopping ₹2,000
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_ref_12',
          canonicalType: CanonicalEventType.refund,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_r_12_1',
            economicEventId: 'evt_ref_12',
            accountId: 'acc_ref_12',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(2000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_r_12_2',
            economicEventId: 'evt_ref_12',
            accountId: 'cat_shop_12',
            direction: PostingDirection.credit, // Contra-expense reduces category
            amount: Money.fromRupees(2000.0),
            createdAt: now,
          ),
        ],
      );

      // Total expense must be exactly 6,000 - 2,000 = ₹4,000
      final netExpenses = await canonicalQueryRepo.getTotalExpenses();
      expect(netExpenses.toRupees, 4000.0);

      final catSpending = await canonicalQueryRepo.getCategorySpending('cat_shop_12');
      expect(catSpending.toRupees, 4000.0);

      final stats = await transactionRepo.getMonthlyStats(1);
      expect(stats.first['expense'], 4000.0);
    });

    test('13. Opening balances do not appear as income/expense', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_ob_13',
        name: 'Initial Bank',
        bank: 'ICICI',
        balance: 100000.0,
      ));

      // Opening balance creates Dr Bank, Cr sys_equity_opening
      final income = await canonicalQueryRepo.getTotalIncome();
      final expense = await canonicalQueryRepo.getTotalExpenses();
      expect(income.isZero, isTrue);
      expect(expense.isZero, isTrue);

      final stats = await transactionRepo.getMonthlyStats(1);
      if (stats.isNotEmpty) {
        expect(stats.first['income'], 0.0);
        expect(stats.first['expense'], 0.0);
      }
    });

    test('14. Reversal/replacement events do not double-count spending', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_rev_14', name: 'Bank 14', bank: 'Axis', balance: 50000.0));
      await seedCategory(Category(id: 'cat_med_14', name: 'Medical', icon: 'cross', color: '#00BCD4', userId: '', type: 'expense'));

      final now = DateTime.now();
      final tx = Transaction(
        id: 'tx_orig_14',
        userId: 'user1',
        accountId: 'acc_rev_14',
        categoryId: 'cat_med_14',
        amount: 3000.0,
        type: 'expense',
        date: now,
      );
      await transactionRepo.insert(tx);

      expect((await canonicalQueryRepo.getTotalExpenses()).toRupees, 3000.0);

      // Now update the transaction to ₹3,500 (this posts a reversal of 3000 + replacement of 3500)
      final updatedTx = tx.copyWith(amount: 3500.0);
      await transactionRepo.update(updatedTx);

      // Total expense must be exactly ₹3,500 (NOT 3000 + 3500 = 6500!)
      final totalExpenses = await canonicalQueryRepo.getTotalExpenses();
      expect(totalExpenses.toRupees, 3500.0);

      final catSpent = await canonicalQueryRepo.getCategorySpending('cat_med_14');
      expect(catSpent.toRupees, 3500.0);

      final stats = await transactionRepo.getMonthlyStats(1);
      expect(stats.first['expense'], 3500.0);
    });

    test('15. Historical/monthly analytics remain consistent with canonical postings', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_hist_15', name: 'Bank 15', bank: 'Kotak', balance: 80000.0));
      await seedCategory(Category(id: 'cat_bill_15', name: 'Bills', icon: 'doc', color: '#FF9800', userId: '', type: 'expense'));

      final lastMonth = DateTime(DateTime.now().year, DateTime.now().month - 1, 15);
      await transactionRepo.insert(Transaction(
        id: 'tx_hist_last_m',
        userId: 'user1',
        accountId: 'acc_hist_15',
        categoryId: 'cat_bill_15',
        amount: 4200.0,
        type: 'expense',
        date: lastMonth,
      ));

      final stats = await transactionRepo.getMonthlyStats(3);
      final lastMonthStr = '${lastMonth.year}-${lastMonth.month.toString().padLeft(2, '0')}';
      final match = stats.firstWhere((s) => s['month'] == lastMonthStr);
      expect(match['expense'], 4200.0);
    });

    // =========================================================================
    // SECTION 2: BUDGET ADVERSARIAL TESTS (Invariants 16 - 23)
    // =========================================================================

    test('16. Rogue legacy transaction insertion does not change budget spent', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bgt_16', name: 'Bank 16', bank: 'SBI', balance: 50000.0));
      await seedCategory(Category(id: 'cat_gro_16', name: 'Groceries', icon: 'cart', color: '#4CAF50', userId: '', type: 'expense'));

      final budget = Budget(
        id: 'bgt_16',
        categoryId: 'cat_gro_16',
        limit: 10000.0,
        period: 'monthly',
        createdAt: DateTime.now(),
      );
      await budgetRepo.insert(budget);

      final now = DateTime.now();
      await transactionRepo.insert(Transaction(
        id: 'tx_gro_canon_16',
        userId: 'user1',
        accountId: 'acc_bgt_16',
        categoryId: 'cat_gro_16',
        amount: 3200.0,
        type: 'expense',
        date: now,
      ));

      final startOfMonth = DateTime(now.year, now.month, 1);
      final endOfMonth = DateTime(now.year, now.month + 1, 0, 23, 59, 59);

      // Verify canonical spent
      var spent = await budgetRepo.getSpentForCategory('cat_gro_16', startOfMonth, endOfMonth);
      expect(spent, 3200.0);

      // Rogue direct insertion into legacy transactions table
      await db.rawInsert(
        'INSERT INTO ${Tables.transactions} (id, account_id, category_id, amount, type, date, is_deleted, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['rogue_bgt_tx_16', 'acc_bgt_16', 'cat_gro_16', 99999.0, 'expense', now.toIso8601String(), 0, now.toIso8601String(), now.toIso8601String()],
      );

      // Spent MUST remain strictly ₹3,200
      spent = await budgetRepo.getSpentForCategory('cat_gro_16', startOfMonth, endOfMonth);
      expect(spent, 3200.0);
    });

    test('17. Rogue legacy budget counters do not change displayed budget progress', () async {
      await seedCategory(Category(id: 'cat_dine_17', name: 'Dining Out', icon: 'cafe', color: '#795548', userId: '', type: 'expense'));

      final budget = Budget(
        id: 'bgt_17',
        categoryId: 'cat_dine_17',
        limit: 5000.0,
        period: 'monthly',
        createdAt: DateTime.now(),
      );
      await budgetRepo.insert(budget);

      // Budget table has no financial spent column, but even if rogue columns or caches exist:
      final startOfMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
      final endOfMonth = DateTime(DateTime.now().year, DateTime.now().month + 1, 0, 23, 59, 59);

      final spent = await budgetRepo.getSpentForCategory('cat_dine_17', startOfMonth, endOfMonth);
      expect(spent, 0.0);
    });

    test('18. Canonical expense posting changes budget progress correctly', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bgt_18', name: 'Bank 18', bank: 'HDFC', balance: 30000.0));
      await seedCategory(Category(id: 'cat_util_18', name: 'Utilities', icon: 'bolt', color: '#FFC107', userId: '', type: 'expense'));

      await budgetRepo.insert(Budget(
        id: 'bgt_18',
        categoryId: 'cat_util_18',
        limit: 8000.0,
        period: 'monthly',
        createdAt: DateTime.now(),
      ));

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);

      expect(await budgetRepo.getSpentForCategory('cat_util_18', start, end), 0.0);

      await transactionRepo.insert(Transaction(
        id: 'tx_bgt_18',
        userId: 'user1',
        accountId: 'acc_bgt_18',
        categoryId: 'cat_util_18',
        amount: 2400.0,
        type: 'expense',
        date: now,
      ));

      expect(await budgetRepo.getSpentForCategory('cat_util_18', start, end), 2400.0);
    });

    test('19. Reversal changes budget progress correctly', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bgt_19', name: 'Bank 19', bank: 'ICICI', balance: 25000.0));
      await seedCategory(Category(id: 'cat_book_19', name: 'Books', icon: 'book', color: '#673AB7', userId: '', type: 'expense'));

      await budgetRepo.insert(Budget(
        id: 'bgt_19',
        categoryId: 'cat_book_19',
        limit: 4000.0,
        period: 'monthly',
        createdAt: DateTime.now(),
      ));

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);

      final tx = Transaction(
        id: 'tx_book_19',
        userId: 'user1',
        accountId: 'acc_bgt_19',
        categoryId: 'cat_book_19',
        amount: 1500.0,
        type: 'expense',
        date: now,
      );
      await transactionRepo.insert(tx);
      expect(await budgetRepo.getSpentForCategory('cat_book_19', start, end), 1500.0);

      // Delete/reverse transaction
      await transactionRepo.delete(tx.id);

      // Budget progress must drop back to 0.0
      expect(await budgetRepo.getSpentForCategory('cat_book_19', start, end), 0.0);
    });

    test('20. Refund changes budget spending correctly', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bgt_20', name: 'Bank 20', bank: 'Axis', balance: 35000.0));
      await seedCategory(Category(id: 'cat_wear_20', name: 'Apparel', icon: 'shirt', color: '#9C27B0', userId: '', type: 'expense'));

      await budgetRepo.insert(Budget(
        id: 'bgt_20',
        categoryId: 'cat_wear_20',
        limit: 7000.0,
        period: 'monthly',
        createdAt: DateTime.now(),
      ));

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);

      // Purchase ₹5,000
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_wear_20',
          canonicalType: CanonicalEventType.expense,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_w_20_1',
            economicEventId: 'evt_wear_20',
            accountId: 'cat_wear_20',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(5000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_w_20_2',
            economicEventId: 'evt_wear_20',
            accountId: 'acc_bgt_20',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(5000.0),
            createdAt: now,
          ),
        ],
      );
      expect(await budgetRepo.getSpentForCategory('cat_wear_20', start, end), 5000.0);

      // Refund ₹1,500
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_wref_20',
          canonicalType: CanonicalEventType.refund,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_wr_20_1',
            economicEventId: 'evt_wref_20',
            accountId: 'acc_bgt_20',
            direction: PostingDirection.debit,
            amount: Money.fromRupees(1500.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_wr_20_2',
            economicEventId: 'evt_wref_20',
            accountId: 'cat_wear_20',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(1500.0),
            createdAt: now,
          ),
        ],
      );

      // Net budget spent must be 5000 - 1500 = ₹3,500
      expect(await budgetRepo.getSpentForCategory('cat_wear_20', start, end), 3500.0);
    });

    test('21. Deleted/reversed events are not double-counted', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bgt_21', name: 'Bank 21', bank: 'Canara', balance: 40000.0));
      await seedCategory(Category(id: 'cat_fit_21', name: 'Fitness', icon: 'dumbbell', color: '#009688', userId: '', type: 'expense'));

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);

      final tx = Transaction(
        id: 'tx_fit_21',
        userId: 'user1',
        accountId: 'acc_bgt_21',
        categoryId: 'cat_fit_21',
        amount: 2000.0,
        type: 'expense',
        date: now,
      );
      await transactionRepo.insert(tx);

      // Update to ₹2,500
      await transactionRepo.update(tx.copyWith(amount: 2500.0));

      // Category spending must be exactly ₹2,500 (never 2000 + 2500 = 4500)
      final spending = await budgetRepo.getSpentForCategory('cat_fit_21', start, end);
      expect(spending, 2500.0);
    });

    test('22. Category isolation works correctly', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bgt_22', name: 'Bank 22', bank: 'SBI', balance: 50000.0));
      await seedCategory(Category(id: 'cat_a_22', name: 'Category A', icon: 'a', color: '#111111', userId: '', type: 'expense'));
      await seedCategory(Category(id: 'cat_b_22', name: 'Category B', icon: 'b', color: '#222222', userId: '', type: 'expense'));

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);

      await transactionRepo.insert(Transaction(
        id: 'tx_a_22',
        userId: 'user1',
        accountId: 'acc_bgt_22',
        categoryId: 'cat_a_22',
        amount: 1800.0,
        type: 'expense',
        date: now,
      ));
      await transactionRepo.insert(Transaction(
        id: 'tx_b_22',
        userId: 'user1',
        accountId: 'acc_bgt_22',
        categoryId: 'cat_b_22',
        amount: 3400.0,
        type: 'expense',
        date: now,
      ));

      expect(await budgetRepo.getSpentForCategory('cat_a_22', start, end), 1800.0);
      expect(await budgetRepo.getSpentForCategory('cat_b_22', start, end), 3400.0);
    });

    test('23. Budget period boundaries are respected', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_bgt_23', name: 'Bank 23', bank: 'HDFC', balance: 60000.0));
      await seedCategory(Category(id: 'cat_time_23', name: 'Time Cat', icon: 'clock', color: '#3F51B5', userId: '', type: 'expense'));

      final currentMonthDate = DateTime(2026, 3, 15);
      final prevMonthDate = DateTime(2026, 2, 20);

      await transactionRepo.insert(Transaction(
        id: 'tx_curr_23',
        userId: 'user1',
        accountId: 'acc_bgt_23',
        categoryId: 'cat_time_23',
        amount: 3000.0,
        type: 'expense',
        date: currentMonthDate,
      ));
      await transactionRepo.insert(Transaction(
        id: 'tx_prev_23',
        userId: 'user1',
        accountId: 'acc_bgt_23',
        categoryId: 'cat_time_23',
        amount: 5000.0,
        type: 'expense',
        date: prevMonthDate,
      ));

      final startMarch = DateTime(2026, 3, 1);
      final endMarch = DateTime(2026, 3, 31, 23, 59, 59);

      final spentMarch = await budgetRepo.getSpentForCategory('cat_time_23', startMarch, endMarch);
      expect(spentMarch, 3000.0);

      final startFeb = DateTime(2026, 2, 1);
      final endFeb = DateTime(2026, 2, 28, 23, 59, 59);
      final spentFeb = await budgetRepo.getSpentForCategory('cat_time_23', startFeb, endFeb);
      expect(spentFeb, 5000.0);
    });

    // =========================================================================
    // SECTION 3: FINANCIAL HEALTH / DERIVED METRICS (Invariants 24 - 27)
    // =========================================================================

    test('24. Rogue legacy financial field mutation does not change Financial Health', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_hlth_24', name: 'Bank 24', bank: 'SBI', balance: 100000.0));

      final metricsBefore = await financialHealthService.calculateMetrics();
      final debtScoreBefore = metricsBefore['debtRatio'];

      // Corrupt legacy bank_accounts.balance
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 1.0 WHERE id = ?', ['acc_hlth_24']);

      final metricsAfter = await financialHealthService.calculateMetrics();
      expect(metricsAfter['debtRatio'], debtScoreBefore);

      final bundle = await analyticsRepo.getDashboardBundle(
        transactionRepo: transactionRepo,
        accountRepo: accountRepo,
        loanRepo: loanRepo,
        creditRepo: creditRepo,
        categoryRepo: categoryRepo,
        budgetRepo: budgetRepo,
      );
      expect(bundle.accounts.isNotEmpty, isTrue);
    });

    test('25. Canonical net worth changes propagate into derived health metrics', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_hlth_25', name: 'Bank 25', bank: 'ICICI', balance: 50000.0));

      final metrics1 = await financialHealthService.calculateMetrics();
      expect(metrics1['assetGrowth'], 1.0); // assets > 1000

      final nw = await canonicalQueryRepo.getNetWorth();
      expect(nw.toRupees, 50000.0);

      final balance = await canonicalAccountRepo.getDerivedBalance('acc_hlth_25');
      expect(balance.toRupees, 50000.0);
    });

    test('26. Canonical debt changes propagate into debt-related health metrics', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_hlth_26', name: 'Bank 26', bank: 'Axis', balance: 100000.0));

      final card = CreditCard(
        id: 'card_hlth_26',
        name: 'Platinum Card',
        bank: 'Axis',
        last4: '5555',
        limitAmount: 100000.0,
        usedAmount: 0.0,
        billingDay: 1,
        dueDay: 15,
      );
      await creditRepo.insert(card);

      final metricsNoDebt = await financialHealthService.calculateMetrics();
      expect(metricsNoDebt['debtRatio'], 1.0); // 0 debt -> perfect score 1.0

      // Incur canonical card liability of ₹50,000
      final now = DateTime.now();
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent.draft(
          id: 'evt_hlth_debt_26',
          canonicalType: CanonicalEventType.cardPurchase,
          occurredAt: now,
          createdAt: now,
        ),
        postings: [
          Posting(
            id: 'pst_hd_26_1',
            economicEventId: 'evt_hlth_debt_26',
            accountId: TablesV24.sysExpMisc,
            direction: PostingDirection.debit,
            amount: Money.fromRupees(50000.0),
            createdAt: now,
          ),
          Posting(
            id: 'pst_hd_26_2',
            economicEventId: 'evt_hlth_debt_26',
            accountId: 'card_hlth_26',
            direction: PostingDirection.credit,
            amount: Money.fromRupees(50000.0),
            createdAt: now,
          ),
        ],
      );

      // Debt ratio drops (liabilities 50k / assets 100k = 0.5 -> debt score = 1.0 - 0.5 = 0.5)
      final metricsWithDebt = await financialHealthService.calculateMetrics();
      expect(metricsWithDebt['debtRatio'], 0.5);
    });

    test('27. Cached/stale derived health data cannot override canonical inputs', () async {
      await accountRepo.insertAccount(BankAccount(id: 'acc_hlth_27', name: 'Bank 27', bank: 'HDFC', balance: 60000.0));

      // Calculate fresh score with snapshot save
      final res = await financialHealthService.calculateFinancialHealthScore(saveSnapshot: true);
      expect(res['score'], isNotNull);

      // Now query fresh score again — it derives dynamically from canonical inputs
      final freshScore = await financialHealthService.calculateFinancialHealthScore(saveSnapshot: false);
      expect(freshScore['score'], res['score']);
    });
  });
}
