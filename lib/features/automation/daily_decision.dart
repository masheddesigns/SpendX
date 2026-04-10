import '../budget/smart_budget_engine.dart';
import '../cashflow/runway_engine.dart';

/// A single, clear daily financial decision for the user.
class DailyDecision {
  final String message;
  final DailyDecisionType type;

  const DailyDecision({required this.message, required this.type});
}

enum DailyDecisionType { positive, caution, warning, critical }

/// Generates ONE clear decision message based on all signals.
/// Priority: critical > warning > caution > positive.
class DailyDecisionEngine {
  DailyDecision decide({
    required Runway runway,
    required List<SmartBudget> budgets,
    required double savingsRate,
    required int healthScore,
    required int streakDays,
  }) {
    // 1. Critical: runway < 5 days
    if (runway.status == RunwayStatus.critical) {
      return const DailyDecision(
        message: 'Reduce spending immediately. Your runway is critically low.',
        type: DailyDecisionType.critical,
      );
    }

    // 2. Warning: runway < 15 days
    if (runway.status == RunwayStatus.warning) {
      return DailyDecision(
        message: '${runway.daysLeft} days of runway left. Limit non-essential spending today.',
        type: DailyDecisionType.warning,
      );
    }

    // 3. Over budget categories
    final overBudget = budgets.where((b) => b.isOverBudget).toList();
    if (overBudget.isNotEmpty) {
      final names = overBudget.take(2).map((b) => b.categoryName).join(' & ');
      return DailyDecision(
        message: 'You\'re over budget in $names. Try to hold spending there today.',
        type: DailyDecisionType.caution,
      );
    }

    // 4. Low savings
    if (savingsRate < 0.10 && savingsRate >= 0) {
      return const DailyDecision(
        message: 'Your savings rate is low. Can you skip one expense today?',
        type: DailyDecisionType.caution,
      );
    }

    // 5. Low health score
    if (healthScore < 50) {
      return const DailyDecision(
        message: 'Focus on building your financial health — small steps count.',
        type: DailyDecisionType.caution,
      );
    }

    // 6. Positive: everything is fine
    if (streakDays >= 7) {
      return DailyDecision(
        message: '$streakDays day streak! You\'re building strong financial habits.',
        type: DailyDecisionType.positive,
      );
    }

    return const DailyDecision(
      message: 'You\'re doing well. Keep tracking and stay within budget.',
      type: DailyDecisionType.positive,
    );
  }
}
