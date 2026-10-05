import 'money.dart';

/// The direction of a posting leg in double-entry bookkeeping.
enum PostingDirection {
  debit,
  credit;

  bool get isDebit => this == debit;
  bool get isCredit => this == credit;

  PostingDirection get opposite => this == debit ? credit : debit;
}

/// Immutable atomic leg of a double-entry transaction.
///
/// CRITICAL DOMAIN INVARIANTS:
/// 1. A posting has EXACTLY ONE direction (debit or credit).
/// 2. The amount is strictly positive minor units (Money > 0).
/// 3. Debits and credits are NEVER represented by positive/negative signs.
class Posting {
  /// Unique identifier of this individual posting row.
  final String id;

  /// Identifier of the parent [EconomicEvent] this posting belongs to.
  final String economicEventId;

  /// Target account affected by this posting.
  final String accountId;

  /// Whether this leg is a debit or a credit.
  final PostingDirection direction;

  /// The non-negative monetary magnitude of this posting leg.
  final Money amount;

  /// Timestamp when this posting was recorded.
  final DateTime createdAt;

  Posting({
    required this.id,
    required this.economicEventId,
    required this.accountId,
    required this.direction,
    required this.amount,
    required this.createdAt,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Posting id cannot be empty.');
    }
    if (economicEventId.trim().isEmpty) {
      throw ArgumentError.value(
        economicEventId,
        'economicEventId',
        'EconomicEvent ID cannot be empty.',
      );
    }
    if (accountId.trim().isEmpty) {
      throw ArgumentError.value(accountId, 'accountId', 'Account ID cannot be empty.');
    }
    if (!amount.isPositive) {
      throw ArgumentError.value(
        amount,
        'amount',
        'Posting amount must be strictly positive minor units.',
      );
    }
  }

  /// Convenience factory for a debit leg.
  factory Posting.debit({
    required String id,
    required String economicEventId,
    required String accountId,
    required Money amount,
    required DateTime createdAt,
  }) {
    return Posting(
      id: id,
      economicEventId: economicEventId,
      accountId: accountId,
      direction: PostingDirection.debit,
      amount: amount,
      createdAt: createdAt,
    );
  }

  /// Convenience factory for a credit leg.
  factory Posting.credit({
    required String id,
    required String economicEventId,
    required String accountId,
    required Money amount,
    required DateTime createdAt,
  }) {
    return Posting(
      id: id,
      economicEventId: economicEventId,
      accountId: accountId,
      direction: PostingDirection.credit,
      amount: amount,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Posting &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          economicEventId == other.economicEventId &&
          accountId == other.accountId &&
          direction == other.direction &&
          amount == other.amount;

  @override
  int get hashCode => Object.hash(
        id,
        economicEventId,
        accountId,
        direction,
        amount,
      );

  @override
  String toString() =>
      'Posting(id: $id, evt: $economicEventId, acc: $accountId, ${direction.name.toUpperCase()} $amount)';
}
