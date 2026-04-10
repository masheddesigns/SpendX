import '../../features/anomaly/anomaly_model.dart';
import '../../models/goal.dart';
import '../../features/goals/goal_progress.dart';

/// Evaluates whether the user "won" today.
/// Pure logic — no DB, no async, no side effects.
///
/// Win conditions (ALL must be true):
///   1. No high-severity anomalies
///   2. No spending limit goals over budget
///   3. At least one positive signal:
///      - has transactions today
///      - OR made goal progress
///      - OR health score >= 60
class StreakEngine {
  bool didUserWinToday({
    required List<Anomaly> anomalies,
    required List<Goal> goals,
    required Map<String, GoalProgress> progressMap,
    required int todayTransactionCount,
    required int healthScore,
  }) {
    // Condition 1: No high-severity anomalies
    final hasHighAnomaly = anomalies.any(
      (a) => a.severity == AnomalySeverity.high,
    );
    if (hasHighAnomaly) return false;

    // Condition 2: No spending goals over budget
    for (final goal in goals) {
      if (goal.type == GoalType.spendingLimit) {
        final progress = progressMap[goal.id];
        if (progress != null && progress.isOverBudget) return false;
      }
    }

    // Condition 3: At least one positive signal
    final hasTransactions = todayTransactionCount > 0;
    final hasGoalProgress = goals.isNotEmpty;
    final healthGood = healthScore >= 60;

    return hasTransactions || hasGoalProgress || healthGood;
  }
}
