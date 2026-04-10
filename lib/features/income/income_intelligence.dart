import 'dart:math' as math;
import '../dashboard/insights_providers.dart';

// ── Income Stability ─────────────────────────────────────────────────────

enum IncomeStabilityLevel { stable, moderate, unstable }

class IncomeIntelligence {
  final double stabilityScore; // 0–100
  final double avgIncome;
  final double variance;
  final IncomeStabilityLevel level;

  const IncomeIntelligence({
    required this.stabilityScore,
    required this.avgIncome,
    required this.variance,
    required this.level,
  });
}

// ── Salary Prediction ────────────────────────────────────────────────────

class SalaryPrediction {
  final double expectedAmount;
  final DateTime expectedDate;
  final double confidence; // 0.0–1.0

  const SalaryPrediction({
    required this.expectedAmount,
    required this.expectedDate,
    required this.confidence,
  });

  String get confidenceLabel =>
      confidence >= 0.8 ? 'High' : confidence >= 0.6 ? 'Medium' : 'Low';
}

// ── Employer Reliability ─────────────────────────────────────────────────

class EmployerReliability {
  final double score; // 0–100
  final int onTimeMonths;
  final int delayedMonths;
  final int partialMonths;

  const EmployerReliability({
    required this.score,
    required this.onTimeMonths,
    required this.delayedMonths,
    required this.partialMonths,
  });

  String get label {
    if (score >= 80) return 'Reliable';
    if (score >= 60) return 'Mostly On Time';
    if (score >= 40) return 'Inconsistent';
    return 'Unreliable';
  }
}

// ── Engine ────────────────────────────────────────────────────────────────

class IncomeIntelligenceEngine {
  /// Compute income stability from monthly stats.
  IncomeIntelligence computeStability(List<MonthlyStats> stats) {
    if (stats.length < 2) {
      return const IncomeIntelligence(
        stabilityScore: 50,
        avgIncome: 0,
        variance: 0,
        level: IncomeStabilityLevel.moderate,
      );
    }

    final incomes = stats.take(6).map((s) => s.income).where((i) => i > 0).toList();
    if (incomes.isEmpty) {
      return const IncomeIntelligence(
        stabilityScore: 0,
        avgIncome: 0,
        variance: 0,
        level: IncomeStabilityLevel.unstable,
      );
    }

    final avg = incomes.reduce((a, b) => a + b) / incomes.length;
    final varianceSum = incomes.map((i) => (i - avg) * (i - avg)).reduce((a, b) => a + b);
    final stdDev = math.sqrt(varianceSum / incomes.length);
    final cv = avg > 0 ? stdDev / avg : 1.0; // coefficient of variation

    final IncomeStabilityLevel level;
    final double score;
    if (cv < 0.10) {
      level = IncomeStabilityLevel.stable;
      score = 90 - (cv * 100);
    } else if (cv < 0.25) {
      level = IncomeStabilityLevel.moderate;
      score = 70 - (cv * 100);
    } else {
      level = IncomeStabilityLevel.unstable;
      score = math.max(10, 50 - (cv * 100));
    }

    return IncomeIntelligence(
      stabilityScore: score.clamp(0, 100),
      avgIncome: avg,
      variance: cv,
      level: level,
    );
  }

  /// Predict next salary based on history.
  SalaryPrediction predictNextSalary({
    required List<MonthlyStats> stats,
    required int expectedPayday,
  }) {
    final incomes = stats.take(6).map((s) => s.income).where((i) => i > 0).toList();
    if (incomes.isEmpty) {
      final now = DateTime.now();
      return SalaryPrediction(
        expectedAmount: 0,
        expectedDate: DateTime(now.year, now.month + 1, expectedPayday.clamp(1, 28)),
        confidence: 0.2,
      );
    }

    final avg = incomes.reduce((a, b) => a + b) / incomes.length;
    final now = DateTime.now();
    final nextMonth = DateTime(now.year, now.month + 1, expectedPayday.clamp(1, 28));

    // Confidence from variance
    final stability = computeStability(stats);
    final confidence = stability.level == IncomeStabilityLevel.stable
        ? 0.9
        : stability.level == IncomeStabilityLevel.moderate
            ? 0.7
            : 0.4;

    return SalaryPrediction(
      expectedAmount: avg,
      expectedDate: nextMonth,
      confidence: confidence,
    );
  }

  /// Compute employer reliability from payment history.
  EmployerReliability computeReliability({
    required int totalMonths,
    required int onTimeMonths,
    required int delayedMonths,
    required int partialMonths,
  }) {
    if (totalMonths == 0) {
      return const EmployerReliability(
        score: 50,
        onTimeMonths: 0,
        delayedMonths: 0,
        partialMonths: 0,
      );
    }

    double score = 100;
    score -= delayedMonths * 10;
    score -= partialMonths * 5;
    score += onTimeMonths * 2;
    score = score.clamp(0, 100);

    return EmployerReliability(
      score: score,
      onTimeMonths: onTimeMonths,
      delayedMonths: delayedMonths,
      partialMonths: partialMonths,
    );
  }
}
