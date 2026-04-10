/// A detected financial anomaly.
class Anomaly {
  final String id;
  final AnomalyType type;
  final String title;
  final String description;
  final AnomalySeverity severity;
  final String? suggestion;
  final DateTime detectedAt;

  const Anomaly({
    required this.id,
    required this.type,
    required this.title,
    required this.description,
    required this.severity,
    this.suggestion,
    required this.detectedAt,
  });
}

enum AnomalyType {
  spendingSpike,
  categorySpike,
  largeTransaction,
  lowBalanceRisk,
  creditRisk,
  emiPressure,
}

enum AnomalySeverity { low, medium, high }
