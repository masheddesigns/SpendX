import 'dart:math' as math;
import '../dashboard/insights_providers.dart';

class Forecast {
  final double predictedIncome;
  final double predictedExpense;
  final double predictedBalance;
  final double confidence; // 0.0–1.0

  const Forecast({
    required this.predictedIncome,
    required this.predictedExpense,
    required this.predictedBalance,
    required this.confidence,
  });

  double get predictedSavings => predictedIncome - predictedExpense;
  String get confidenceLabel =>
      confidence >= 0.8 ? 'High' : confidence >= 0.6 ? 'Medium' : 'Low';
}

/// Deterministic forecast using weighted moving average + trend.
/// No ML, no API, no randomness.
class ForecastEngine {
  Forecast predict({
    required List<MonthlyStats> monthlyStats,
    required double currentBalance,
  }) {
    if (monthlyStats.length < 2) {
      return Forecast(
        predictedIncome: monthlyStats.firstOrNull?.income ?? 0,
        predictedExpense: monthlyStats.firstOrNull?.expense ?? 0,
        predictedBalance: currentBalance,
        confidence: 0.3,
      );
    }

    // Use up to 3 most recent COMPLETE months (skip current partial month)
    final history = monthlyStats.length > 1 ? monthlyStats.sublist(1) : monthlyStats;
    final recent = history.take(3).toList();

    // ── Step 1: Weighted average (recent months weighted more) ────────
    double weightedIncome = 0, weightedExpense = 0, totalWeight = 0;
    for (var i = 0; i < recent.length; i++) {
      final weight = recent.length - i.toDouble(); // 3, 2, 1
      weightedIncome += recent[i].income * weight;
      weightedExpense += recent[i].expense * weight;
      totalWeight += weight;
    }
    final avgIncome = totalWeight > 0 ? weightedIncome / totalWeight : 0.0;
    final avgExpense = totalWeight > 0 ? weightedExpense / totalWeight : 0.0;

    // ── Step 2: Trend adjustment (small influence) ───────────────────
    double expenseTrend = 0;
    double incomeTrend = 0;
    if (recent.length >= 2) {
      expenseTrend = (recent.first.expense - recent.last.expense) /
          recent.length;
      incomeTrend = (recent.first.income - recent.last.income) /
          recent.length;
    }

    final predictedExpense = (avgExpense + expenseTrend * 0.3)
        .clamp(0.0, double.infinity);
    final predictedIncome = (avgIncome + incomeTrend * 0.3)
        .clamp(0.0, double.infinity);

    // ── Step 3: Balance prediction ───────────────────────────────────
    final predictedBalance = currentBalance + predictedIncome - predictedExpense;

    // ── Step 4: Confidence from variance ─────────────────────────────
    double confidence;
    if (recent.length >= 3) {
      final expenses = recent.map((s) => s.expense).toList();
      final mean = expenses.reduce((a, b) => a + b) / expenses.length;
      final variance = expenses
          .map((e) => (e - mean) * (e - mean))
          .reduce((a, b) => a + b) / expenses.length;
      final stdDev = math.sqrt(variance);

      if (mean > 0) {
        final cv = stdDev / mean; // coefficient of variation
        if (cv < 0.1) {
          confidence = 0.9;
        } else if (cv < 0.25) {
          confidence = 0.7;
        } else {
          confidence = 0.5;
        }
      } else {
        confidence = 0.3;
      }
    } else {
      confidence = 0.4;
    }

    return Forecast(
      predictedIncome: predictedIncome,
      predictedExpense: predictedExpense,
      predictedBalance: predictedBalance,
      confidence: confidence,
    );
  }
}
