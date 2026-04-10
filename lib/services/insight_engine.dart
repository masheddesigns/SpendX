import 'package:flutter/material.dart';
import '../models/analytics_summary.dart';
import '../models/insight.dart';

class InsightEngine {
  List<Insight> generate(AnalyticsSummary summary) {
    if (summary.recentTransactions.isEmpty) return [];

    final insights = <Insight>[];

    // ── 1. Overspending Warning ──────────────────────────────────────
    if (summary.monthlyExpense > summary.monthlyIncome &&
        summary.monthlyIncome > 0) {
      final excess = summary.monthlyExpense - summary.monthlyIncome;
      insights.add(Insight(
        title: 'Spending exceeds income',
        description:
            'You\'ve spent ${_formatAmount(excess)} more than you\'ve earned '
            'this month. Review discretionary expenses.',
        type: InsightType.warning,
        icon: Icons.warning_amber_rounded,
      ));
    }

    // ── 2. Month-over-month trend ────────────────────────────────────
    if (summary.previousMonthExpense > 0 && summary.monthlyExpense > 0) {
      final change = summary.monthlyExpense - summary.previousMonthExpense;
      final changePct =
          (change / summary.previousMonthExpense * 100).abs().round();

      if (change > 0 && changePct >= 10) {
        insights.add(Insight(
          title: 'Spending up $changePct% vs last month',
          description:
              'You\'ve spent ${_formatAmount(change)} more than last month. '
              'Check if any new recurring costs crept in.',
          type: InsightType.info,
          icon: Icons.trending_up_rounded,
        ));
      } else if (change < 0 && changePct >= 10) {
        insights.add(Insight(
          title: 'Spending down $changePct% vs last month',
          description:
              'Great discipline! You spent ${_formatAmount(change.abs())} '
              'less than last month.',
          type: InsightType.success,
          icon: Icons.trending_down_rounded,
        ));
      }
    }

    // ── 3. Savings rate ──────────────────────────────────────────────
    if (summary.monthlyIncome > 0) {
      final savings = summary.monthlyIncome - summary.monthlyExpense;
      final rate = (savings / summary.monthlyIncome * 100).round();

      if (rate >= 30) {
        insights.add(Insight(
          title: 'Excellent savings: $rate%',
          description:
              'You\'re saving ${_formatAmount(savings)} this month. '
              'That\'s above the recommended 20% threshold.',
          type: InsightType.success,
          icon: Icons.auto_awesome_rounded,
        ));
      } else if (rate >= 10 && rate < 30) {
        insights.add(Insight(
          title: 'Savings rate: $rate%',
          description:
              'You\'re saving ${_formatAmount(savings)} this month. '
              'Aim for 20-30% to build a stronger safety net.',
          type: InsightType.tip,
          icon: Icons.savings_rounded,
        ));
      } else if (rate > 0 && rate < 10) {
        insights.add(Insight(
          title: 'Low savings rate: $rate%',
          description:
              'Only ${_formatAmount(savings)} saved this month. '
              'Consider cutting back on non-essentials.',
          type: InsightType.warning,
          icon: Icons.savings_outlined,
        ));
      }
    }

    // ── 4. Top category concentration ────────────────────────────────
    if (summary.categorySpending.isNotEmpty && summary.monthlyExpense > 0) {
      final topEntry = summary.categorySpending.entries
          .reduce((a, b) => a.value > b.value ? a : b);
      final ratio = topEntry.value / summary.monthlyExpense;

      if (ratio > 0.45) {
        final catName = summary.categoriesMap[topEntry.key]?.name ??
            'One category';
        insights.add(Insight(
          title: '$catName dominates spending',
          description:
              '$catName accounts for ${(ratio * 100).round()}% of '
              'your total expenses (${_formatAmount(topEntry.value)}).',
          type: InsightType.info,
          icon: Icons.pie_chart_outline_rounded,
        ));
      }
    }

    // ── 5. Budget pressure ───────────────────────────────────────────
    for (final budget in summary.budgetProgress) {
      if (budget.budget.limit <= 0) continue;
      final progress = budget.spent / budget.budget.limit;

      if (progress >= 1.0) {
        insights.add(Insight(
          title: '${budget.category.name} budget exceeded',
          description:
              'You\'ve spent ${_formatAmount(budget.spent)} against a '
              '${_formatAmount(budget.budget.limit)} budget.',
          type: InsightType.warning,
          icon: Icons.report_rounded,
        ));
      } else if (progress > 0.85) {
        final remaining = budget.budget.limit - budget.spent;
        insights.add(Insight(
          title: '${budget.category.name} nearly exhausted',
          description:
              '${(progress * 100).round()}% used. '
              'Only ${_formatAmount(remaining)} remaining.',
          type: InsightType.tip,
          icon: Icons.speed_rounded,
        ));
      }
    }

    // ── 6. No income detected ────────────────────────────────────────
    if (summary.monthlyIncome == 0 && summary.monthlyExpense > 0) {
      insights.add(const Insight(
        title: 'No income recorded this month',
        description:
            'Only expenses detected so far. Add income transactions '
            'for accurate savings tracking.',
        type: InsightType.info,
        icon: Icons.info_outline_rounded,
      ));
    }

    // ── 7. Spending velocity (daily burn rate) ───────────────────────
    if (summary.monthlyExpense > 0) {
      final now = DateTime.now();
      final dayOfMonth = now.day;
      final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
      final dailyBurn = summary.monthlyExpense / dayOfMonth;
      final projectedMonthly = dailyBurn * daysInMonth;

      if (projectedMonthly > summary.monthlyIncome * 1.2 &&
          summary.monthlyIncome > 0 &&
          dayOfMonth >= 7) {
        insights.add(Insight(
          title: 'On track to overspend',
          description:
              'At ${_formatAmount(dailyBurn)}/day, you\'re projected to '
              'spend ${_formatAmount(projectedMonthly)} by month end.',
          type: InsightType.warning,
          icon: Icons.local_fire_department_rounded,
        ));
      }
    }

    return insights;
  }

  String _formatAmount(double amount) {
    if (amount >= 100000) {
      return '${(amount / 100000).toStringAsFixed(1)}L';
    } else if (amount >= 1000) {
      return '${(amount / 1000).toStringAsFixed(1)}K';
    }
    return amount.toStringAsFixed(0);
  }
}
