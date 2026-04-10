import '../../models/goal.dart';
import '../../utils/app_format.dart';
import 'goal_progress.dart';

/// Nudge types for UI styling.
enum NudgeType { positive, warning, actionable }

class Nudge {
  final String text;
  final NudgeType type;

  const Nudge({required this.text, required this.type});
}

/// Generates behavioral nudges from goal progress.
/// Pure computation — no DB, no async, no side effects.
class BehaviorEngine {
  /// Generate up to 3 nudges based on active goals and their progress.
  List<Nudge> generate({
    required List<Goal> goals,
    required Map<String, GoalProgress> progressMap,
  }) {
    final nudges = <Nudge>[];

    for (final goal in goals) {
      final progress = progressMap[goal.id];
      if (progress == null) continue;

      switch (goal.type) {
        case GoalType.savings:
          _savingsNudges(goal, progress, nudges);
        case GoalType.spendingLimit:
          _spendingNudges(goal, progress, nudges);
        case GoalType.debtPayoff:
          _debtNudges(goal, progress, nudges);
      }

      if (nudges.length >= 3) break;
    }

    return nudges.take(3).toList();
  }

  void _savingsNudges(Goal goal, GoalProgress p, List<Nudge> out) {
    if (p.isCompleted) {
      out.add(Nudge(
        text: '${goal.title} completed! You saved ${AppFormat.currency(goal.targetAmount)}.',
        type: NudgeType.positive,
      ));
      return;
    }

    if (p.progressPct >= 0.8) {
      out.add(Nudge(
        text: '${goal.title}: Almost there! ${AppFormat.currency(p.remaining)} to go.',
        type: NudgeType.positive,
      ));
    } else if (p.daysLeft < 14 && p.progressPct < 0.5) {
      out.add(Nudge(
        text: '${goal.title}: Need ${AppFormat.currency(p.requiredDaily)}/day to stay on track.',
        type: NudgeType.actionable,
      ));
    } else if (p.progressPct > 0.5) {
      out.add(Nudge(
        text: '${goal.title}: ${(p.progressPct * 100).round()}% done. Keep going!',
        type: NudgeType.positive,
      ));
    }
  }

  void _spendingNudges(Goal goal, GoalProgress p, List<Nudge> out) {
    if (p.isOverBudget) {
      final over = (p.currentSpent ?? 0) - goal.targetAmount;
      out.add(Nudge(
        text: '${goal.title}: Over budget by ${AppFormat.currency(over)}.',
        type: NudgeType.warning,
      ));
      return;
    }

    if (p.progressPct >= 0.8) {
      out.add(Nudge(
        text: '${goal.title}: ${(p.progressPct * 100).round()}% used. '
            '${AppFormat.currency(p.remaining)} left for ${p.daysLeft} days.',
        type: NudgeType.warning,
      ));
    } else if (p.progressPct < 0.5 && p.daysLeft > 7) {
      out.add(Nudge(
        text: '${goal.title}: On track. ${AppFormat.currency(p.requiredDaily)}/day available.',
        type: NudgeType.positive,
      ));
    }
  }

  void _debtNudges(Goal goal, GoalProgress p, List<Nudge> out) {
    if (p.isCompleted) {
      out.add(Nudge(
        text: '${goal.title} cleared! Debt-free on this goal.',
        type: NudgeType.positive,
      ));
      return;
    }

    if (p.progressPct >= 0.5) {
      out.add(Nudge(
        text: '${goal.title}: ${(p.progressPct * 100).round()}% paid off. '
            '${AppFormat.currency(p.remaining)} to go.',
        type: NudgeType.positive,
      ));
    } else if (p.daysLeft < 30) {
      out.add(Nudge(
        text: '${goal.title}: ${AppFormat.currency(p.requiredDaily)}/day needed to clear on time.',
        type: NudgeType.actionable,
      ));
    }
  }
}
