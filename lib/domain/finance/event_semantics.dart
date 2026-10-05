import 'account_type.dart';
import 'economic_event.dart';
import 'exceptions.dart';
import 'money.dart';
import 'posting.dart';

/// Pure domain factories and typed semantics for canonical financial events.
///
/// These factories enforce strict double-entry accounting rules at the domain layer,
/// preventing illegal anti-patterns such as:
/// - Credit card payment recorded as an Expense
/// - Inter-account transfer recorded as Income/Expense
/// - Loan principal repayment recorded as an Expense
/// - Refund recorded as ordinary Income
/// - Unbalanced or single-legged transactions
abstract final class EventSemantics {
  /// Creates a canonical **Expense** event.
  ///
  /// Standard Accounting:
  /// - DEBIT: Expense Account (increases expense)
  /// - CREDIT: Asset Account (decreases cash/bank)
  static EconomicEvent createExpense({
    required String eventId,
    required String assetAccountId,
    required String expenseAccountId,
    required Money amount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    _requirePositiveAmount(amount);

    final postings = [
      Posting.debit(
        id: '${eventId}_dr',
        economicEventId: eventId,
        accountId: expenseAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
      Posting.credit(
        id: '${eventId}_cr',
        economicEventId: eventId,
        accountId: assetAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
    ];

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.expense,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates a canonical **Income** event.
  ///
  /// Standard Accounting:
  /// - DEBIT: Asset Account (increases cash/bank)
  /// - CREDIT: Income Account (increases income/revenue)
  static EconomicEvent createIncome({
    required String eventId,
    required String assetAccountId,
    required String incomeAccountId,
    required Money amount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    _requirePositiveAmount(amount);

    final postings = [
      Posting.debit(
        id: '${eventId}_dr',
        economicEventId: eventId,
        accountId: assetAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
      Posting.credit(
        id: '${eventId}_cr',
        economicEventId: eventId,
        accountId: incomeAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
    ];

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.income,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates a canonical **Transfer** event between two asset accounts.
  ///
  /// Standard Accounting:
  /// - DEBIT: Destination Asset Account (increases cash/bank at destination)
  /// - CREDIT: Source Asset Account (decreases cash/bank at source)
  ///
  /// Invariant: Net change to Asset category is EXACTLY ZERO.
  static EconomicEvent createTransfer({
    required String eventId,
    required String sourceAssetAccountId,
    required String destinationAssetAccountId,
    required Money amount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    _requirePositiveAmount(amount);
    if (sourceAssetAccountId == destinationAssetAccountId) {
      throw AccountingInvariantException(
        'Transfer source and destination accounts must be distinct.',
        eventId: eventId,
      );
    }

    final postings = [
      Posting.debit(
        id: '${eventId}_dr',
        economicEventId: eventId,
        accountId: destinationAssetAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
      Posting.credit(
        id: '${eventId}_cr',
        economicEventId: eventId,
        accountId: sourceAssetAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
    ];

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.transfer,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates a canonical **Credit Card Purchase** event.
  ///
  /// Standard Accounting:
  /// - DEBIT: Expense Account (increases expense)
  /// - CREDIT: Credit Card Liability Account (increases liability/debt)
  static EconomicEvent createCardPurchase({
    required String eventId,
    required String cardLiabilityAccountId,
    required String expenseAccountId,
    required Money amount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    _requirePositiveAmount(amount);

    final postings = [
      Posting.debit(
        id: '${eventId}_dr',
        economicEventId: eventId,
        accountId: expenseAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
      Posting.credit(
        id: '${eventId}_cr',
        economicEventId: eventId,
        accountId: cardLiabilityAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
    ];

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.cardPurchase,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates a canonical **Credit Card Payment** (bill payment) event.
  ///
  /// Standard Accounting:
  /// - DEBIT: Credit Card Liability Account (decreases credit card debt)
  /// - CREDIT: Bank Asset Account (decreases bank balance)
  ///
  /// MANDATORY INVARIANT:
  /// A credit card payment NEVER touches an Expense account! It is a pure
  /// balance sheet asset/liability settlement.
  static EconomicEvent createCardPayment({
    required String eventId,
    required String bankAssetAccountId,
    required String cardLiabilityAccountId,
    required Money amount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    _requirePositiveAmount(amount);

    final postings = [
      Posting.debit(
        id: '${eventId}_dr',
        economicEventId: eventId,
        accountId: cardLiabilityAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
      Posting.credit(
        id: '${eventId}_cr',
        economicEventId: eventId,
        accountId: bankAssetAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
    ];

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.cardPayment,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates a canonical **Refund** event.
  ///
  /// Standard Accounting:
  /// - DEBIT: Asset Account (cash returned)
  /// - CREDIT: Expense Account (offsets original expense or general refunds)
  ///
  /// MANDATORY INVARIANT:
  /// A refund is a contra-expense and NEVER touches an Income account.
  static EconomicEvent createRefund({
    required String eventId,
    required String assetAccountId,
    required String expenseAccountId,
    required Money amount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    String? originalEventId,
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    _requirePositiveAmount(amount);

    final meta = Map<String, dynamic>.from(metadata ?? const {});
    if (originalEventId != null) {
      meta['original_event_id'] = originalEventId;
    }

    final postings = [
      Posting.debit(
        id: '${eventId}_dr',
        economicEventId: eventId,
        accountId: assetAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
      Posting.credit(
        id: '${eventId}_cr',
        economicEventId: eventId,
        accountId: expenseAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
    ];

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.refund,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: meta,
      postings: postings,
    );
  }

  /// Creates a canonical **Loan Disbursement** event.
  ///
  /// Standard Accounting:
  /// - DEBIT: Bank Asset Account (increases cash in bank)
  /// - CREDIT: Loan Liability Account (creates loan obligation)
  static EconomicEvent createLoanDisbursement({
    required String eventId,
    required String bankAssetAccountId,
    required String loanLiabilityAccountId,
    required Money amount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    _requirePositiveAmount(amount);

    final postings = [
      Posting.debit(
        id: '${eventId}_dr',
        economicEventId: eventId,
        accountId: bankAssetAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
      Posting.credit(
        id: '${eventId}_cr',
        economicEventId: eventId,
        accountId: loanLiabilityAccountId,
        amount: amount,
        createdAt: createdAt,
      ),
    ];

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.loanDisbursement,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates a canonical **Loan Repayment** (EMI) event with split principal and interest.
  ///
  /// Standard Accounting:
  /// - DEBIT: Loan Liability Account (reduces principal debt by [principalAmount])
  /// - DEBIT: Interest Expense Account (recognizes cost of borrowing by [interestAmount])
  /// - CREDIT: Bank Asset Account (total cash outflow = principal + interest)
  ///
  /// MANDATORY INVARIANT:
  /// Principal repayment is a liability reduction, NOT an expense.
  /// Only interest is recognized as an expense.
  static EconomicEvent createLoanRepayment({
    required String eventId,
    required String bankAssetAccountId,
    required String loanLiabilityAccountId,
    required String interestExpenseAccountId,
    required Money principalAmount,
    required Money interestAmount,
    required DateTime occurredAt,
    required DateTime createdAt,
    String description = '',
    List<String>? evidenceIds,
    Map<String, dynamic>? metadata,
  }) {
    if (!principalAmount.isPositive && !interestAmount.isPositive) {
      throw ArgumentError(
        'At least one of principal or interest must be strictly positive.',
      );
    }
    final totalPayment = principalAmount + interestAmount;

    final postings = <Posting>[];
    if (principalAmount.isPositive) {
      postings.add(
        Posting.debit(
          id: '${eventId}_dr_principal',
          economicEventId: eventId,
          accountId: loanLiabilityAccountId,
          amount: principalAmount,
          createdAt: createdAt,
        ),
      );
    }
    if (interestAmount.isPositive) {
      postings.add(
        Posting.debit(
          id: '${eventId}_dr_interest',
          economicEventId: eventId,
          accountId: interestExpenseAccountId,
          amount: interestAmount,
          createdAt: createdAt,
        ),
      );
    }
    postings.add(
      Posting.credit(
        id: '${eventId}_cr_bank',
        economicEventId: eventId,
        accountId: bankAssetAccountId,
        amount: totalPayment,
        createdAt: createdAt,
      ),
    );

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.loanRepayment,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: description,
      evidenceIds: evidenceIds,
      metadata: metadata,
      postings: postings,
    );
  }

  /// Creates a canonical **Opening Balance Equity** adjustment event.
  ///
  /// For an Asset account:
  /// - If balance > 0: DEBIT Asset / CREDIT Equity:OpeningBalances
  /// - If balance < 0 (overdraft): CREDIT Asset / DEBIT Equity:OpeningBalances
  ///
  /// For a Liability account:
  /// - If debt > 0: DEBIT Equity:OpeningBalances / CREDIT Liability
  static EconomicEvent createOpeningBalance({
    required String eventId,
    required String targetAccountId,
    required AccountType accountType,
    required String openingBalanceEquityAccountId,
    required Money balance,
    required DateTime occurredAt,
    required DateTime createdAt,
    required String reason,
    String? provenanceSource,
    Map<String, dynamic>? metadata,
  }) {
    if (balance.isZero) {
      throw ArgumentError('Opening balance event cannot have zero balance.');
    }

    final meta = Map<String, dynamic>.from(metadata ?? const {});
    meta['reconciliation_reason'] = reason;
    if (provenanceSource != null) {
      meta['provenance_source'] = provenanceSource;
    }

    final absAmount = balance.abs();
    final postings = <Posting>[];

    if (accountType == AccountType.asset) {
      if (balance.isPositive) {
        postings.add(
          Posting.debit(
            id: '${eventId}_dr',
            economicEventId: eventId,
            accountId: targetAccountId,
            amount: absAmount,
            createdAt: createdAt,
          ),
        );
        postings.add(
          Posting.credit(
            id: '${eventId}_cr',
            economicEventId: eventId,
            accountId: openingBalanceEquityAccountId,
            amount: absAmount,
            createdAt: createdAt,
          ),
        );
      } else {
        postings.add(
          Posting.debit(
            id: '${eventId}_dr',
            economicEventId: eventId,
            accountId: openingBalanceEquityAccountId,
            amount: absAmount,
            createdAt: createdAt,
          ),
        );
        postings.add(
          Posting.credit(
            id: '${eventId}_cr',
            economicEventId: eventId,
            accountId: targetAccountId,
            amount: absAmount,
            createdAt: createdAt,
          ),
        );
      }
    } else if (accountType == AccountType.liability) {
      // Positive liability means debt owed
      postings.add(
        Posting.debit(
          id: '${eventId}_dr',
          economicEventId: eventId,
          accountId: openingBalanceEquityAccountId,
          amount: absAmount,
          createdAt: createdAt,
        ),
      );
      postings.add(
        Posting.credit(
          id: '${eventId}_cr',
          economicEventId: eventId,
          accountId: targetAccountId,
          amount: absAmount,
          createdAt: createdAt,
        ),
      );
    } else {
      throw ArgumentError(
        'Opening balances can only be established for Asset or Liability accounts. Found $accountType',
      );
    }

    return EconomicEvent.posted(
      id: eventId,
      canonicalType: CanonicalEventType.openingBalance,
      occurredAt: occurredAt,
      createdAt: createdAt,
      description: 'Opening Balance: $reason',
      metadata: meta,
      postings: postings,
    );
  }

  static void _requirePositiveAmount(Money amount) {
    if (!amount.isPositive) {
      throw ArgumentError.value(
        amount,
        'amount',
        'Event amount must be strictly positive minor units.',
      );
    }
  }
}
