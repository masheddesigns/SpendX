import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/providers.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/salary_repo.dart';
import 'package:spend_x/data/repositories/lending_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_loan_adapter.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/features/dashboard/providers/dashboard_providers.dart';
import 'package:spend_x/features/home/providers/home_providers.dart';
import 'package:spend_x/models/analytics_bundle.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/analytics_service.dart';
import 'package:spend_x/services/financial_health_service.dart';

class FakeTransactionsNotifier extends TransactionsNotifier {
  final List<spx.Transaction> _txns;
  FakeTransactionsNotifier(this._txns);

  @override
  Future<List<spx.Transaction>> build() async => _txns;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone 5.0 Phase 4 — Group B: Dashboard and Net-Worth Parity (DEF-514 & DEF-516)', () {
    late Database db;
    late CanonicalFinancialQueryRepository canonicalQueryRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late TransactionRepo transactionRepo;
    late FinancialHealthService financialHealthService;

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

      canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      transactionRepo = TransactionRepo(executor: db);

      financialHealthService = FinancialHealthService(
        transactionRepo: transactionRepo,
        accountRepo: AccountRepo(executor: db),
        loanRepo: LoanRepo(executor: db),
        salaryRepo: SalaryRepo(),
        lendingRepo: LendingRepo(),
        categoryRepo: CategoryRepo(),
        queryRepo: canonicalQueryRepo,
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> recordBalancedTransaction({
      required String eventId,
      required String debitAccountId,
      required String creditAccountId,
      required int amountMinorUnits,
      required DateTime timestampUtc,
      required String eventType,
      String? description,
    }) async {
      final now = timestampUtc.toIso8601String();
      await db.insert(TablesV24.economicEvents, {
        'id': eventId,
        'event_type': eventType,
        'lifecycle_status': 'draft',
        'timestamp': now,
        'description': description ?? 'Test transaction $eventId',
        'created_at': now,
        'updated_at': now,
      });

      await db.insert(TablesV24.postings, {
        'id': 'pst_${eventId}_deb',
        'economic_event_id': eventId,
        'account_id': debitAccountId,
        'direction': 'debit',
        'amount_minor_units': amountMinorUnits,
        'currency': 'INR',
        'created_at': now,
      });

      await db.insert(TablesV24.postings, {
        'id': 'pst_${eventId}_cred',
        'economic_event_id': eventId,
        'account_id': creditAccountId,
        'direction': 'credit',
        'amount_minor_units': amountMinorUnits,
        'currency': 'INR',
        'created_at': now,
      });

      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted', 'updated_at': now},
        where: 'id = ?',
        whereArgs: [eventId],
      );
    }

