import 'money.dart';

/// The status of a balance reconciliation assessment.
enum ReconciliationStatus {
  /// History matches legacy balance perfectly; zero delta.
  matched,

  /// Historical transactions do not explain full balance; opening equity required.
  equityAdjustmentRequired,

  /// Critical anomalies detected (e.g. orphan transactions); flagged for manual inspection.
  quarantined,

  /// User has reviewed and approved the reconciliation delta.
  reviewed;

  bool get isMatched => this == matched;
  bool get requiresEquityAdjustment => this == equityAdjustmentRequired;
  bool get isQuarantined => this == quarantined;
  bool get isReviewed => this == reviewed;
}

/// Explicit provenance and audit entity for opening-balance reconciliation.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// An opening balance adjustment can NEVER be an opaque balancing figure.
/// It must preserve the exact delta between legacy reported balance and
/// reconstructed history, accompanied by mandatory provenance and reasoning.
class OpeningBalanceReconciliation {
  /// Unique reconciliation record ID.
  final String id;

  /// Identifier of the target account being reconciled.
  final String accountId;

  /// Balance reported in the legacy system (e.g. bank_accounts.balance).
  final Money legacyReportedBalance;

  /// Balance derived by summing non-deleted legacy transactions.
  final Money reconstructedBalanceFromTxns;

  /// The exact mathematical difference: `legacyReportedBalance - reconstructedBalanceFromTxns`.
  final Money adjustmentDelta;

  /// Explicit explanation for why this delta exists
  /// (e.g., 'Unbacked initial balance on account creation', 'Pre-SpendX opening savings').
  final String reconciliationReason;

  /// Provenance source tag (e.g. 'migration_v24_reconciliation', 'manual_account_creation').
  final String provenanceSource;

  /// Reconciliation audit status.
  final ReconciliationStatus status;

  /// Optional ID of the generated [EconomicEvent] that established opening equity.
  final String? generatedEventId;

  /// When this reconciliation was computed.
  final DateTime createdAt;

  OpeningBalanceReconciliation({
    required this.id,
    required this.accountId,
    required this.legacyReportedBalance,
    required this.reconstructedBalanceFromTxns,
    required this.reconciliationReason,
    required this.provenanceSource,
    required this.status,
    this.generatedEventId,
    required this.createdAt,
  }) : adjustmentDelta = legacyReportedBalance - reconstructedBalanceFromTxns {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Reconciliation ID cannot be empty.');
    }
    if (accountId.trim().isEmpty) {
      throw ArgumentError.value(accountId, 'accountId', 'Account ID cannot be empty.');
    }
    if (reconciliationReason.trim().isEmpty) {
      throw ArgumentError.value(
        reconciliationReason,
        'reconciliationReason',
        'Reconciliation reason must be explicitly stated. Generic adjustments are prohibited.',
      );
    }
    if (provenanceSource.trim().isEmpty) {
      throw ArgumentError.value(
        provenanceSource,
        'provenanceSource',
        'Provenance source cannot be empty.',
      );
    }
  }

  /// Whether an equity adjustment event is mathematically required.
  bool get hasDelta => !adjustmentDelta.isZero;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpeningBalanceReconciliation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          accountId == other.accountId &&
          legacyReportedBalance == other.legacyReportedBalance &&
          reconstructedBalanceFromTxns == other.reconstructedBalanceFromTxns &&
          adjustmentDelta == other.adjustmentDelta &&
          reconciliationReason == other.reconciliationReason &&
          provenanceSource == other.provenanceSource &&
          status == other.status;

  @override
  int get hashCode => Object.hash(
        id,
        accountId,
        legacyReportedBalance,
        reconstructedBalanceFromTxns,
        adjustmentDelta,
        reconciliationReason,
        provenanceSource,
        status,
      );

  @override
  String toString() =>
      'OpeningBalanceReconciliation(acc: $accountId, legacy: $legacyReportedBalance, reconstructed: $reconstructedBalanceFromTxns, delta: $adjustmentDelta, status: ${status.name})';
}
