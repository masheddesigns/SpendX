import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/domain/finance/finance.dart';

void main() {
  group('EventSemantics Domain Accounting Rule Tests', () {
    final now = DateTime(2026, 10, 3, 14, 0);

    test('Expense: Dr Expense / Cr Asset', () {
      final event = EventSemantics.createExpense(
        eventId: 'evt_exp_1',
        assetAccountId: 'ast_bank',
        expenseAccountId: 'exp_groceries',
        amount: Money.fromRupees(1500),
        occurredAt: now,
        createdAt: now,
      );

      expect(event.lifecycleStatus, EventLifecycle.posted);
      expect(event.canonicalType, CanonicalEventType.expense);
      expect(event.postings.length, 2);

      final dr = event.postings.firstWhere((p) => p.direction.isDebit);
      final cr = event.postings.firstWhere((p) => p.direction.isCredit);

      expect(dr.accountId, 'exp_groceries');
      expect(dr.amount, Money.fromRupees(1500));
      expect(cr.accountId, 'ast_bank');
      expect(cr.amount, Money.fromRupees(1500));
    });

    test('Transfer: Dr Destination Asset / Cr Source Asset (Asset Category Net Zero)', () {
      final event = EventSemantics.createTransfer(
        eventId: 'evt_tr_1',
        sourceAssetAccountId: 'ast_hdfc',
        destinationAssetAccountId: 'ast_sbi',
        amount: Money.fromRupees(10000),
        occurredAt: now,
        createdAt: now,
      );

      expect(event.canonicalType, CanonicalEventType.transfer);
      expect(event.postings.length, 2);

      final dr = event.postings.firstWhere((p) => p.direction.isDebit);
      final cr = event.postings.firstWhere((p) => p.direction.isCredit);

      expect(dr.accountId, 'ast_sbi');
      expect(cr.accountId, 'ast_hdfc');
      expect(dr.amount, Money.fromRupees(10000));
      expect(cr.amount, Money.fromRupees(10000));
    });

    test('Transfer: Same source and destination throws AccountingInvariantException', () {
      expect(
        () => EventSemantics.createTransfer(
          eventId: 'evt_tr_bad',
          sourceAssetAccountId: 'ast_hdfc',
          destinationAssetAccountId: 'ast_hdfc',
          amount: Money.fromRupees(1000),
          occurredAt: now,
          createdAt: now,
        ),
        throwsA(isA<AccountingInvariantException>()),
      );
    });

    test('Card Purchase: Dr Expense / Cr Card Liability', () {
      final event = EventSemantics.createCardPurchase(
        eventId: 'evt_cc_buy',
        cardLiabilityAccountId: 'liab_cc_hdfc',
        expenseAccountId: 'exp_electronics',
        amount: Money.fromRupees(25000),
        occurredAt: now,
        createdAt: now,
      );

      expect(event.canonicalType, CanonicalEventType.cardPurchase);
      final dr = event.postings.firstWhere((p) => p.direction.isDebit);
      final cr = event.postings.firstWhere((p) => p.direction.isCredit);

      expect(dr.accountId, 'exp_electronics');
      expect(cr.accountId, 'liab_cc_hdfc');
      expect(dr.amount, Money.fromRupees(25000));
    });

    test('Card Payment: Dr Card Liability / Cr Bank Asset (ZERO EXPENSE POSTINGS)', () {
      final event = EventSemantics.createCardPayment(
        eventId: 'evt_cc_pay',
        bankAssetAccountId: 'ast_bank_sbi',
        cardLiabilityAccountId: 'liab_cc_hdfc',
        amount: Money.fromRupees(25000),
        occurredAt: now,
        createdAt: now,
      );

      expect(event.canonicalType, CanonicalEventType.cardPayment);
      expect(event.postings.length, 2);

      final dr = event.postings.firstWhere((p) => p.direction.isDebit);
      final cr = event.postings.firstWhere((p) => p.direction.isCredit);

      expect(dr.accountId, 'liab_cc_hdfc'); // Reduces card liability
      expect(cr.accountId, 'ast_bank_sbi');  // Reduces bank cash
      expect(dr.amount, Money.fromRupees(25000));
      expect(cr.amount, Money.fromRupees(25000));

      // CRITICAL VERIFICATION: No postings touch expense!
      for (final p in event.postings) {
        expect(p.accountId.startsWith('exp_'), isFalse);
      }
    });

    test('Refund: Dr Asset / Cr Expense (Contra-expense, ZERO INCOME POSTINGS)', () {
      final event = EventSemantics.createRefund(
        eventId: 'evt_ref_1',
        assetAccountId: 'ast_bank',
        expenseAccountId: 'exp_shopping',
        amount: Money.fromRupees(2000),
        occurredAt: now,
        createdAt: now,
        originalEventId: 'evt_original_shopping',
      );

      expect(event.canonicalType, CanonicalEventType.refund);
      final dr = event.postings.firstWhere((p) => p.direction.isDebit);
      final cr = event.postings.firstWhere((p) => p.direction.isCredit);

      expect(dr.accountId, 'ast_bank'); // Cash received back
      expect(cr.accountId, 'exp_shopping'); // Offsets expense
      expect(event.metadata['original_event_id'], 'evt_original_shopping');

      // CRITICAL: Refund never becomes income
      for (final p in event.postings) {
        expect(p.accountId.startsWith('inc_'), isFalse);
      }
    });

    test('Loan Repayment: Dr Principal + Dr Interest / Cr Bank (3 Legs Balanced)', () {
      final event = EventSemantics.createLoanRepayment(
        eventId: 'evt_loan_repay',
        bankAssetAccountId: 'ast_bank',
        loanLiabilityAccountId: 'liab_loan_car',
        interestExpenseAccountId: 'exp_interest_car',
        principalAmount: Money.fromRupees(15000),
        interestAmount: Money.fromRupees(3500),
        occurredAt: now,
        createdAt: now,
      );

      expect(event.canonicalType, CanonicalEventType.loanRepayment);
      expect(event.postings.length, 3);

      final debits = event.postings.where((p) => p.direction.isDebit).toList();
      final credit = event.postings.firstWhere((p) => p.direction.isCredit);

      expect(debits.length, 2);
      final principalLeg = debits.firstWhere((p) => p.accountId == 'liab_loan_car');
      final interestLeg = debits.firstWhere((p) => p.accountId == 'exp_interest_car');

      expect(principalLeg.amount, Money.fromRupees(15000));
      expect(interestLeg.amount, Money.fromRupees(3500));
      expect(credit.accountId, 'ast_bank');
      expect(credit.amount, Money.fromRupees(18500)); // 15000 + 3500
    });

    test('Opening Balance: Dr Asset / Cr Equity for positive bank balance', () {
      final event = EventSemantics.createOpeningBalance(
        eventId: 'evt_open_bank',
        targetAccountId: 'ast_bank_icici',
        accountType: AccountType.asset,
        openingBalanceEquityAccountId: 'eq_opening_balance',
        balance: Money.fromRupees(50000),
        occurredAt: now,
        createdAt: now,
        reason: 'Initial bank balance at onboarding',
        provenanceSource: 'onboarding_screen',
      );

      expect(event.canonicalType, CanonicalEventType.openingBalance);
      final dr = event.postings.firstWhere((p) => p.direction.isDebit);
      final cr = event.postings.firstWhere((p) => p.direction.isCredit);

      expect(dr.accountId, 'ast_bank_icici');
      expect(cr.accountId, 'eq_opening_balance');
      expect(event.metadata['reconciliation_reason'], 'Initial bank balance at onboarding');
      expect(event.metadata['provenance_source'], 'onboarding_screen');
    });

    test('Draft -> Posted lifecycle asserts balance and prevents post-commit mutation', () {
      final draft = EconomicEvent.draft(
        id: 'evt_draft_1',
        canonicalType: CanonicalEventType.expense,
        occurredAt: now,
        createdAt: now,
      );
      expect(draft.lifecycleStatus, EventLifecycle.draft);
      expect(draft.postings.isEmpty, isTrue);

      // Attempting to post without postings throws
      expect(() => draft.post(), throwsA(isA<AccountingInvariantException>()));

      // Attach balanced postings
      final withPostings = draft.withPostings([
        Posting.debit(
          id: 'p1',
          economicEventId: 'evt_draft_1',
          accountId: 'exp_food',
          amount: Money.fromRupees(200),
          createdAt: now,
        ),
        Posting.credit(
          id: 'p2',
          economicEventId: 'evt_draft_1',
          accountId: 'ast_cash',
          amount: Money.fromRupees(200),
          createdAt: now,
        ),
      ]);

      final postedEvent = withPostings.post();
      expect(postedEvent.lifecycleStatus, EventLifecycle.posted);

      // Cannot attach new postings to posted event
      expect(
        () => postedEvent.withPostings([]),
        throwsA(isA<AccountingInvariantException>()),
      );
    });
  });
}
