import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/providers/account_providers.dart';
import '../dashboard/insights_providers.dart';
import '../liabilities/providers/credit_health_providers.dart';

// ── Score Model ──────────────────────────────────────────────────────────

class FinancialHealthScore {
  final int score; // 0–100
  final String level; // Excellent / Good / Moderate / Risk
  final ScoreBreakdown breakdown;
  final List<HealthInsight> insights;

  const FinancialHealthScore({
    required this.score,
    required this.level,
    required this.breakdown,
    required this.insights,
  });
}

class ScoreBreakdown {
  final int savingsScore;    // out of 30
  final int debtScore;       // out of 25
  final int stabilityScore;  // out of 20
  final int liquidityScore;  // out of 15
  final int utilizationScore; // out of 10

  const ScoreBreakdown({
    required this.savingsScore,
    required this.debtScore,
    required this.stabilityScore,
    required this.liquidityScore,
    required this.utilizationScore,
  });
}

class HealthInsight {
  final String text;
  final HealthInsightType type;

  const HealthInsight({required this.text, required this.type});
}

enum HealthInsightType { positive, warning, actionable }

// ── Score Computation (Pure, Deterministic) ──────────────────────────────

/// Computes the financial health score from pre-fetched provider data.
/// All inputs come from existing providers — no direct DB access.
FinancialHealthScore computeHealthScore({
  required double savingsRate,
  required double pressureRatio,
  required PressureLevel pressureLevel,
  required List<MonthlyStats> monthlyStats,
  required double liquidBalance,
  required double monthlyExpense,
  required double creditUtilizationPct,
}) {
  // ── 1. Savings Score (30 pts) ────────────────────────────────────────
  final int savingsScore;
  if (savingsRate >= 0.30) {
    savingsScore = 30;
  } else if (savingsRate >= 0.20) {
    savingsScore = 24;
  } else if (savingsRate >= 0.10) {
    savingsScore = 15;
  } else if (savingsRate > 0) {
    savingsScore = 8;
  } else {
    savingsScore = 2;
  }

  // ── 2. Debt Pressure Score (25 pts) ──────────────────────────────────
  final int debtScore;
  switch (pressureLevel) {
    case PressureLevel.healthy:
      debtScore = 25;
    case PressureLevel.moderate:
      debtScore = 15;
    case PressureLevel.high:
      debtScore = 5;
  }

  // ── 3. Spending Stability (20 pts) ───────────────────────────────────
  // Compare variance of last 3 months' expenses
  final int stabilityScore;
  if (monthlyStats.length >= 3) {
    final recent3 = monthlyStats.take(3).map((s) => s.expense).toList();
    final avg = recent3.reduce((a, b) => a + b) / recent3.length;
    if (avg > 0) {
      final variance = recent3
          .map((e) => ((e - avg) / avg).abs())
          .reduce((a, b) => a + b) / recent3.length;
      // variance < 0.15 = very stable, < 0.30 = moderate, else unstable
      if (variance < 0.15) {
        stabilityScore = 20;
      } else if (variance < 0.30) {
        stabilityScore = 12;
      } else {
        stabilityScore = 5;
      }
    } else {
      stabilityScore = 10; // no data baseline
    }
  } else {
    stabilityScore = 10; // not enough history
  }

  // ── 4. Liquidity Score (15 pts) ──────────────────────────────────────
  final int liquidityScore;
  final liquidMonths = monthlyExpense > 0
      ? liquidBalance / monthlyExpense
      : (liquidBalance > 0 ? 12.0 : 0.0);

  if (liquidMonths >= 6) {
    liquidityScore = 15;
  } else if (liquidMonths >= 3) {
    liquidityScore = 10;
  } else if (liquidMonths >= 1) {
    liquidityScore = 6;
  } else {
    liquidityScore = 2;
  }

  // ── 5. Credit Utilization (10 pts) ───────────────────────────────────
  final int utilizationScore;
  if (creditUtilizationPct <= 0) {
    utilizationScore = 10; // no credit cards or zero usage
  } else if (creditUtilizationPct < 30) {
    utilizationScore = 10;
  } else if (creditUtilizationPct < 70) {
    utilizationScore = 6;
  } else {
    utilizationScore = 2;
  }

  // ── Total ────────────────────────────────────────────────────────────
  final total = savingsScore + debtScore + stabilityScore +
      liquidityScore + utilizationScore;

  final String level;
  if (total >= 80) {
    level = 'Excellent';
  } else if (total >= 60) {
    level = 'Good';
  } else if (total >= 40) {
    level = 'Moderate';
  } else {
    level = 'Needs Attention';
  }

  // ── Insights (actionable) ────────────────────────────────────────────
  final insights = <HealthInsight>[];

  if (savingsScore >= 24) {
    insights.add(const HealthInsight(
      text: 'Strong savings rate',
      type: HealthInsightType.positive,
    ));
  } else if (savingsRate < 0.10) {
    insights.add(const HealthInsight(
      text: 'Increase savings to at least 20% of income',
      type: HealthInsightType.actionable,
    ));
  }

  if (debtScore >= 20) {
    insights.add(const HealthInsight(
      text: 'Debt under control',
      type: HealthInsightType.positive,
    ));
  } else if (pressureLevel == PressureLevel.high) {
    insights.add(const HealthInsight(
      text: 'Reduce debt obligations — they exceed 60% of income',
      type: HealthInsightType.actionable,
    ));
  }

  if (stabilityScore >= 15) {
    insights.add(const HealthInsight(
      text: 'Stable spending pattern',
      type: HealthInsightType.positive,
    ));
  } else if (stabilityScore <= 5) {
    insights.add(const HealthInsight(
      text: 'Spending varies significantly — set a monthly budget',
      type: HealthInsightType.warning,
    ));
  }

  if (liquidityScore >= 10) {
    insights.add(const HealthInsight(
      text: 'Good emergency fund coverage',
      type: HealthInsightType.positive,
    ));
  } else if (liquidMonths < 3) {
    insights.add(const HealthInsight(
      text: 'Build 3–6 months of expenses as emergency fund',
      type: HealthInsightType.actionable,
    ));
  }

  if (creditUtilizationPct > 70) {
    insights.add(const HealthInsight(
      text: 'Credit utilization above 70% — reduce card usage',
      type: HealthInsightType.actionable,
    ));
  } else if (creditUtilizationPct > 0 && creditUtilizationPct < 30) {
    insights.add(const HealthInsight(
      text: 'Healthy credit utilization',
      type: HealthInsightType.positive,
    ));
  }

  return FinancialHealthScore(
    score: total,
    level: level,
    breakdown: ScoreBreakdown(
      savingsScore: savingsScore,
      debtScore: debtScore,
      stabilityScore: stabilityScore,
      liquidityScore: liquidityScore,
      utilizationScore: utilizationScore,
    ),
    insights: insights,
  );
}

// ── Provider ─────────────────────────────────────────────────────────────

final financialHealthScoreProvider =
    FutureProvider<FinancialHealthScore>((ref) async {
  // Gather all inputs from existing providers
  final currentStats = await ref.watch(currentMonthStatsProvider.future);
  final monthlyStats = await ref.watch(monthlyStatsProvider.future);
  final pressure = await ref.watch(financialPressureProvider.future);
  final creditHealth = await ref.watch(creditHealthProvider.future);
  final accounts = await ref.watch(accountsProvider.future);

  // Liquid balance = sum of asset account balances
  final liquidBalance = accounts
      .where((a) => a.isAsset)
      .fold<double>(0, (sum, a) => sum + a.balance);

  final monthlyExpense = currentStats?.expense ?? 0;
  final savingsRate = currentStats?.savingsRate ?? 0;

  return computeHealthScore(
    savingsRate: savingsRate,
    pressureRatio: pressure.pressureRatio,
    pressureLevel: pressure.level,
    monthlyStats: monthlyStats,
    liquidBalance: liquidBalance,
    monthlyExpense: monthlyExpense,
    creditUtilizationPct: creditHealth.utilizationPct,
  );
});
