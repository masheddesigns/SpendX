import 'money.dart';

/// Pure domain representation of a virtual savings goal earmark.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// An [AssetEarmark] is a soft reservation / derived allocation of cash.
/// It NEVER moves physical money and creates ZERO double-entry ledger postings.
/// Ledger balance is physical accounting fact; earmarks govern derived Safe-to-Spend.
class AssetEarmark {
  /// Unique identifier of the earmark link.
  final String id;

  /// Identifier of the target savings goal.
  final String goalId;

  /// Identifier of the liquid asset account where funds are virtually reserved.
  final String assetAccountId;

  /// Amount reserved for this goal in minor units. Must be strictly positive.
  final Money earmarkedAmount;

  /// When this earmark was created.
  final DateTime createdAt;

  /// When this earmark was last modified.
  final DateTime updatedAt;

  AssetEarmark({
    required this.id,
    required this.goalId,
    required this.assetAccountId,
    required this.earmarkedAmount,
    required this.createdAt,
    required this.updatedAt,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Earmark ID cannot be empty.');
    }
    if (goalId.trim().isEmpty) {
      throw ArgumentError.value(goalId, 'goalId', 'Goal ID cannot be empty.');
    }
    if (assetAccountId.trim().isEmpty) {
      throw ArgumentError.value(
        assetAccountId,
        'assetAccountId',
        'Asset Account ID cannot be empty.',
      );
    }
    if (!earmarkedAmount.isPositive) {
      throw ArgumentError.value(
        earmarkedAmount,
        'earmarkedAmount',
        'Earmarked amount must be strictly positive minor units.',
      );
    }
  }

  /// Creates a copy of this earmark with an updated amount.
  AssetEarmark copyWith({
    Money? earmarkedAmount,
    DateTime? updatedAt,
  }) {
    return AssetEarmark(
      id: id,
      goalId: goalId,
      assetAccountId: assetAccountId,
      earmarkedAmount: earmarkedAmount ?? this.earmarkedAmount,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssetEarmark &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          goalId == other.goalId &&
          assetAccountId == other.assetAccountId &&
          earmarkedAmount == other.earmarkedAmount;

  @override
  int get hashCode => Object.hash(id, goalId, assetAccountId, earmarkedAmount);

  @override
  String toString() =>
      'AssetEarmark(id: $id, goal: $goalId, acc: $assetAccountId, amount: $earmarkedAmount)';
}
