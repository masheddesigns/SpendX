import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_opening_balance_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('C3A.1 Canonical Semantic Closure Audit Test Suite', () {
    late Database db;
    late CanonicalAccountRepository accountRepo;
    late CanonicalEventRepository eventRepo;
    late CanonicalFinancialQueryRepository queryRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late CanonicalOpeningBalanceRepository obrRepo;
    late CanonicalReviewRepository reviewRepo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await TablesV24.createAllV24(db);
      await TablesV24.installTriggers(db);
      await TablesV24.seedSystemAccounts(db);

      accountRepo = CanonicalAccountRepository(executor: db);
      eventRepo = CanonicalEventRepository(executor: db);
      queryRepo = CanonicalFinancialQueryRepository(executor: db);
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      obrRepo = CanonicalOpeningBalanceRepository(executor: db);
      reviewRepo = CanonicalReviewRepository(executor: db);

      final now = DateTime.now();
      // Chart of Accounts for semantic audit
      await accountRepo.createAccount(Account(
        id: 'acc_bank_a',
        name: 'Bank Account A',
        type: AccountType.asset,
        category: 'bank',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_bank_b',
        name: 'Bank Account B',
        type: AccountType.asset,
        category: 'bank',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_card',
        name: 'Credit Card',
        type: AccountType.liability,
        category: 'credit_card',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_loan',
        name: 'Personal Loan',
        type: AccountType.liability,
        category: 'loan',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_salary',
        name: 'Salary',
        type: AccountType.income,
        category: 'salary',
        createdAt: now,
        updatedAt: now,
      ));
      await accountRepo.createAccount(Account(
        id: 'acc_expense_gen',
        name: 'General Expense',
        type: AccountType.expense,
        category: 'general',
        createdAt: now,
        updatedAt: now,
      ));
    });

    tearDown(() async {
      await db.close();
    });

    // =========================================================================
    // SECTION 2: EXPENSE SEMANTICS
    // =========================================================================
    test('Semantic 2: Expense from Bank (Assets -1k, Expenses +1k, NetWorth -1k, CashFlow -1k)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_exp_1',
          economicEventId: 'evt_exp',
          accountId: 'acc_expense_gen',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(100000), // ₹1,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_exp_2',
          economicEventId: 'evt_exp',
          accountId: 'acc_bank_a',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(100000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_exp',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Office Supplies',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      // Effects:
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, -100000);
      expect((await queryRepo.getTotalAssets()).minorUnits, -100000);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 100000);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, -100000);
      expect((await queryRepo.getCashFlow()).minorUnits, -100000);
    });

    // =========================================================================
    // SECTION 2: INCOME SEMANTICS
    // =========================================================================
    test('Semantic 2: Income into Bank (Assets +50k, Income +50k, NetWorth +50k, CashFlow +50k)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_inc_1',
          economicEventId: 'evt_inc',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000000), // ₹50,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_inc_2',
          economicEventId: 'evt_inc',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_inc',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Monthly Salary',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      // Effects:
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 5000000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 5000000);
      expect((await queryRepo.getTotalIncome()).minorUnits, 5000000);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, 5000000);
      expect((await queryRepo.getCashFlow()).minorUnits, 5000000);
    });

    // =========================================================================
    // SECTION 2: TRANSFER SEMANTICS
    // =========================================================================
    test('Semantic 2: Inter-Account Transfer (Assets change 0, Income 0, Expenses 0, NetWorth 0, CashFlow 0)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_tr_1',
          economicEventId: 'evt_tr',
          accountId: 'acc_bank_b',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(1000000), // ₹10,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_tr_2',
          economicEventId: 'evt_tr',
          accountId: 'acc_bank_a',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(1000000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_tr',
          canonicalType: CanonicalEventType.transfer,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Transfer A to B',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      expect((await accountRepo.getDerivedBalance('acc_bank_b')).minorUnits, 1000000);
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, -1000000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, 0);
      expect((await queryRepo.getCashFlow()).minorUnits, 0);
    });

    // =========================================================================
    // SECTION 3: CREDIT CARD PURCHASE
    // =========================================================================
    test('Semantic 3: Credit Card Purchase (Expense +2k, Liability +2k, NetWorth -2k, CashFlow 0)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_cc_p1',
          economicEventId: 'evt_cc_p',
          accountId: 'acc_expense_gen',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(200000), // ₹2,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_cc_p2',
          economicEventId: 'evt_cc_p',
          accountId: 'acc_card',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(200000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_cc_p',
          canonicalType: CanonicalEventType.cardPurchase,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Card Purchase',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      expect((await queryRepo.getTotalExpenses()).minorUnits, 200000);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 200000);
      expect((await accountRepo.getDerivedBalance('acc_card')).minorUnits, 200000);
      expect((await queryRepo.getNetWorth()).minorUnits, -200000);
      // Critical: Bank cash is untouched, so Cash Flow is strictly ₹0
      expect((await queryRepo.getCashFlow()).minorUnits, 0);
    });

    // =========================================================================
    // SECTION 4: CREDIT CARD PAYMENT
    // =========================================================================
    test('Semantic 4: Credit Card Payment (Bank -2k, Card -2k, Expenses 0, Income 0, NetWorth 0)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_cc_pay1',
          economicEventId: 'evt_cc_pay',
          accountId: 'acc_card',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(200000), // ₹2,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_cc_pay2',
          economicEventId: 'evt_cc_pay',
          accountId: 'acc_bank_a',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(200000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_cc_pay',
          canonicalType: CanonicalEventType.cardPayment,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Card Bill Payment',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, -200000);
      // Liability reduced by 2000: credit balance becomes -200000 (net debit against card)
      expect((await accountRepo.getDerivedBalance('acc_card')).minorUnits, -200000);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, -200000);
      // Crucial: NOT an expense or income!
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, 0);
      // Cash was transferred out of bank, so cash flow is -200000
      expect((await queryRepo.getCashFlow()).minorUnits, -200000);
    });

    // =========================================================================
    // SECTION 5: REFUND (CONTRA-EXPENSE)
    // =========================================================================
    test('Semantic 5: Refund into Bank (Assets +500, Expenses -500, NetWorth +500, CashFlow +500, Income 0)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_ref_1',
          economicEventId: 'evt_ref',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(50000), // ₹500.00
          createdAt: now,
        ),
        Posting(
          id: 'p_ref_2',
          economicEventId: 'evt_ref',
          accountId: TablesV24.sysExpRefunds,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(50000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_ref',
          canonicalType: CanonicalEventType.refund,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Merchant Refund',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 50000);
      // sysExpRefunds is credited: normal debit expense balance is -50000
      expect((await queryRepo.getTotalExpenses()).minorUnits, -50000);
      // Crucial: Unmatched refunds NEVER become income!
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, 50000);
      expect((await queryRepo.getCashFlow()).minorUnits, 50000);
    });

    // =========================================================================
    // SECTION 6: LOAN DISBURSEMENT
    // =========================================================================
    test('Semantic 6: Loan Disbursement (Assets +100k, Liabilities +100k, NetWorth 0, Income 0)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_ld_1',
          economicEventId: 'evt_ld',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(10000000), // ₹1,00,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_ld_2',
          economicEventId: 'evt_ld',
          accountId: 'acc_loan',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(10000000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_ld',
          canonicalType: CanonicalEventType.loanDisbursement,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Personal Loan Disbursement',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      expect((await queryRepo.getTotalAssets()).minorUnits, 10000000);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 10000000);
      expect((await queryRepo.getNetWorth()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getCashFlow()).minorUnits, 10000000);
    });

    // =========================================================================
    // SECTION 7: LOAN REPAYMENT (PRINCIPAL + INTEREST SPLIT)
    // =========================================================================
    test('Semantic 7: Loan Repayment (Liability -8k, Expense +2k, Assets -10k, NetWorth -2k, CashFlow -10k)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_lr_1',
          economicEventId: 'evt_lr',
          accountId: 'acc_loan',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(800000), // ₹8,000.00 principal
          createdAt: now,
        ),
        Posting(
          id: 'p_lr_2',
          economicEventId: 'evt_lr',
          accountId: TablesV24.sysExpInterest,
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(200000), // ₹2,000.00 interest
          createdAt: now,
        ),
        Posting(
          id: 'p_lr_3',
          economicEventId: 'evt_lr',
          accountId: 'acc_bank_a',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(1000000), // ₹10,000.00 total debit from bank
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_lr',
          canonicalType: CanonicalEventType.loanRepayment,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Loan EMI Payment',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      // Principal repayment is a liability reduction, NOT an expense
      expect((await accountRepo.getDerivedBalance('acc_loan')).minorUnits, -800000);
      // Interest is an expense
      expect((await queryRepo.getTotalExpenses()).minorUnits, 200000);
      // Total bank asset reduced by 10,000
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, -1000000);
      // Net Worth impact = Assets (-10k) - Liabilities (-8k) = -2k
      expect((await queryRepo.getNetWorth()).minorUnits, -200000);
      // Physical Cash Flow is -10k
      expect((await queryRepo.getCashFlow()).minorUnits, -1000000);
    });

    // =========================================================================
    // SECTION 8 & 9: ACCOUNT BALANCES & GLOBAL ACCOUNTING EQUATION
    // =========================================================================
    test('Semantic 8 & 9: Account Balances and Global Accounting Equation (Assets = Liabilities + Equity)', () async {
      final now = DateTime.now();

      // Step A: Opening Balance ₹20,000 into Bank A
      final pOpen = [
        Posting(
          id: 'p_op_1',
          economicEventId: 'evt_open',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(2000000),
          createdAt: now,
        ),
        Posting(
          id: 'p_op_2',
          economicEventId: 'evt_open',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(2000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_open',
          canonicalType: CanonicalEventType.openingBalance,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Opening Balance',
          postings: pOpen,
          createdAt: now,
        ),
        postings: pOpen,
      );

      // Step B: Salary ₹30,000 into Bank A
      final pSal = [
        Posting(
          id: 'p_sal_1',
          economicEventId: 'evt_sal2',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(3000000),
          createdAt: now,
        ),
        Posting(
          id: 'p_sal_2',
          economicEventId: 'evt_sal2',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(3000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_sal2',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Salary',
          postings: pSal,
          createdAt: now,
        ),
        postings: pSal,
      );

      // Step C: Card Spend ₹5,000
      final pCard = [
        Posting(
          id: 'p_csp_1',
          economicEventId: 'evt_csp',
          accountId: 'acc_expense_gen',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(500000),
          createdAt: now,
        ),
        Posting(
          id: 'p_csp_2',
          economicEventId: 'evt_csp',
          accountId: 'acc_card',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(500000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_csp',
          canonicalType: CanonicalEventType.cardPurchase,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Card Purchase',
          postings: pCard,
          createdAt: now,
        ),
        postings: pCard,
      );

      // Check Balances:
      // Asset (Bank A): 20,000 + 30,000 = ₹50,000
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 5000000);
      // Liability (Card): ₹5,000 (credit normal)
      expect((await accountRepo.getDerivedBalance('acc_card')).minorUnits, 500000);
      // Equity (sysEquityOpening): ₹20,000 (credit normal)
      expect((await accountRepo.getDerivedBalance(TablesV24.sysEquityOpening)).minorUnits, 2000000);
      // Income (Salary): ₹30,000 (credit normal)
      expect((await accountRepo.getDerivedBalance('acc_salary')).minorUnits, 3000000);
      // Expense (General): ₹5,000 (debit normal)
      expect((await accountRepo.getDerivedBalance('acc_expense_gen')).minorUnits, 500000);

      // GLOBAL EQUATION: Assets = Liabilities + Total Equity
      final assets = await queryRepo.getTotalAssets(); // 50,000
      final liabilities = await queryRepo.getTotalLiabilities(); // 5,000
      final totalEquity = await queryRepo.getTotalEquity(); // Base(20k) + Retained(30k-5k = 25k) = 45k
      final netWorth = await queryRepo.getNetWorth(); // 50k - 5k = 45k

      expect(assets.minorUnits, 5000000);
      expect(liabilities.minorUnits, 500000);
      expect(totalEquity.minorUnits, 4500000);
      expect(netWorth.minorUnits, 4500000);

      // The Fundamental Accounting Equation holds exactly:
      expect(assets.minorUnits, liabilities.minorUnits + totalEquity.minorUnits);
      expect(netWorth.minorUnits, assets.minorUnits - liabilities.minorUnits);
    });

    // =========================================================================
    // SECTION 10: DRAFT ISOLATION (BEFORE & AFTER POSTING)
    // =========================================================================
    test('Semantic 10: Draft Isolation (Zero impact before posting, exactly once after posting)', () async {
      final now = DateTime.now();

      final pDraft = [
        Posting(
          id: 'p_iso_1',
          economicEventId: 'evt_iso',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(777000), // ₹7,770.00
          createdAt: now,
        ),
        Posting(
          id: 'p_iso_2',
          economicEventId: 'evt_iso',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(777000),
          createdAt: now,
        ),
      ];

      // 1. Stage Draft
      await eventRepo.createDraftEvent(
        EconomicEvent(
          id: 'evt_iso',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.draft,
          occurredAt: now,
          description: 'Staged Bonus',
          createdAt: now,
        ),
        postings: pDraft,
      );

      // Before posting: ZERO accounting impact across all metrics
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 0);
      expect((await accountRepo.getDerivedBalance('acc_salary')).minorUnits, 0);
      expect((await queryRepo.getTotalAssets()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getNetWorth()).minorUnits, 0);
      expect((await queryRepo.getCashFlow()).minorUnits, 0);

      // 2. Post Event
      await eventRepo.postEvent('evt_iso');

      // After posting: Appears exactly once
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 777000);
      expect((await accountRepo.getDerivedBalance('acc_salary')).minorUnits, 777000);
      expect((await queryRepo.getTotalAssets()).minorUnits, 777000);
      expect((await queryRepo.getTotalIncome()).minorUnits, 777000);
      expect((await queryRepo.getNetWorth()).minorUnits, 777000);
      expect((await queryRepo.getCashFlow()).minorUnits, 777000);
    });

    // =========================================================================
    // SECTION 11 & 12: SAFE-TO-SPEND & EARMARK SEMANTICS
    // =========================================================================
    test('Semantic 11 & 12: Earmark and Safe-to-Spend Semantics (0 ledger postings, balance unchanged, STS reduced)', () async {
      final now = DateTime.now();

      // Seed bank cash ₹50,000
      final pInit = [
        Posting(
          id: 'p_sts_1',
          economicEventId: 'evt_sts_init',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
        Posting(
          id: 'p_sts_2',
          economicEventId: 'evt_sts_init',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: now,
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_sts_init',
          canonicalType: CanonicalEventType.openingBalance,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Seed Bank',
          postings: pInit,
          createdAt: now,
        ),
        postings: pInit,
      );

      final initialPostingsCount = (await db.rawQuery('SELECT COUNT(*) AS c FROM ${TablesV24.postings};')).first['c'] as int;

      // Create Asset Earmark ₹15,000
      await earmarkRepo.setEarmark(AssetEarmark(
        id: 'em_vacation',
        goalId: 'goal_vacation',
        assetAccountId: 'acc_bank_a',
        earmarkedAmount: Money.fromMinorUnits(1500000),
        createdAt: now,
        updatedAt: now,
      ));

      // 1. Postings count must remain unchanged (0 postings generated)
      final postEarmarkCount = (await db.rawQuery('SELECT COUNT(*) AS c FROM ${TablesV24.postings};')).first['c'] as int;
      expect(postEarmarkCount, initialPostingsCount);

      // 2. Account balance and net worth must remain completely unchanged
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 5000000);
      expect((await queryRepo.getNetWorth()).minorUnits, 5000000);

      // 3. Safe-to-Spend must decrease by ₹15,000
      // Liquid = 50,000, Earmarks = 15,000 -> STS = 35,000
      final sts1 = await queryRepo.getSafeToSpend();
      expect(sts1.liquidAssets.minorUnits, 5000000);
      expect(sts1.activeEarmarks.minorUnits, 1500000);
      expect(sts1.safeToSpend.minorUnits, 3500000);
      expect(sts1.cashflowShortfall.minorUnits, 0);

      // 4. Ingestion boundary: Review Candidate rejection has 0 impact
      final candidate = ReviewCandidate(
        id: 'cand_temp',
        sourceType: 'sms',
        rawPayload: 'Spam SMS',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromMinorUnits(100000),
        confidenceScore: 0.20,
        status: ReviewCandidateStatus.pending,
        createdAt: now,
      );
      await reviewRepo.createCandidate(candidate);
      await reviewRepo.rejectCandidate('cand_temp');

      final stsAfterReject = await queryRepo.getSafeToSpend();
      expect(stsAfterReject.safeToSpend.minorUnits, 3500000);
      expect(stsAfterReject.cashflowShortfall.minorUnits, 0);
    });

    // =========================================================================
    // SECTION 13: OPENING BALANCE WITH PROVENANCE
    // =========================================================================
    test('Semantic 13: Opening Balance Invariant (EconomicEvent + sys_equity_opening + Provenance, no income/expense)', () async {
      final now = DateTime.now();
      final pOpen = [
        Posting(
          id: 'p_op_aud_1',
          economicEventId: 'evt_op_aud',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(2500000), // ₹25,000.00
          createdAt: now,
        ),
        Posting(
          id: 'p_op_aud_2',
          economicEventId: 'evt_op_aud',
          accountId: TablesV24.sysEquityOpening,
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(2500000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_op_aud',
          canonicalType: CanonicalEventType.openingBalance,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Opening Balance HDFC',
          postings: pOpen,
          createdAt: now,
        ),
        postings: pOpen,
      );

      // Provenance record
      await obrRepo.saveReconciliation(OpeningBalanceReconciliation(
        id: 'obr_aud_1',
        accountId: 'acc_bank_a',
        legacyReportedBalance: Money.fromMinorUnits(2500000),
        reconstructedBalanceFromTxns: Money.fromMinorUnits(0),
        reconciliationReason: 'Pre-existing bank account initial balance',
        provenanceSource: 'migration_v24_reconciliation',
        status: ReconciliationStatus.equityAdjustmentRequired,
        generatedEventId: 'evt_op_aud',
        createdAt: now,
      ));

      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 2500000);
      expect((await queryRepo.getTotalIncome()).minorUnits, 0);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 0);
      expect((await queryRepo.getTotalAssets()).minorUnits, 2500000);
      expect((await queryRepo.getNetWorth()).minorUnits, 2500000);

      final obr = await obrRepo.getReconciliationForAccount('acc_bank_a');
      expect(obr, isNotNull);
      expect(obr!.generatedEventId, 'evt_op_aud');
      expect(obr.adjustmentDelta.minorUnits, 2500000);
    });

    // =========================================================================
    // SECTION 14: POSTED IMMUTABILITY
    // =========================================================================
    test('Semantic 14: Posted Immutability Suite (All mutation attempts fail via triggers)', () async {
      final now = DateTime.now();
      final postings = [
        Posting(
          id: 'p_lock_1',
          economicEventId: 'evt_lock',
          accountId: 'acc_expense_gen',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(10000),
          createdAt: now,
        ),
        Posting(
          id: 'p_lock_2',
          economicEventId: 'evt_lock',
          accountId: 'acc_bank_a',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(10000),
          createdAt: now,
        ),
      ];

      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_lock',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Locked Record',
          postings: postings,
          createdAt: now,
        ),
        postings: postings,
      );

      // Attempt 1: Mutate canonical accounting fields of posted event
      expect(
        () => db.update(
          TablesV24.economicEvents,
          {'event_type': 'income'},
          where: 'id = ?',
          whereArgs: ['evt_lock'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Attempt 2: Delete posted event
      expect(
        () => db.delete(
          TablesV24.economicEvents,
          where: 'id = ?',
          whereArgs: ['evt_lock'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Attempt 3: Insert posting into posted event
      expect(
        () => db.insert(TablesV24.postings, {
          'id': 'p_lock_extra',
          'economic_event_id': 'evt_lock',
          'account_id': 'acc_bank_a',
          'sequence_number': 3,
          'direction': 'debit',
          'amount_minor_units': 100,
          'created_at': now.toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Attempt 4: Modify posting of posted event
      expect(
        () => db.update(
          TablesV24.postings,
          {'amount_minor_units': 99999},
          where: 'id = ?',
          whereArgs: ['p_lock_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Attempt 5: Delete posting of posted event
      expect(
        () => db.delete(
          TablesV24.postings,
          where: 'id = ?',
          whereArgs: ['p_lock_1'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Verify original accounting state is completely unchanged
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, -10000);
      expect((await accountRepo.getDerivedBalance('acc_expense_gen')).minorUnits, 10000);
    });

    // =========================================================================
    // SECTION 15: ATOMIC ROLLBACK INJECTION
    // =========================================================================
    test('Semantic 15: Atomic Rollback Injection (Zero partial event, posting, or balance on failure)', () async {
      final now = DateTime.now();

      // Failure case: Unbalanced postings (Dr 5000 != Cr 4000)
      final badPostings = [
        Posting(
          id: 'p_fail_1',
          economicEventId: 'evt_fail_inj',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000),
          createdAt: now,
        ),
        Posting(
          id: 'p_fail_2',
          economicEventId: 'evt_fail_inj',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(4000), // Deliberate imbalance
          createdAt: now,
        ),
      ];

      expect(
        () => eventRepo.createAndPostEvent(
          EconomicEvent(
            id: 'evt_fail_inj',
            canonicalType: CanonicalEventType.income,
            lifecycleStatus: EventLifecycle.draft,
            occurredAt: now,
            description: 'Failed Event',
            createdAt: now,
          ),
          postings: badPostings,
        ),
        throwsA(isA<AccountingInvariantException>()),
      );

      // Invariant: No partial event in economic_events
      expect(await eventRepo.getEvent('evt_fail_inj'), isNull);

      // Invariant: No orphan postings
      final orphanPostings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['evt_fail_inj'],
      );
      expect(orphanPostings, isEmpty);

      // Invariant: No altered account balances
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 0);
      expect((await accountRepo.getDerivedBalance('acc_salary')).minorUnits, 0);
    });

    // =========================================================================
    // SECTION 16: C2B PARITY VERIFICATION
    // =========================================================================
    test('Semantic 16: C2B Parity Check against Legacy Transition Parity', () async {
      final now = DateTime(2025, 1, 1).toIso8601String();

      // Reproduce C2B Fixture FX01 (Salary + Groceries) inside canonical repository
      // Salary ₹50,000
      final pSal = [
        Posting(
          id: 'p_fx01_sal1',
          economicEventId: 'evt_fx01_sal',
          accountId: 'acc_bank_a',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(5000000), // ₹50,000.00
          createdAt: DateTime.parse(now),
        ),
        Posting(
          id: 'p_fx01_sal2',
          economicEventId: 'evt_fx01_sal',
          accountId: 'acc_salary',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(5000000),
          createdAt: DateTime.parse(now),
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_fx01_sal',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: DateTime.parse(now),
          description: 'January Salary',
          postings: pSal,
          createdAt: DateTime.parse(now),
        ),
        postings: pSal,
      );

      // Groceries ₹5,000
      final pGroc = [
        Posting(
          id: 'p_fx01_groc1',
          economicEventId: 'evt_fx01_groc',
          accountId: 'acc_expense_gen',
          direction: PostingDirection.debit,
          amount: Money.fromMinorUnits(500000), // ₹5,000.00
          createdAt: DateTime.parse(now),
        ),
        Posting(
          id: 'p_fx01_groc2',
          economicEventId: 'evt_fx01_groc',
          accountId: 'acc_bank_a',
          direction: PostingDirection.credit,
          amount: Money.fromMinorUnits(500000),
          createdAt: DateTime.parse(now),
        ),
      ];
      await eventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_fx01_groc',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: DateTime.parse(now),
          description: 'Groceries',
          postings: pGroc,
          createdAt: DateTime.parse(now),
        ),
        postings: pGroc,
      );

      // Parity assertions:
      expect((await accountRepo.getDerivedBalance('acc_bank_a')).minorUnits, 4500000); // ₹45,000.00
      expect((await queryRepo.getTotalAssets()).minorUnits, 4500000);
      expect((await queryRepo.getTotalLiabilities()).minorUnits, 0);
      expect((await queryRepo.getTotalIncome()).minorUnits, 5000000);
      expect((await queryRepo.getTotalExpenses()).minorUnits, 500000);
      expect((await queryRepo.getNetWorth()).minorUnits, 4500000);
      expect((await queryRepo.getCashFlow()).minorUnits, 4500000);

      // Counts: 2 events, 4 postings
      final eventCount = (await db.rawQuery('SELECT COUNT(*) AS c FROM ${TablesV24.economicEvents};')).first['c'] as int;
      final postingCount = (await db.rawQuery('SELECT COUNT(*) AS c FROM ${TablesV24.postings};')).first['c'] as int;
      expect(eventCount, 2);
      expect(postingCount, 4);
    });
  });
}
