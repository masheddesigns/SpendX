import 'money.dart';

/// Pure domain representation of the Safe-to-Spend liquidity calculation.
///
/// CRITICAL ARCHITECTURAL DISTINCTIONS:
/// 1. [discretionaryCash] can be negative when commitments exceed liquid cash.
/// 2. [safeToSpend] is floored at zero: `max(0, discretionaryCash)`.
/// 3. [cashflowShortfall] preserves deficit magnitude: `max(0, -discretionaryCash)`.
///
/// These three metrics must NEVER be collapsed into a single value.
class SafeToSpendCalculation {
  /// Total cash across all unrestricted liquid asset accounts.
  final Money liquidAssets;

  /// Sum of all active virtual reservations for savings goals.
  final Money activeEarmarks;

  /// Fixed, non-negotiable recurring obligations due within the next 14 calendar days.
  final Money knownCommitments14d;

  /// High-confidence pending debits (e.g., cleared uncleared cheques, pending debit cards).
  final Money highConfidencePendingDebits;

  /// Raw, un-floored discretionary liquidity. Can be negative.
  final Money discretionaryCash;

  /// User-facing safe spending allowance floored at zero.
  final Money safeToSpend;

  /// Cashflow deficit when discretionary cash is negative; zero otherwise.
  final Money cashflowShortfall;

  const SafeToSpendCalculation._({
    required this.liquidAssets,
    required this.activeEarmarks,
    required this.knownCommitments14d,
    required this.highConfidencePendingDebits,
    required this.discretionaryCash,
    required this.safeToSpend,
    required this.cashflowShortfall,
  });

  /// Computes the complete Safe-to-Spend breakdown from its component values.
  factory SafeToSpendCalculation.compute({
    required Money liquidAssets,
    required Money activeEarmarks,
    required Money knownCommitments14d,
    required Money highConfidencePendingDebits,
  }) {
    // discretionary_cash = liquid_assets - active_earmarks - known_commitments_14d - high_confidence_pending_debits
    final discretionary = liquidAssets -
        activeEarmarks -
        knownCommitments14d -
        highConfidencePendingDebits;

    final zero = Money.zeroCurrency(liquidAssets.currency);

    // safe_to_spend = max(0, discretionary_cash)
    final safe = discretionary.isNegative ? zero : discretionary;

    // cashflow_shortfall = max(0, -discretionary_cash)
    final shortfall = discretionary.isNegative ? -discretionary : zero;

    return SafeToSpendCalculation._(
      liquidAssets: liquidAssets,
      activeEarmarks: activeEarmarks,
      knownCommitments14d: knownCommitments14d,
      highConfidencePendingDebits: highConfidencePendingDebits,
      discretionaryCash: discretionary,
      safeToSpend: safe,
      cashflowShortfall: shortfall,
    );
  }

  /// Whether the user is currently in a liquidity deficit (shortfall > 0).
  bool get hasShortfall => discretionaryCash.isNegative;

  /// Total commitments and reservations deducting from liquid assets.
  Money get totalReservations =>
      activeEarmarks + knownCommitments14d + highConfidencePendingDebits;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SafeToSpendCalculation &&
          runtimeType == other.runtimeType &&
          liquidAssets == other.liquidAssets &&
          activeEarmarks == other.activeEarmarks &&
          knownCommitments14d == other.knownCommitments14d &&
          highConfidencePendingDebits == other.highConfidencePendingDebits &&
          discretionaryCash == other.discretionaryCash &&
          safeToSpend == other.safeToSpend &&
          cashflowShortfall == other.cashflowShortfall;

  @override
  int get hashCode => Object.hash(
        liquidAssets,
        activeEarmarks,
        knownCommitments14d,
        highConfidencePendingDebits,
        discretionaryCash,
        safeToSpend,
        cashflowShortfall,
      );

  @override
  String toString() =>
      'SafeToSpendCalculation(Liquid: $liquidAssets, Discretionary: $discretionaryCash, Safe: $safeToSpend, Shortfall: $cashflowShortfall)';
}