    test('B.1: Refund Netting — ₹2,000 expense and ₹500 refund yields net ₹1,500 across home, dashboard, and FinancialHealthService', () async {
      final now = DateTime.now();
      final txExpense = spx.Transaction(
        id: 'tx_b1_exp',
        userId: 'u1',
        accountId: 'acc1',
        categoryId: 'cat_groceries',
        type: 'expense',
        amount: 2000.0,
        date: now,
        notes: 'Grocery store',
      );
      final txRefund = spx.Transaction(
        id: 'tx_b1_ref',
        userId: 'u1',
        accountId: 'acc1',
        categoryId: 'cat_groceries',
        type: 'refund',
        amount: 500.0,
        date: now,
        notes: 'Returned item',
      );

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([txExpense, txRefund])),
        ],
      );
      await container.read(transactionsProvider.future);

      // 1. homeSummaryProvider
      final homeSummary = container.read(homeSummaryProvider);
      expect(homeSummary.expense, equals(1500.0), reason: 'homeSummaryProvider must net refunds against expenses');
      expect(homeSummary.balance, equals(-1500.0));

      // 2. dashboardSummaryProvider
      final dashboardSummary = container.read(dashboardSummaryProvider);
      expect(dashboardSummary.expense, equals(1500.0), reason: 'dashboardSummaryProvider must net refunds');
      expect(dashboardSummary.currentMonthExpense, equals(1500.0));

      // 3. FinancialHealthService.getMonthlySummary
      await transactionRepo.insert(txExpense);
      await transactionRepo.insert(txRefund);

      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['expenses'], equals(1500.0), reason: 'FinancialHealthService must net refunds');
      expect(fhSummary['categorySpending']['cat_groceries'], equals(1500.0));
    });

    test('B.2: Transfer Exclusion — ₹5,000 transfer is strictly excluded from income and expenses', () async {
      final now = DateTime.now();
      final txTransfer = spx.Transaction(
        id: 'tx_b2_xfer',
        userId: 'u1',
        accountId: 'acc_checking',
        relatedEntityId: 'acc_savings',
        type: 'transfer',
        amount: 5000.0,
        date: now,
        notes: 'Inter-account transfer',
      );

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([txTransfer])),
        ],
      );
      await container.read(transactionsProvider.future);

      final homeSummary = container.read(homeSummaryProvider);
      expect(homeSummary.income, equals(0.0), reason: 'Transfers must not appear as income');
      expect(homeSummary.expense, equals(0.0), reason: 'Transfers must not appear as expense');

      final dashboardSummary = container.read(dashboardSummaryProvider);
      expect(dashboardSummary.income, equals(0.0));
      expect(dashboardSummary.expense, equals(0.0));

      await transactionRepo.insert(txTransfer);
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['income'], equals(0.0));
      expect(fhSummary['expenses'], equals(0.0));
    });

    test('B.3: Credit-Card Purchase — ₹3,500 purchase is counted as spending exactly once', () async {
      final now = DateTime.now();
      final txCardPurchase = spx.Transaction(
        id: 'tx_b3_card_pur',
        userId: 'u1',
        accountId: 'card_hdfc',
        categoryId: 'cat_dining',
        type: 'credit_card_purchase',
        amount: 3500.0,
        date: now,
        notes: 'Restaurant dinner',
      );

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([txCardPurchase])),
        ],
      );
      await container.read(transactionsProvider.future);

      final homeSummary = container.read(homeSummaryProvider);
      expect(homeSummary.expense, equals(3500.0), reason: 'Credit card purchase must be counted as spending');
      expect(homeSummary.currentMonthExpense, equals(3500.0));

      final dashboardSummary = container.read(dashboardSummaryProvider);
      expect(dashboardSummary.expense, equals(3500.0));
      expect(dashboardSummary.currentMonthExpense, equals(3500.0));

      // In FinancialHealthService
      await transactionRepo.insert(txCardPurchase);
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['expenses'], equals(3500.0));
      expect(fhSummary['categorySpending']['cat_dining'], equals(3500.0));
    });

    test('B.4: Credit-Card Bill Payment — ₹3,500 payment is excluded from expenses (no double-counting)', () async {
      final now = DateTime.now();
      final txPayment = spx.Transaction(
        id: 'tx_b4_cc_pay',
        userId: 'u1',
        accountId: 'acc_bank',
        relatedEntityId: 'card_hdfc',
        type: 'credit_card_payment',
        amount: 3500.0,
        date: now,
        notes: 'Monthly card bill payment',
      );

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([txPayment])),
        ],
      );
      await container.read(transactionsProvider.future);

      final homeSummary = container.read(homeSummaryProvider);
      expect(homeSummary.expense, equals(0.0), reason: 'Credit card bill payments must NOT be counted as new expenses');
      expect(homeSummary.income, equals(0.0));

      final dashboardSummary = container.read(dashboardSummaryProvider);
      expect(dashboardSummary.expense, equals(0.0));

      await transactionRepo.insert(txPayment);
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['expenses'], equals(0.0));
    });

    test('B.5: Loan Repayment — ₹10,000 principal + ₹2,000 interest only counts interest as expense', () async {
      final now = DateTime.now();
      final txLoanRepayWithSplit = spx.Transaction(
        id: 'tx_b5_split',
        userId: 'u1',
        accountId: 'acc_bank',
        relatedEntityId: 'loan_auto',
        type: 'loan_repayment',
        amount: 12000.0,
        date: now,
        notes: 'Car EMI. Principal: 10000.0, Interest: 2000.0',
      );
      final txLoanRepayPurePrincipal = spx.Transaction(
        id: 'tx_b5_principal_only',
        userId: 'u1',
        accountId: 'acc_bank',
        relatedEntityId: 'loan_auto',
        type: 'loan_repayment',
        amount: 5000.0,
        date: now,
        notes: 'Prepayment towards principal',
      );

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([txLoanRepayWithSplit, txLoanRepayPurePrincipal])),
        ],
      );
      await container.read(transactionsProvider.future);

      // In homeSummaryProvider: only interest portion (2000.0) is expense
      final homeSummary = container.read(homeSummaryProvider);
      expect(homeSummary.expense, equals(2000.0), reason: 'Principal must not be counted as expense; only interest counts');

      // In dashboardSummaryProvider: only interest portion (2000.0) is expense
      final dashboardSummary = container.read(dashboardSummaryProvider);
      expect(dashboardSummary.expense, equals(2000.0));

      // In FinancialHealthService
      await transactionRepo.insert(txLoanRepayWithSplit);
      await transactionRepo.insert(txLoanRepayPurePrincipal);
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['expenses'], equals(2000.0));

      // In AnalyticsService
      final bundle = AnalyticsBundle(
        transactions: [txLoanRepayWithSplit, txLoanRepayPurePrincipal],
        accounts: const [],
        loans: const [],
        cards: const [],
        categories: const [],
        budgets: const [],
      );
      final analyticsSummary = AnalyticsService().computeSummary(bundle);
      expect(analyticsSummary.monthlyExpense, equals(2000.0));
    });

    test('B.6: Canonical Net Worth Parity (DEF-516) — Home greeting & AnalyticsService align with canonical ledger', () async {
      final now = DateTime.now();
      final nowUtc = now.toUtc();

      // 1. Post canonical asset balance of ₹25,000 (2,500,000 paise)
      await canonicalAccountRepo.createAccount(
        Account(
          id: 'acc_savings_b6',
          name: 'Savings Bank',
          type: AccountType.asset,
          category: 'savings',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await recordBalancedTransaction(
        eventId: 'evt_nw_b6_asset',
        debitAccountId: 'acc_savings_b6',
        creditAccountId: TablesV24.sysEquityOpening,
        amountMinorUnits: 2500000,
        timestampUtc: nowUtc,
        eventType: 'opening_balance',
      );

      // 2. Post canonical liability balance of ₹7,000 (700,000 paise)
      await canonicalAccountRepo.createAccount(
        Account(
          id: 'acc_card_b6',
          name: 'Axis Card',
          type: AccountType.liability,
          category: 'credit_card',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await recordBalancedTransaction(
        eventId: 'evt_nw_b6_liab',
        debitAccountId: TablesV24.sysExpMisc,
        creditAccountId: 'acc_card_b6',
        amountMinorUnits: 700000,
        timestampUtc: nowUtc,
        eventType: 'expense',
      );

      // Canonical Net Worth: 25,000 - 7,000 = 18,000
      final canonicalNw = await canonicalQueryRepo.getNetWorth();
      expect(canonicalNw.toRupees, equals(18000.0));

      // Test AnalyticsService with canonicalNetWorth pass-through
      final bankAcc = BankAccount(
        id: 'acc_savings_b6',
        userId: 'u1',
        name: 'Savings Bank',
        bank: 'SBI',
        balance: 25000.0,
      );
      // Stale card usedAmount in legacy row
      final staleCard = CreditCard(
        id: 'acc_card_b6',
        userId: 'u1',
        name: 'Axis Card',
        bank: 'Axis',
        last4: '9999',
        limitAmount: 50000.0,
        usedAmount: 0.0,
        dueDay: 15,
      );

      final bundle = AnalyticsBundle(
        transactions: const [],
        accounts: [bankAcc],
        loans: const [],
        cards: [staleCard],
        categories: const [],
        budgets: const [],
        canonicalNetWorth: canonicalNw.toRupees,
      );

      final summary = AnalyticsService().computeSummary(bundle);
      expect(summary.netWorth, equals(18000.0), reason: 'AnalyticsService must report exact canonical net worth ₹18,000');

      // Test Riverpod netWorthProvider
      final container = ProviderContainer(
        overrides: [
          canonicalFinancialQueryRepositoryProvider.overrideWithValue(canonicalQueryRepo),
          netWorthSummaryProvider.overrideWith((ref) async => (
            assets: 25000.0,
            liabilities: 7000.0,
            netWorth: 18000.0,
          )),
        ],
      );
      await container.read(netWorthSummaryProvider.future);

      final netWorthFromProvider = container.read(netWorthProvider);
      expect(netWorthFromProvider, equals(18000.0), reason: 'netWorthProvider must provide canonical ₹18,000');
    });

    test('B.7: Multi-transaction realistic monthly scenario — income, expense, refund, card, transfer, loan', () async {
      final now = DateTime.now();
      final txns = [
        spx.Transaction(id: 't1', userId: 'u1', type: 'income', amount: 80000.0, date: now),
        spx.Transaction(id: 't2', userId: 'u1', type: 'expense', amount: 15000.0, date: now),
        spx.Transaction(id: 't3', userId: 'u1', type: 'credit_card_purchase', amount: 8000.0, date: now),
        spx.Transaction(id: 't4', userId: 'u1', type: 'refund', amount: 3000.0, date: now),
        spx.Transaction(id: 't5', userId: 'u1', type: 'transfer', amount: 20000.0, date: now),
        spx.Transaction(id: 't6', userId: 'u1', type: 'credit_card_payment', amount: 8000.0, date: now),
        spx.Transaction(id: 't7', userId: 'u1', type: 'loan_repayment', amount: 25000.0, notes: 'Principal: 21000, Interest: 4000', date: now),
      ];

      // Net Income = 80,000
      // Net Expense = 15,000 (expense) + 8,000 (card purchase) - 3,000 (refund) + 4,000 (loan interest) = 24,000
      // Net Cash Flow / Balance = 80,000 - 24,000 = 56,000

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier(txns)),
        ],
      );
      await container.read(transactionsProvider.future);

      final homeSummary = container.read(homeSummaryProvider);
      expect(homeSummary.income, equals(80000.0));
      expect(homeSummary.expense, equals(24000.0));
      expect(homeSummary.balance, equals(56000.0));

      final dashboardSummary = container.read(dashboardSummaryProvider);
      expect(dashboardSummary.income, equals(80000.0));
      expect(dashboardSummary.expense, equals(24000.0));
      expect(dashboardSummary.balance, equals(56000.0));
    });

    test('B.8: Loan Interest Parity — Combined EMI with annotation and without annotation preserves ₹2,000 expense across all layers', () async {
      final now = DateTime.now();
      final eventRepo = CanonicalEventRepository(executor: db);

      await canonicalAccountRepo.createAccount(Account(
        id: 'acc_bank_b8',
        name: 'Bank Account',
        type: AccountType.asset,
        category: 'savings',
        createdAt: now,
        updatedAt: now,
      ));
      await canonicalAccountRepo.createAccount(Account(
        id: 'loan_home_b8',
        name: 'Home Loan',
        type: AccountType.liability,
        category: 'loan',
        createdAt: now,
        updatedAt: now,
      ));

      // 1. Create canonical combined EMI payment records with annotation in note
      final combinedRecordsWithNote = CanonicalLoanAdapter.createCombinedPaymentRecords(
        loanId: 'loan_home_b8',
        assetAccountId: 'acc_bank_b8',
        principalAmount: Money.fromRupees(10000.0),
        interestAmount: Money.fromRupees(2000.0),
        timestamp: now,
        description: 'Home Loan EMI. Principal: 10000.0, Interest: 2000.0',
        eventId: 'evt_emi_with_note',
      );

      await eventRepo.createAndPostEvent(
        combinedRecordsWithNote.event,
        postings: combinedRecordsWithNote.postings,
        evidence: [combinedRecordsWithNote.evidence],
      );

      final annotatedTx = (await transactionRepo.getAll()).firstWhere((t) => t.id == 'evt_emi_with_note');
      expect(annotatedTx.interestAmount, equals(2000.0), reason: 'Transaction must project structured interestAmount from postings');

      // 2. Create the exact same EMI with NO annotation (annotation removed / unannotated)
      final combinedRecordsNoNote = CanonicalLoanAdapter.createCombinedPaymentRecords(
        loanId: 'loan_home_b8',
        assetAccountId: 'acc_bank_b8',
        principalAmount: Money.fromRupees(10000.0),
        interestAmount: Money.fromRupees(2000.0),
        timestamp: now,
        description: 'Standard Loan Payment', // Note without 'Interest:'
        eventId: 'evt_emi_no_note',
      );

      await eventRepo.createAndPostEvent(
        combinedRecordsNoNote.event,
        postings: combinedRecordsNoNote.postings,
        evidence: [combinedRecordsNoNote.evidence],
      );

      final unannotatedTx = (await transactionRepo.getAll()).firstWhere((t) => t.id == 'evt_emi_no_note');
      expect(unannotatedTx.notes.contains('Interest:'), isFalse, reason: 'Must have no Interest: note');
      expect(unannotatedTx.interestAmount, equals(2000.0), reason: 'Must still have ₹2,000 structured interest from postings');

      // 3. Test unannotatedTx across Home, Dashboard, Analytics, Financial Health
      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([unannotatedTx])),
        ],
      );
      await container.read(transactionsProvider.future);

      // Home
      expect(container.read(homeSummaryProvider).expense, equals(2000.0), reason: 'Home must recognize structured interest without note');

      // Dashboard
      expect(container.read(dashboardSummaryProvider).expense, equals(2000.0), reason: 'Dashboard must recognize structured interest without note');

      // Analytics
      final bundle = AnalyticsBundle(
        transactions: [unannotatedTx],
        accounts: const [],
        loans: const [],
        cards: const [],
        categories: const [],
        budgets: const [],
      );
      expect(AnalyticsService().computeSummary(bundle).monthlyExpense, equals(2000.0), reason: 'Analytics must recognize structured interest without note');

      // Financial Health
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      // Both evt_emi_with_note and evt_emi_no_note are in DB: total interest expense = 2000 + 2000 = 4000
      expect(fhSummary['expenses'], equals(4000.0), reason: 'Financial Health must sum both structured interest amounts');

      // Canonical monthly SQL reporting (TransactionRepo.getStatsForRange)
      final monthStart = DateTime(now.year, now.month, 1);
      final monthEnd = DateTime(now.year, now.month + 1, 1);
      final sqlStats = await transactionRepo.getStatsForRange(monthStart, monthEnd);
      expect(sqlStats['expense'], equals(4000.0), reason: 'SQL canonical aggregation must equal exactly 4000.0');
    });

    test('B.9: Principal-only Prepayment — ₹5,000 prepayment has ₹0 expense across all layers', () async {
      final now = DateTime.now();
      final eventRepo = CanonicalEventRepository(executor: db);

      await canonicalAccountRepo.createAccount(Account(
        id: 'acc_bank_b9',
        name: 'Bank Account',
        type: AccountType.asset,
        category: 'savings',
        createdAt: now,
        updatedAt: now,
      ));
      await canonicalAccountRepo.createAccount(Account(
        id: 'loan_auto_b9',
        name: 'Auto Loan',
        type: AccountType.liability,
        category: 'loan',
        createdAt: now,
        updatedAt: now,
      ));

      final prepayRecords = CanonicalLoanAdapter.createRepaymentRecords(
        loanId: 'loan_auto_b9',
        assetAccountId: 'acc_bank_b9',
        principalAmount: Money.fromRupees(5000.0),
        timestamp: now,
        description: 'Prepayment towards principal',
        eventId: 'evt_prepay_b9',
      );

      await eventRepo.createAndPostEvent(
        prepayRecords.event,
        postings: prepayRecords.postings,
        evidence: [prepayRecords.evidence],
      );

      final tx = (await transactionRepo.getAll()).firstWhere((t) => t.id == 'evt_prepay_b9');
      expect(tx.interestAmount, isNull, reason: 'Principal-only repayment has no interest debit');

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([tx])),
        ],
      );
      await container.read(transactionsProvider.future);

      // Home
      expect(container.read(homeSummaryProvider).expense, equals(0.0));
      // Dashboard
      expect(container.read(dashboardSummaryProvider).expense, equals(0.0));
      // Analytics
      final bundle = AnalyticsBundle(
        transactions: [tx],
        accounts: const [],
        loans: const [],
        cards: const [],
        categories: const [],
        budgets: const [],
      );
      expect(AnalyticsService().computeSummary(bundle).monthlyExpense, equals(0.0));
      // Financial Health
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['expenses'], equals(0.0));
      // SQL Canonical getStatsForRange
      final monthStart = DateTime(now.year, now.month, 1);
      final monthEnd = DateTime(now.year, now.month + 1, 1);
      final sqlStats = await transactionRepo.getStatsForRange(monthStart, monthEnd);
      expect(sqlStats['expense'], equals(0.0));
    });

    test('B.10: Interest-only Payment — ₹2,000 interest payment is ₹2,000 expense across all layers', () async {
      final now = DateTime.now();
      final eventRepo = CanonicalEventRepository(executor: db);

      await canonicalAccountRepo.createAccount(Account(
        id: 'acc_bank_b10',
        name: 'Bank Account',
        type: AccountType.asset,
        category: 'savings',
        createdAt: now,
        updatedAt: now,
      ));
      await canonicalAccountRepo.createAccount(Account(
        id: 'loan_edu_b10',
        name: 'Education Loan',
        type: AccountType.liability,
        category: 'loan',
        createdAt: now,
        updatedAt: now,
      ));

      final interestRecords = CanonicalLoanAdapter.createInterestPaymentRecords(
        loanId: 'loan_edu_b10',
        assetAccountId: 'acc_bank_b10',
        interestAmount: Money.fromRupees(2000.0),
        timestamp: now,
        description: 'Monthly loan interest charge',
        eventId: 'evt_interest_b10',
      );

      await eventRepo.createAndPostEvent(
        interestRecords.event,
        postings: interestRecords.postings,
        evidence: [interestRecords.evidence],
      );

      final tx = (await transactionRepo.getAll()).firstWhere((t) => t.id == 'evt_interest_b10');
      expect(tx.interestAmount, equals(2000.0));

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier([tx])),
        ],
      );
      await container.read(transactionsProvider.future);

      // Home
      expect(container.read(homeSummaryProvider).expense, equals(2000.0));
      // Dashboard
      expect(container.read(dashboardSummaryProvider).expense, equals(2000.0));
      // Analytics
      final bundle = AnalyticsBundle(
        transactions: [tx],
        accounts: const [],
        loans: const [],
        cards: const [],
        categories: const [],
        budgets: const [],
      );
      expect(AnalyticsService().computeSummary(bundle).monthlyExpense, equals(2000.0));
      // Financial Health
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['expenses'], equals(2000.0));
      // SQL Canonical getStatsForRange
      final monthStart = DateTime(now.year, now.month, 1);
      final monthEnd = DateTime(now.year, now.month + 1, 1);
      final sqlStats = await transactionRepo.getStatsForRange(monthStart, monthEnd);
      expect(sqlStats['expense'], equals(2000.0));
    });

    test('B.11: Multiple Repayments in Same Period — Combined EMI + Prepayment + Interest-Only maintains exact parity', () async {
      final now = DateTime.now();
      final eventRepo = CanonicalEventRepository(executor: db);

      await canonicalAccountRepo.createAccount(Account(
        id: 'acc_bank_b11',
        name: 'Bank Account',
        type: AccountType.asset,
        category: 'savings',
        createdAt: now,
        updatedAt: now,
      ));
      await canonicalAccountRepo.createAccount(Account(
        id: 'loan_b11',
        name: 'Flexi Loan',
        type: AccountType.liability,
        category: 'loan',
        createdAt: now,
        updatedAt: now,
      ));

      // 1. EMI: Principal 10,000 + Interest 2,000 (Expense = 2,000)
      final emi = CanonicalLoanAdapter.createCombinedPaymentRecords(
        loanId: 'loan_b11',
        assetAccountId: 'acc_bank_b11',
        principalAmount: Money.fromRupees(10000.0),
        interestAmount: Money.fromRupees(2000.0),
        timestamp: now,
        description: 'Regular EMI',
        eventId: 'evt_multi_1',
      );
      await eventRepo.createAndPostEvent(emi.event, postings: emi.postings, evidence: [emi.evidence]);

      // 2. Prepayment: Principal 5,000 (Expense = 0)
      final prepay = CanonicalLoanAdapter.createRepaymentRecords(
        loanId: 'loan_b11',
        assetAccountId: 'acc_bank_b11',
        principalAmount: Money.fromRupees(5000.0),
        timestamp: now,
        description: 'Principal prepayment',
        eventId: 'evt_multi_2',
      );
      await eventRepo.createAndPostEvent(prepay.event, postings: prepay.postings, evidence: [prepay.evidence]);

      // 3. Interest only: Interest 1,500 (Expense = 1,500)
      final interestOnly = CanonicalLoanAdapter.createInterestPaymentRecords(
        loanId: 'loan_b11',
        assetAccountId: 'acc_bank_b11',
        interestAmount: Money.fromRupees(1500.0),
        timestamp: now,
        description: 'Interest adjustment',
        eventId: 'evt_multi_3',
      );
      await eventRepo.createAndPostEvent(interestOnly.event, postings: interestOnly.postings, evidence: [interestOnly.evidence]);

      // Total expected expense = 2000 + 0 + 1500 = 3500.0
      final allTxns = await transactionRepo.getAll();
      expect(allTxns.length, equals(3));

      final container = ProviderContainer(
        overrides: [
          transactionsProvider.overrideWith(() => FakeTransactionsNotifier(allTxns)),
        ],
      );
      await container.read(transactionsProvider.future);

      // Home
      expect(container.read(homeSummaryProvider).expense, equals(3500.0));
      // Dashboard
      expect(container.read(dashboardSummaryProvider).expense, equals(3500.0));
      // Analytics
      final bundle = AnalyticsBundle(
        transactions: allTxns,
        accounts: const [],
        loans: const [],
        cards: const [],
        categories: const [],
        budgets: const [],
      );
      expect(AnalyticsService().computeSummary(bundle).monthlyExpense, equals(3500.0));
      // Financial Health
      final fhSummary = await financialHealthService.getMonthlySummary(now);
      expect(fhSummary['expenses'], equals(3500.0));
      // SQL Canonical getStatsForRange
      final monthStart = DateTime(now.year, now.month, 1);
      final monthEnd = DateTime(now.year, now.month + 1, 1);
      final sqlStats = await transactionRepo.getStatsForRange(monthStart, monthEnd);
      expect(sqlStats['expense'], equals(3500.0));
    });

    test('B.12: Structured Interest Precedence — tx.interestAmount overrides conflicting free-text note annotation', () async {
      final now = DateTime.now();

      // 1. Transaction with total ₹12,000, structured interest ₹2,000, but note says Interest: 1500
      final txConflicting = spx.Transaction(
        id: 'tx_conflicting_b12',
        userId: 'u1',
        accountId: 'acc_bank_b12',
        relatedEntityId: 'loan_car_b12',
        type: 'loan_repayment',
        amount: 12000.0,
        date: now,
        notes: 'EMI repayment. Principal: 10500, Interest: 1500',
        interestAmount: 2000.0, // Structured interest is authoritative
      );

      final postings = CanonicalTransactionAdapter.toPostings(
        txConflicting,
        eventId: 'evt_conflicting_b12',
      );

      // Verify postings count and structure
      expect(postings.length, equals(3), reason: 'Must have 3 legs (principal Dr, interest Dr, bank Cr)');

      // Interest posting: ₹2,000 (200,000 paise)
      final interestPosting = postings.firstWhere(
        (p) => p.accountId == TablesV24.sysExpInterest && p.direction == PostingDirection.debit,
      );
      expect(interestPosting.amount.minorUnits, equals(200000), reason: 'Interest posting must be ₹2,000, ignoring note of 1500');

      // Principal posting: ₹10,000 (1,000,000 paise)
      final principalPosting = postings.firstWhere(
        (p) => p.accountId == 'loan_car_b12' && p.direction == PostingDirection.debit,
      );
      expect(principalPosting.amount.minorUnits, equals(1000000), reason: 'Principal posting must be ₹10,000');

      // Bank credit: ₹12,000 (1,200,000 paise)
      final bankPosting = postings.firstWhere(
        (p) => p.accountId == 'acc_bank_b12' && p.direction == PostingDirection.credit,
      );
      expect(bankPosting.amount.minorUnits, equals(1200000), reason: 'Bank credit must be ₹12,000');

      // Balanced postings check
      final totalDebits = postings
          .where((p) => p.direction == PostingDirection.debit)
          .fold<int>(0, (sum, p) => sum + p.amount.minorUnits);
      final totalCredits = postings
          .where((p) => p.direction == PostingDirection.credit)
          .fold<int>(0, (sum, p) => sum + p.amount.minorUnits);
      expect(totalDebits, equals(totalCredits), reason: 'Postings must balance exactly');
      expect(totalDebits, equals(1200000));

      // 2. Legacy transaction with NO structured interest amount (interestAmount == null) uses note parser
      final txLegacy = spx.Transaction(
        id: 'tx_legacy_b12',
        userId: 'u1',
        accountId: 'acc_bank_b12',
        relatedEntityId: 'loan_car_b12',
        type: 'loan_repayment',
        amount: 12000.0,
        date: now,
        notes: 'Legacy EMI. Principal: 9500, Interest: 2500',
        interestAmount: null, // No structured interest provided
      );

      final legacyPostings = CanonicalTransactionAdapter.toPostings(
        txLegacy,
        eventId: 'evt_legacy_b12',
      );
      final legacyInterestPosting = legacyPostings.firstWhere(
        (p) => p.accountId == TablesV24.sysExpInterest && p.direction == PostingDirection.debit,
      );
      expect(legacyInterestPosting.amount.minorUnits, equals(250000), reason: 'Legacy transaction without interestAmount must parse note');

      // 3. Validation: interest exceeding total repayment throws ArgumentError
      final txExcessive = spx.Transaction(
        id: 'tx_excessive_b12',
        userId: 'u1',
        accountId: 'acc_bank_b12',
        relatedEntityId: 'loan_car_b12',
        type: 'loan_repayment',
        amount: 5000.0,
        date: now,
        interestAmount: 6000.0, // Exceeds 5000.0
      );
      expect(
        () => CanonicalTransactionAdapter.toPostings(txExcessive, eventId: 'evt_err'),
        throwsArgumentError,
      );
    });

    test('B.13: Zero-Interest Loan Repayment — interestAmount: 0 produces 100% principal debit, zero interest postings, and ignores conflicting notes', () {
      final now = DateTime.now();

      // 1. Transaction with interestAmount: 0, conflicting note 'Interest: 800'
      final txZeroInterest = spx.Transaction(
        id: 'tx_zero_b13',
        userId: 'u1',
        accountId: 'acc_bank_b13',
        relatedEntityId: 'loan_liability_b13',
        type: 'loan_repayment',
        amount: 8000.0,
        date: now,
        notes: 'Prepayment with conflicting note. Principal: 7200, Interest: 800',
        interestAmount: 0.0, // Structured 0 interest
      );

      final postings = CanonicalTransactionAdapter.toPostings(
        txZeroInterest,
        eventId: 'evt_zero_b13',
      );

      // Must produce exactly 2 postings: Debit loan liability, Credit bank asset
      expect(postings.length, equals(2), reason: 'Zero-interest repayment must produce exactly 2 postings');

      // 1. Debit loan liability for full amount ₹8,000 (800,000 paise)
      final loanDebit = postings.firstWhere(
        (p) => p.accountId == 'loan_liability_b13' && p.direction == PostingDirection.debit,
      );
      expect(loanDebit.amount.minorUnits, equals(800000), reason: 'Full ₹8,000 must debit loan liability');

      // 2. Credit bank asset for full amount ₹8,000 (800,000 paise)
      final bankCredit = postings.firstWhere(
        (p) => p.accountId == 'acc_bank_b13' && p.direction == PostingDirection.credit,
      );
      expect(bankCredit.amount.minorUnits, equals(800000), reason: 'Full ₹8,000 must credit bank asset');

      // 3. No sysExpInterest posting exists
      final hasInterestPosting = postings.any((p) => p.accountId == TablesV24.sysExpInterest);
      expect(hasInterestPosting, isFalse, reason: 'Zero-interest repayment must NOT have any sysExpInterest posting');

      // 4. Balanced postings
      final totalDebits = postings
          .where((p) => p.direction == PostingDirection.debit)
          .fold<int>(0, (sum, p) => sum + p.amount.minorUnits);
      final totalCredits = postings
          .where((p) => p.direction == PostingDirection.credit)
          .fold<int>(0, (sum, p) => sum + p.amount.minorUnits);
      expect(totalDebits, equals(totalCredits));
      expect(totalDebits, equals(800000));

      // 5. Negative interest validation: throws ArgumentError
      final txNegativeInterest = spx.Transaction(
        id: 'tx_neg_b13',
        userId: 'u1',
        accountId: 'acc_bank_b13',
        relatedEntityId: 'loan_liability_b13',
        type: 'loan_repayment',
        amount: 8000.0,
        date: now,
        interestAmount: -100.0, // Negative interest is invalid
      );
      expect(
        () => CanonicalTransactionAdapter.toPostings(txNegativeInterest, eventId: 'evt_neg'),
        throwsArgumentError,
        reason: 'Negative interestAmount must be rejected with ArgumentError',
      );
    });
  });
}
