/// Progress emitted during historical SMS inbox calibration.
/// Every counter reflects distinct records, not parser match counts.
class CalibrationProgress {
  final int messagesScanned;
  final int financialIdentified;
  final int accountsDiscovered;
  final int transactionsImported;
  final int existingMatched;
  final int reviewRequired;
  final int obligationsDetected;
  final int nonFinancialIgnored;

  const CalibrationProgress({
    this.messagesScanned = 0,
    this.financialIdentified = 0,
    this.accountsDiscovered = 0,
    this.transactionsImported = 0,
    this.existingMatched = 0,
    this.reviewRequired = 0,
    this.obligationsDetected = 0,
    this.nonFinancialIgnored = 0,
  });

  CalibrationProgress copyWith({
    int? messagesScanned,
    int? financialIdentified,
    int? accountsDiscovered,
    int? transactionsImported,
    int? existingMatched,
    int? reviewRequired,
    int? obligationsDetected,
    int? nonFinancialIgnored,
  }) {
    return CalibrationProgress(
      messagesScanned: messagesScanned ?? this.messagesScanned,
      financialIdentified: financialIdentified ?? this.financialIdentified,
      accountsDiscovered: accountsDiscovered ?? this.accountsDiscovered,
      transactionsImported: transactionsImported ?? this.transactionsImported,
      existingMatched: existingMatched ?? this.existingMatched,
      reviewRequired: reviewRequired ?? this.reviewRequired,
      obligationsDetected: obligationsDetected ?? this.obligationsDetected,
      nonFinancialIgnored: nonFinancialIgnored ?? this.nonFinancialIgnored,
    );
  }
}

/// Final outcome of the historical SMS inbox calibration scan.
class CalibrationScanOutcome {
  final CalibrationProgress progress;
  final bool completed;
  final bool resumed;
  final String? error;

  const CalibrationScanOutcome({
    required this.progress,
    required this.completed,
    this.resumed = false,
    this.error,
  });
}
