import '../../features/anomaly/anomaly_model.dart';
import '../../models/goal.dart';
import '../../models/transaction.dart';
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

  /// Evaluates consecutive active days dynamically from the transaction ledger.
  ///
  /// Guarantees:
  /// 1. Timezone-normalized local calendar day evaluation.
  /// 2. If the user hasn't logged an activity yet today, yesterday's streak is
  ///    preserved as active (does not reset until a full calendar day is missed).
  /// 3. As soon as activity is recorded today, the streak advances cleanly.
  int computeStreak({
    required List<Transaction> transactions,
    required DateTime now,
    int savedStreak = 0,
    DateTime? lastEvaluated,
  }) {
    final activeDays = <String>{};
    for (final t in transactions) {
      if (t.isDeleted) continue;
      final d = t.date.toLocal();
      activeDays.add(
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
      );
    }

    final today = DateTime(now.year, now.month, now.day);
    String dayKey(DateTime dt) =>
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

    final hasToday = activeDays.contains(dayKey(today));
    final yesterday = today.subtract(const Duration(days: 1));
    final hasYesterday = activeDays.contains(dayKey(yesterday));

    // If neither today nor yesterday had any activity, streak has lapsed
    if (!hasToday && !hasYesterday) {
      return 0;
    }

    // Traverse backward consecutively
    int consecutive = 0;
    var cursor = hasToday ? today : yesterday;
    while (activeDays.contains(dayKey(cursor))) {
      consecutive++;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    // If transactions only contain a rolling window, preserve saved streak
    if (savedStreak > consecutive && lastEvaluated != null) {
      final lastEvalDay = DateTime(
        lastEvaluated.year,
        lastEvaluated.month,
        lastEvaluated.day,
      );
      final diff = today.difference(lastEvalDay).inDays;
      if (diff == 0) {
        consecutive = savedStreak;
      } else if (diff == 1 && hasToday) {
        consecutive = savedStreak + 1;
      } else if (diff == 1 && !hasToday) {
        consecutive = savedStreak;
      }
    }

    return consecutive;
  }
}
