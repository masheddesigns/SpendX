import 'dart:math';

/// Driving score computed purely from existing local data — no GPS needed.
/// Focuses purely on fuel efficiency and logging behaviors.
///
/// Score is 0–100, broken into 3 core sub-metrics:
///   1. Efficiency Consistency (steady mileage)
///   2. Efficiency Trend       (improving vs declining)
///   3. Logging Activity       (consistent tracking)
class DrivingScoreService {
  DrivingScoreService._();
  static final DrivingScoreService instance = DrivingScoreService._();

  /// Compute the overall driving score.
  DrivingScore compute({
    required List<double> efficiencies, // mileage data points (km/L)
    required double avgMileage,
  }) {
    if (efficiencies.isEmpty) {
      return DrivingScore.empty();
    }

    final scores = <ScoreMetric>[];

    // 1. Efficiency consistency (std-dev of mileage)
    double efficiencyScore = 100.0;
    if (efficiencies.length > 2) {
      final mean = efficiencies.reduce((a, b) => a + b) / efficiencies.length;
      final variance = efficiencies.map((e) => pow(e - mean, 2)).reduce((a, b) => a + b) / efficiencies.length;
      final stdDev = sqrt(variance);
      final cv = mean > 0 ? stdDev / mean : 0; // coefficient of variation
      efficiencyScore = (100 - (cv * 200)).clamp(0, 100).toDouble();
    }
    scores.add(ScoreMetric(
      label: 'Consistency',
      icon: '📊',
      score: efficiencyScore,
      comment: efficiencyScore >= 80 ? 'Very steady mileage' : efficiencyScore >= 60 ? 'Slightly variable' : 'Mileage varies a lot',
    ));

    // 2. Efficiency trend (last 3 vs first 3 entries)
    double trendScore = 75.0;
    if (efficiencies.length >= 6) {
      final recent = efficiencies.sublist(efficiencies.length - 3).reduce((a, b) => a + b) / 3;
      final earlier = efficiencies.sublist(0, 3).reduce((a, b) => a + b) / 3;
      final improvement = earlier > 0 ? (recent - earlier) / earlier : 0;
      trendScore = (75 + improvement * 500).clamp(0, 100).toDouble();
    }
    scores.add(ScoreMetric(
      label: 'Efficiency Trend',
      icon: '📈',
      score: trendScore,
      comment: trendScore >= 80 ? 'Improving over time' : trendScore >= 60 ? 'Stable efficiency' : 'Declining efficiency',
    ));

    // 3. Logging frequency (proxy for engagement)
    double loggingScore = 50.0;
    if (efficiencies.isNotEmpty) {
      // Reward having more data points
      loggingScore = (efficiencies.length * 5).clamp(0, 100).toDouble();
    }
    scores.add(ScoreMetric(
      label: 'Active Logging',
      icon: '📝',
      score: loggingScore,
      comment: loggingScore >= 80 ? 'Great tracking habits' : loggingScore >= 40 ? 'Moderate tracking' : 'Log more often!',
    ));

    // Overall = weighted average
    final overall = (
      efficiencyScore * 0.40 +
      trendScore      * 0.40 +
      loggingScore    * 0.20
    );

    return DrivingScore(
      overall: overall,
      metrics: scores,
      grade: _grade(overall),
      gradeColor: _gradeColor(overall),
    );
  }

  String _grade(double score) {
    if (score >= 90) return 'A+';
    if (score >= 80) return 'A';
    if (score >= 70) return 'B';
    if (score >= 60) return 'C';
    if (score >= 50) return 'D';
    return 'F';
  }

  String _gradeColor(double score) {
    if (score >= 80) return '#22C55E'; // green
    if (score >= 60) return '#F59E0B'; // amber
    return '#EF4444'; // red
  }
}

class ScoreMetric {
  final String label;
  final String icon;
  final double score; // 0–100
  final String comment;

  const ScoreMetric({
    required this.label,
    required this.icon,
    required this.score,
    required this.comment,
  });
}

class DrivingScore {
  final double overall; // 0–100
  final List<ScoreMetric> metrics;
  final String grade;
  final String gradeColor;

  const DrivingScore({
    required this.overall,
    required this.metrics,
    required this.grade,
    required this.gradeColor,
  });

  factory DrivingScore.empty() => const DrivingScore(
    overall: 0,
    metrics: [],
    grade: '—',
    gradeColor: '#9CA3AF',
  );
}
