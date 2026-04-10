import '../../utils/app_format.dart';
import '../budget/smart_budget_engine.dart';
import '../cashflow/runway_engine.dart';
import '../goals/goal_progress.dart';
import '../../models/goal.dart';

// ── Models ───────────────────────────────────────────────────────────────

enum NudgePriority { critical, high, medium, low }
enum NudgeType { warning, tip, action }

class SmartNudge {
  final String title;
  final String message;
  final NudgeType type;
  final NudgePriority priority;

  const SmartNudge({
    required this.title,
    required this.message,
    required this.type,
    required this.priority,
  });
}

class SaveSuggestion {
  final double amount;
  final String message;

  const SaveSuggestion({required this.amount, required this.message});
}

class BudgetAdjustment {
  final String categoryName;
  final double oldLimit;
  final double newLimit;
  final String reason;

  const BudgetAdjustment({
    required this.categoryName,
    required this.oldLimit,
    required this.newLimit,
    required this.reason,
  });
}

// ── Auto-Save Engine ─────────────────────────────────────────────────────

class AutoSaveEngine {
  SaveSuggestion? suggest({
    required double monthlyIncome,
    required double monthlyExpense,
  }) {
    if (monthlyIncome <= 0) return null;

    final surplus = monthlyIncome - monthlyExpense;
    if (surplus < 1000) return null;

    final saveAmount = (surplus * 0.3).roundToDouble();
    return SaveSuggestion(
      amount: saveAmount,
      message: 'You have ${AppFormat.currency(surplus)} surplus this month. '
          'Save ${AppFormat.currency(saveAmount)} to build your cushion.',
    );
  }
}

// ── Budget Adjuster ──────────────────────────────────────────────────────

class BudgetAdjuster {
  static const _discretionary = {
    'Food', 'Shopping', 'Entertainment', 'Travel', 'Subscriptions',
  };

  List<BudgetAdjustment> adjust({
    required List<SmartBudget> budgets,
    required Runway runway,
  }) {
    final adjustments = <BudgetAdjustment>[];

    // Rule 1: If runway is low, cut discretionary by 20%
    if (runway.status == RunwayStatus.critical ||
        runway.status == RunwayStatus.warning) {
      for (final b in budgets) {
        if (_discretionary.contains(b.categoryName)) {
          final newLimit = (b.limit * 0.8).roundToDouble();
          if (newLimit < b.limit) {
            adjustments.add(BudgetAdjustment(
              categoryName: b.categoryName,
              oldLimit: b.limit,
              newLimit: newLimit,
              reason: 'Runway is ${runway.daysLeft} days — reducing discretionary spend',
            ));
          }
        }
      }
      return adjustments;
    }

    // Rule 2: Tighten over-budget categories by 10%
    for (final b in budgets) {
      if (b.isOverBudget) {
        final newLimit = (b.limit * 0.9).roundToDouble();
        adjustments.add(BudgetAdjustment(
          categoryName: b.categoryName,
          oldLimit: b.limit,
          newLimit: newLimit,
          reason: '${b.categoryName} is over budget',
        ));
      }
    }

    return adjustments;
  }
}

// ── Smart Nudge Engine ───────────────────────────────────────────────────

class NudgeEngine {
  /// Generates up to 3 prioritized nudges from all system signals.
  List<SmartNudge> generate({
    required Runway runway,
    required List<SmartBudget> budgets,
    required double savingsRate,
    required double creditUtilizationPct,
    required List<Goal> goals,
    required Map<String, GoalProgress> goalProgress,
    required int healthScore,
  }) {
    final nudges = <SmartNudge>[];

    // 1. Cashflow risk (highest priority)
    if (runway.status == RunwayStatus.critical) {
      nudges.add(const SmartNudge(
        title: 'Critical: Low runway',
        message: 'Reduce spending immediately or ensure income arrives soon.',
        type: NudgeType.warning,
        priority: NudgePriority.critical,
      ));
    } else if (runway.status == RunwayStatus.warning) {
      nudges.add(SmartNudge(
        title: '${runway.daysLeft} days of runway',
        message: 'Consider cutting non-essential expenses.',
        type: NudgeType.warning,
        priority: NudgePriority.high,
      ));
    }

    // 2. Over-budget categories
    final overBudget = budgets.where((b) => b.isOverBudget).toList();
    if (overBudget.isNotEmpty) {
      final names = overBudget.take(2).map((b) => b.categoryName).join(', ');
      nudges.add(SmartNudge(
        title: 'Over budget in $names',
        message: 'Reduce spending to stay within limits.',
        type: NudgeType.warning,
        priority: NudgePriority.high,
      ));
    }

    // 3. Low savings rate
    if (savingsRate < 0.10 && savingsRate >= 0) {
      nudges.add(const SmartNudge(
        title: 'Low savings rate',
        message: 'Try saving at least 10% of your income.',
        type: NudgeType.tip,
        priority: NudgePriority.medium,
      ));
    }

    // 4. High credit utilization
    if (creditUtilizationPct > 80) {
      nudges.add(const SmartNudge(
        title: 'High credit usage',
        message: 'Pay down your credit card to avoid interest charges.',
        type: NudgeType.action,
        priority: NudgePriority.high,
      ));
    }

    // 5. Goal at risk
    for (final goal in goals) {
      final progress = goalProgress[goal.id];
      if (progress != null && progress.isAtRisk) {
        nudges.add(SmartNudge(
          title: '${goal.title} at risk',
          message: 'Increase daily contribution to stay on track.',
          type: NudgeType.action,
          priority: NudgePriority.medium,
        ));
        break; // Only one goal nudge
      }
    }

    // 6. Health score nudge
    if (healthScore < 40) {
      nudges.add(const SmartNudge(
        title: 'Financial health needs attention',
        message: 'Focus on reducing debt and building savings.',
        type: NudgeType.tip,
        priority: NudgePriority.medium,
      ));
    }

    // Sort by priority and return max 3
    nudges.sort((a, b) => a.priority.index.compareTo(b.priority.index));
    return nudges.take(3).toList();
  }
}
