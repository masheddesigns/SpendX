import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/goal_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_earmark_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/credit_transaction.dart';
import 'package:spend_x/models/goal.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Milestone C4-0: Canonical Read Boundary & Application Read Inventory Test Suite', () {
    late Database db;
    late AccountRepo accountRepo;
    late CreditRepo creditRepo;
    late LoanRepo loanRepo;
    late GoalRepo goalRepo;
    late CanonicalEarmarkRepository earmarkRepo;
    late CanonicalReviewRepository reviewRepo;
    late CanonicalAccountRepository canonicalAccountRepo;
    late CanonicalEventRepository canonicalEventRepo;
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

      canonicalAccountRepo = CanonicalAccountRepository(executor: db);
      canonicalEventRepo = CanonicalEventRepository(executor: db);
      earmarkRepo = CanonicalEarmarkRepository(executor: db);
      reviewRepo = CanonicalReviewRepository(executor: db);
      financialQueryRepo = CanonicalFinancialQueryRepository(executor: db);

      accountRepo = AccountRepo(executor: db);
      creditRepo = CreditRepo(executor: db);
      loanRepo = LoanRepo(executor: db);
      goalRepo = GoalRepo(executor: db, earmarkRepo: earmarkRepo);
    });

    tearDown(() async {
      await db.close();
    });

    // -------------------------------------------------------------------------
    // Test 1: Account balance comes from canonical postings
    // -------------------------------------------------------------------------
    test('1. Account balance comes from canonical postings (CanonicalAccountRepository.getDerivedBalance)', () async {
      final now = DateTime.now();
      // Insert bank account via AccountRepo
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_bank_test1',
        name: 'HDFC Savings',
        bank: 'HDFC',
        balance: 10000.0, // Initial balance creates opening balance event
      ));

      // Post an income event: ₹5,000 credit salary, debit bank
      final incomePostings = [
        Posting(
          id: 'p_t1_inc_asset',
          economicEventId: 'evt_t1_inc',
          accountId: 'acc_bank_test1',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(5000.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_t1_inc_rev',
          economicEventId: 'evt_t1_inc',
          accountId: TablesV24.sysIncMisc,
          direction: PostingDirection.credit,
          amount: Money.fromRupees(5000.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_t1_inc',
          canonicalType: CanonicalEventType.income,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Salary credited',
          postings: incomePostings,
          createdAt: now,
        ),
        postings: incomePostings,
      );

      // Verify derived balance strictly equals ₹10,000 + ₹5,000 = ₹15,000
      final derivedBalance = await canonicalAccountRepo.getDerivedBalance('acc_bank_test1');
      expect(derivedBalance.toRupees, equals(15000.0));

      // Verify AccountRepo.getById reads derived balance canonically
      final account = await accountRepo.getById('acc_bank_test1');
      expect(account, isNotNull);
      expect(account!.balance, equals(15000.0));
    });

    // -------------------------------------------------------------------------
    // Test 2: Credit outstanding comes from canonical liability postings
    // -------------------------------------------------------------------------
    test('2. Credit outstanding comes from canonical liability postings', () async {
      final now = DateTime.now();
      final card = CreditCard(
        id: 'card_test2',
        name: 'SBI Prime Card',
        bank: 'SBI',
        last4: '1234',
        limitAmount: 100000.0,
        usedAmount: 0.0,
      );
      await creditRepo.insert(card);

      // Charge an expense of ₹7,500: Dr Expense, Cr Card Liability
      final expensePostings = [
        Posting(
          id: 'p_t2_exp',
          economicEventId: 'evt_t2_charge',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromRupees(7500.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_t2_card_liab',
          economicEventId: 'evt_t2_charge',
          accountId: 'card_test2',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(7500.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_t2_charge',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Dining expense',
          postings: expensePostings,
          createdAt: now,
        ),
        postings: expensePostings,
      );

      // Derived liability balance for credit card is Credit - Debit = ₹7,500
      final liability = await canonicalAccountRepo.getDerivedBalance('card_test2');
      expect(liability.toRupees, equals(7500.0));

      // CreditRepo.getCard derives usedAmount dynamically from postings
      final fetchedCard = await creditRepo.getCard('card_test2');
      expect(fetchedCard, isNotNull);
      expect(fetchedCard!.usedAmount, equals(7500.0));
    });

    // -------------------------------------------------------------------------
    // Test 3: Loan balance comes from canonical liability postings
    // -------------------------------------------------------------------------
    test('3. Loan balance comes from canonical liability postings', () async {
      // Create funding bank
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_fund_loan',
        name: 'Funding Bank',
        bank: 'Axis',
        balance: 50000.0,
      ));

      final loan = Loan(
        id: 'loan_test3',
        name: 'Auto Loan',
        bank: 'HDFC',
        total: 50000.0,
        paidAmount: 10000.0, // initial payment
        monthlyInstallment: 5000.0,
        tenureMonths: 10,
        interestRate: 0.0,
        dueDay: 10,
        loanStatus: 'active',
        startDate: DateTime.now(),
      );
      await loanRepo.insertLoan(loan);

      // Remaining liability = Total (₹50,000) - Paid (₹10,000) = ₹40,000
      final derivedLiability = await canonicalAccountRepo.getDerivedBalance('loan_test3');
      expect(derivedLiability.toRupees, equals(40000.0));

      final fetchedLoan = await loanRepo.getLoanById('loan_test3');
      expect(fetchedLoan, isNotNull);
      expect(fetchedLoan!.paidAmount, equals(10000.0));
      expect(fetchedLoan.total - fetchedLoan.paidAmount, equals(40000.0));
    });

    // -------------------------------------------------------------------------
    // Test 4: Goal progress comes from active earmarks
    // -------------------------------------------------------------------------
    test('4. Goal progress comes from active earmarks (CanonicalEarmarkRepository.getTotalEarmarkedForGoal)', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_goal_asset',
        name: 'Liquid Savings',
        bank: 'ICICI',
        balance: 20000.0,
      ));

      final goal = Goal(
        id: 'goal_test4',
        title: 'New Laptop',
        type: GoalType.savings,
        targetAmount: 80000.0,
        currentAmount: 0.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 90)),
      );
      await goalRepo.insert(goal);

      // Create an earmark of ₹35,000
      final now = DateTime.now();
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_test4',
        goalId: 'goal_test4',
        assetAccountId: 'acc_goal_asset',
        earmarkedAmount: Money.fromRupees(35000.0),
        createdAt: now,
        updatedAt: now,
      ));

      final totalEarmarked = await earmarkRepo.getTotalEarmarkedForGoal('goal_test4');
      expect(totalEarmarked.toRupees, equals(35000.0));

      final fetchedGoal = await goalRepo.getGoalById('goal_test4');
      expect(fetchedGoal, isNotNull);
      expect(fetchedGoal!.currentAmount, equals(35000.0));
    });

    // -------------------------------------------------------------------------
    // Test 5: Legacy mutable balance columns cannot alter canonical financial query results
    // -------------------------------------------------------------------------
    test('5. Legacy mutable balance columns (bank_accounts.balance, credit_cards.used_amount, loans.paid_amount) cannot alter canonical financial query results', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_bank_test5',
        name: 'Test Bank',
        bank: 'SBI',
        balance: 20000.0,
      ));

      final initialAssets = await financialQueryRepo.getTotalAssets();
      expect(initialAssets.toRupees, equals(20000.0));

      // Attempt direct SQL hack on legacy mutable column
      await db.rawUpdate('UPDATE ${Tables.bankAccounts} SET balance = 999999.0 WHERE id = ?', ['acc_bank_test5']);

      // Canonical financial query MUST remain 20000.0
      final assetsAfterHack = await financialQueryRepo.getTotalAssets();
      expect(assetsAfterHack.toRupees, equals(20000.0));
    });

    // -------------------------------------------------------------------------
    // Test 6: goals.current_amount direct update cannot alter goal financial progress
    // -------------------------------------------------------------------------
    test('6. goals.current_amount direct update cannot alter goal financial progress', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_goal_bank6',
        name: 'Goal Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));

      final goal = Goal(
        id: 'goal_test6',
        title: 'Emergency Fund',
        type: GoalType.savings,
        targetAmount: 50000.0,
        currentAmount: 0.0,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 60)),
      );
      await goalRepo.insert(goal);

      final now = DateTime.now();
      await goalRepo.createEarmark(AssetEarmark(
        id: 'em_test6',
        goalId: 'goal_test6',
        assetAccountId: 'acc_goal_bank6',
        earmarkedAmount: Money.fromRupees(5000.0),
        createdAt: now,
        updatedAt: now,
      ));

      // Rogue SQL update on legacy goals.current_amount
      await db.rawUpdate('UPDATE ${Tables.goals} SET current_amount = 49999.0 WHERE id = ?', ['goal_test6']);

      // GoalRepo.getGoalById reads from earmarks, ignoring rogue value
      final fetched = await goalRepo.getGoalById('goal_test6');
      expect(fetched!.currentAmount, equals(5000.0));
      final canonicalProgress = await earmarkRepo.getTotalEarmarkedForGoal('goal_test6');
      expect(canonicalProgress.toRupees, equals(5000.0));
    });

    // -------------------------------------------------------------------------
    // Test 7: Soft-deleted legacy transactions do not become financial truth
    // -------------------------------------------------------------------------
    test('7. Soft-deleted legacy transactions do not become financial truth', () async {
      // Insert legacy transaction marked deleted or soft-deleted
      await db.insert(Tables.transactions, {
        'id': 'tx_legacy_deleted',
        'notes': 'Ghost Expense',
        'amount': 8888.0,
        'type': 'expense',
        'account_id': 'acc_dummy',
        'date': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'is_deleted': 1,
      });

      // Canonical financial query strictly inspects postings table
      final totalExpenses = await financialQueryRepo.getTotalExpenses();
      expect(totalExpenses.minorUnits, equals(0));
    });

    // -------------------------------------------------------------------------
    // Test 8: Card payments do not become expenses (Dr Card Liability / Cr Bank Asset)
    // -------------------------------------------------------------------------
    test('8. Card payments do not become expenses (Dr Card Liability / Cr Bank Asset)', () async {
      final now = DateTime.now();
      // Setup bank and card
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_bank_pay',
        name: 'Bank Pay',
        bank: 'SBI',
        balance: 20000.0,
      ));
      final card = CreditCard(
        id: 'card_pay',
        name: 'Pay Card',
        bank: 'SBI',
        last4: '9999',
        limitAmount: 50000.0,
        usedAmount: 5000.0,
      );
      await creditRepo.insert(card);

      final initialExpenses = await financialQueryRepo.getTotalExpenses();
      expect(initialExpenses.minorUnits, equals(0));

      // Record card bill payment: Dr Card Liability ₹3,000, Cr Bank Asset ₹3,000
      final payment = CreditTransaction(
        id: 'tx_card_bill_pay',
        cardId: 'card_pay',
        amount: 3000.0,
        date: now,
        category: 'Payment',
        note: 'Card Bill Payment',
        type: 'payment',
        status: 'active',
        categoryId: 'acc_bank_pay',
      );
      await creditRepo.insertTransaction(payment);

      // Verify total expenses remains 0!
      final totalExpenses = await financialQueryRepo.getTotalExpenses();
      expect(totalExpenses.minorUnits, equals(0));

      // Verify card liability decreased from 5,000 to 2,000
      final updatedCard = await creditRepo.getCard('card_pay');
      expect(updatedCard!.usedAmount, equals(2000.0));

      // Verify bank balance decreased from 20,000 to 17,000
      final updatedBank = await accountRepo.getById('acc_bank_pay');
      expect(updatedBank!.balance, equals(17000.0));
    });

    // -------------------------------------------------------------------------
    // Test 9: Transfers do not affect net worth (Delta NetWorth = 0)
    // -------------------------------------------------------------------------
    test('9. Transfers do not affect net worth (Delta NetWorth = 0)', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_from',
        name: 'From Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_to',
        name: 'To Bank',
        bank: 'HDFC',
        balance: 5000.0,
      ));

      final netWorthBefore = await financialQueryRepo.getNetWorth();
      expect(netWorthBefore.toRupees, equals(15000.0));

      // Transfer ₹4,000 from acc_from to acc_to
      final transferPostings = [
        Posting(
          id: 'p_tx_out',
          economicEventId: 'evt_xfer',
          accountId: 'acc_from',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(4000.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_tx_in',
          economicEventId: 'evt_xfer',
          accountId: 'acc_to',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(4000.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_xfer',
          canonicalType: CanonicalEventType.transfer,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Inter-bank transfer',
          postings: transferPostings,
          createdAt: now,
        ),
        postings: transferPostings,
      );

      final netWorthAfter = await financialQueryRepo.getNetWorth();
      expect(netWorthAfter.toRupees, equals(15000.0));
      expect(netWorthAfter - netWorthBefore, equals(Money.zero));

      // Verify total expenses and total income are both 0
      final exp = await financialQueryRepo.getTotalExpenses();
      final inc = await financialQueryRepo.getTotalIncome();
      expect(exp.minorUnits, equals(0));
      expect(inc.minorUnits, equals(0));
    });

    // -------------------------------------------------------------------------
    // Test 10: Loan principal repayment does not become expense
    // -------------------------------------------------------------------------
    test('10. Loan principal repayment does not become expense', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_loan_payer',
        name: 'Payer Bank',
        bank: 'SBI',
        balance: 30000.0,
      ));

      final loan = Loan(
        id: 'loan_repay_test',
        name: 'Personal Loan',
        bank: 'SBI',
        total: 20000.0,
        paidAmount: 0.0,
        monthlyInstallment: 2000.0,
        tenureMonths: 10,
        interestRate: 0.0,
        dueDay: 1,
        loanStatus: 'active',
        startDate: now,
      );
      await loanRepo.insertLoan(loan);

      // Principal repayment: Dr Loan Liability ₹2,000, Cr Bank Asset ₹2,000
      final principalPostings = [
        Posting(
          id: 'p_loan_pr_dr',
          economicEventId: 'evt_loan_pr',
          accountId: 'loan_repay_test',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(2000.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_bank_pr_cr',
          economicEventId: 'evt_loan_pr',
          accountId: 'acc_loan_payer',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(2000.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_loan_pr',
          canonicalType: CanonicalEventType.loanRepayment,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Loan principal repayment',
          postings: principalPostings,
          createdAt: now,
        ),
        postings: principalPostings,
      );

      final totalExpenses = await financialQueryRepo.getTotalExpenses();
      expect(totalExpenses.minorUnits, equals(0));
    });

    // -------------------------------------------------------------------------
    // Test 11: Loan interest payment becomes expense
    // -------------------------------------------------------------------------
    test('11. Loan interest payment becomes expense', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_interest_bank',
        name: 'Bank Interest',
        bank: 'SBI',
        balance: 10000.0,
      ));

      // Interest payment: Dr sys_exp_interest ₹350, Cr Bank Asset ₹350
      final interestPostings = [
        Posting(
          id: 'p_int_exp_dr',
          economicEventId: 'evt_loan_int',
          accountId: TablesV24.sysExpInterest,
          direction: PostingDirection.debit,
          amount: Money.fromRupees(350.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_int_bank_cr',
          economicEventId: 'evt_loan_int',
          accountId: 'acc_interest_bank',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(350.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_loan_int',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Loan Interest Component',
          postings: interestPostings,
          createdAt: now,
        ),
        postings: interestPostings,
      );

      final totalExpenses = await financialQueryRepo.getTotalExpenses();
      expect(totalExpenses.toRupees, equals(350.0));
    });

    // -------------------------------------------------------------------------
    // Test 12: Refund semantics remain correct (contra-expense, zero income)
    // -------------------------------------------------------------------------
    test('12. Refund semantics remain correct (contra-expense, zero income)', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_refund_bank',
        name: 'Refund Bank',
        bank: 'SBI',
        balance: 5000.0,
      ));

      // Initial purchase of ₹1,000: Dr sys_exp_misc, Cr Bank
      final purchasePostings = [
        Posting(
          id: 'p_ref_pur_dr',
          economicEventId: 'evt_ref_pur',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromRupees(1000.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_ref_pur_cr',
          economicEventId: 'evt_ref_pur',
          accountId: 'acc_refund_bank',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(1000.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_ref_pur',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Original purchase',
          postings: purchasePostings,
          createdAt: now,
        ),
        postings: purchasePostings,
      );

      expect((await financialQueryRepo.getTotalExpenses()).toRupees, equals(1000.0));
      expect((await financialQueryRepo.getTotalIncome()).minorUnits, equals(0));

      // Process refund of ₹400: Dr Bank Asset ₹400, Cr sys_exp_misc ₹400
      final refundPostings = [
        Posting(
          id: 'p_ref_asset_dr',
          economicEventId: 'evt_refund',
          accountId: 'acc_refund_bank',
          direction: PostingDirection.debit,
          amount: Money.fromRupees(400.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_ref_exp_cr',
          economicEventId: 'evt_refund',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.credit,
          amount: Money.fromRupees(400.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_refund',
          canonicalType: CanonicalEventType.refund,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Partial refund',
          postings: refundPostings,
          createdAt: now,
        ),
        postings: refundPostings,
      );

      // Expenses strictly reduced by contra-expense (₹1000 - ₹400 = ₹600)
      final netExpenses = await financialQueryRepo.getTotalExpenses();
      expect(netExpenses.toRupees, equals(600.0));

      // Total Income strictly remains 0 (refund is NOT income)
      final totalIncome = await financialQueryRepo.getTotalIncome();
      expect(totalIncome.minorUnits, equals(0));
    });

    // -------------------------------------------------------------------------
    // Test 13: Opening balance remains part of canonical state (sys_equity_opening)
    // -------------------------------------------------------------------------
    test('13. Opening balance remains part of canonical state (sys_equity_opening)', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_opening_test',
        name: 'Opening Bank',
        bank: 'SBI',
        balance: 15000.0,
      ));

      final baseEquity = await financialQueryRepo.getBaseEquity();
      expect(baseEquity.toRupees, equals(15000.0));

      final totalEquity = await financialQueryRepo.getTotalEquity();
      expect(totalEquity.toRupees, equals(15000.0));

      final netWorth = await financialQueryRepo.getNetWorth();
      expect(netWorth.toRupees, equals(15000.0));

      // Opening balance does NOT enter income
      final totalIncome = await financialQueryRepo.getTotalIncome();
      expect(totalIncome.minorUnits, equals(0));
    });

    // -------------------------------------------------------------------------
    // Test 14: Review candidates do not create accounting truth
    // -------------------------------------------------------------------------
    test('14. Review candidates do not create accounting truth', () async {
      final candidate = ReviewCandidate(
        id: 'rev_test14',
        sourceType: 'sms',
        rawPayload: 'Debited 5000 for Flight',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(5000.0),
        confidenceScore: 0.98,
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      );
      await reviewRepo.createCandidate(candidate);

      // Postings count must remain 0
      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);

      // Financial queries must show ₹0
      final expenses = await financialQueryRepo.getTotalExpenses();
      expect(expenses.minorUnits, equals(0));
      final assets = await financialQueryRepo.getTotalAssets();
      expect(assets.minorUnits, equals(0));
    });

    // -------------------------------------------------------------------------
    // Test 15: High-confidence pending debit reduces Safe-to-Spend
    // -------------------------------------------------------------------------
    test('15. High-confidence pending debit reduces Safe-to-Spend', () async {
      // Setup liquid bank with ₹50,000
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_liquid_safe',
        name: 'Liquid Wallet',
        bank: 'SBI',
        balance: 50000.0,
      ));

      // Base safe-to-spend: liquid = 50,000, earmarks = 0, commitments = 10,000
      final baseCalc = await financialQueryRepo.getSafeToSpend(
        knownCommitments14d: Money.fromRupees(10000.0),
      );
      expect(baseCalc.safeToSpend.toRupees, equals(40000.0));

      // With high-confidence pending debit of ₹5,000 (e.g. uncleared POS auth)
      final calcWithPending = await financialQueryRepo.getSafeToSpend(
        knownCommitments14d: Money.fromRupees(10000.0),
        highConfidencePendingDebits: Money.fromRupees(5000.0),
      );
      expect(calcWithPending.discretionaryCash.toRupees, equals(35000.0));
      expect(calcWithPending.safeToSpend.toRupees, equals(35000.0));
      expect(calcWithPending.cashflowShortfall.minorUnits, equals(0));
    });

    // -------------------------------------------------------------------------
    // Test 16: Low-confidence candidates do not alter Safe-to-Spend
    // -------------------------------------------------------------------------
    test('16. Low-confidence candidates do not alter Safe-to-Spend', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_liquid_low_conf',
        name: 'Liquid Bank',
        bank: 'SBI',
        balance: 20000.0,
      ));

      // Ingest a low-confidence candidate (e.g. spam/otp text)
      await reviewRepo.createCandidate(ReviewCandidate(
        id: 'rev_low_conf',
        sourceType: 'sms',
        rawPayload: 'Possible charge 8000',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(8000.0),
        confidenceScore: 0.35, // low confidence!
        status: ReviewCandidateStatus.pending,
        createdAt: DateTime.now(),
      ));

      // Only candidates with confidence >= 0.90 are classified as high-confidence pending debits
      final candidates = await reviewRepo.listCandidates(status: ReviewCandidateStatus.pending);
      final highConfidenceTotal = candidates
          .where((c) => c.confidenceScore >= 0.90)
          .fold<Money>(Money.zero, (sum, c) => sum + c.suggestedAmount);

      final safeCalc = await financialQueryRepo.getSafeToSpend(
        highConfidencePendingDebits: highConfidenceTotal,
      );

      // Safe-to-spend is completely unaffected by low-confidence candidate
      expect(safeCalc.safeToSpend.toRupees, equals(20000.0));
    });

    // -------------------------------------------------------------------------
    // Test 17: Suspected duplicates do not alter accounting truth
    // -------------------------------------------------------------------------
    test('17. Suspected duplicates do not alter accounting truth', () async {
      final now = DateTime.now();
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_dedup_bank',
        name: 'Dedup Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));

      // Original posted expense of ₹500
      final expPostings = [
        Posting(
          id: 'p_orig_dr',
          economicEventId: 'evt_orig_tx',
          accountId: TablesV24.sysExpMisc,
          direction: PostingDirection.debit,
          amount: Money.fromRupees(500.0),
          createdAt: now,
        ),
        Posting(
          id: 'p_orig_cr',
          economicEventId: 'evt_orig_tx',
          accountId: 'acc_dedup_bank',
          direction: PostingDirection.credit,
          amount: Money.fromRupees(500.0),
          createdAt: now,
        ),
      ];
      await canonicalEventRepo.createAndPostEvent(
        EconomicEvent(
          id: 'evt_orig_tx',
          canonicalType: CanonicalEventType.expense,
          lifecycleStatus: EventLifecycle.posted,
          occurredAt: now,
          description: 'Coffee payment',
          postings: expPostings,
          createdAt: now,
        ),
        postings: expPostings,
      );

      // Ingest duplicate SMS as review candidate flagged rejected
      await reviewRepo.createCandidate(ReviewCandidate(
        id: 'rev_dup_sms',
        sourceType: 'sms',
        rawPayload: 'Debited 500 at Coffee Shop',
        suggestedEventType: CanonicalEventType.expense,
        suggestedAmount: Money.fromRupees(500.0),
        confidenceScore: 0.95,
        status: ReviewCandidateStatus.rejected, // rejected as suspected duplicate
        createdAt: now,
      ));

      // Total expenses must strictly reflect only the single original event
      final expenses = await financialQueryRepo.getTotalExpenses();
      expect(expenses.toRupees, equals(500.0));
    });

    // -------------------------------------------------------------------------
    // Test 18: Canonical queries remain stable when compatibility projections are stale
    // -------------------------------------------------------------------------
    test('18. Canonical queries remain stable when compatibility projections are stale', () async {
      await accountRepo.insertAccount(BankAccount(
        id: 'acc_stale_compat',
        name: 'Stale Bank',
        bank: 'SBI',
        balance: 10000.0,
      ));

      // Deliberately corrupt or empty legacy tables
      await db.delete(Tables.transactions);
      await db.delete(Tables.ledgerTransactions);

      // Canonical financial query repository and canonical account repo remain 100% accurate
      final derivedBalance = await canonicalAccountRepo.getDerivedBalance('acc_stale_compat');
      expect(derivedBalance.toRupees, equals(10000.0));

      final totalAssets = await financialQueryRepo.getTotalAssets();
      expect(totalAssets.toRupees, equals(10000.0));

      final netWorth = await financialQueryRepo.getNetWorth();
      expect(netWorth.toRupees, equals(10000.0));
    });
  });
}
