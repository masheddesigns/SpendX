import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/streak_repo.dart';
import '../../models/streak.dart';
import '../anomaly/anomaly_provider.dart';
import '../goals/goal_progress.dart';
import '../goals/goal_providers.dart';
import '../health/health_score_provider.dart';
import '../transactions/providers/transaction_providers.dart';
import 'streak_engine.dart';

final streakRepoProvider = Provider<StreakRepo>((ref) => StreakRepo());

/// Current streak state.
final streakProvider = FutureProvider<Streak>((ref) {
  return ref.watch(streakRepoProvider).get();
});

/// Evaluates and updates the streak for today.
/// Safe to call multiple times — deduplicates per day.
final evaluateStreakProvider = FutureProvider<Streak>((ref) async {
  final repo = ref.read(streakRepoProvider);
  var streak = await repo.get();

  // Already evaluated today — no double-counting
  if (streak.evaluatedToday) {
    debugPrint('🔥 Streak already evaluated today: ${streak.current}');
    return streak;
  }

  // Gather all signals
  final anomalies = await ref.read(anomalyProvider.future);
  final goals = await ref.read(activeGoalsProvider.future);
  final healthScore = await ref.read(financialHealthScoreProvider.future);
  final transactions = await ref.read(transactionsProvider.future);

  // Count today's transactions
  final now = DateTime.now();
  final todayStart = DateTime(now.year, now.month, now.day);
  final todayTxCount = transactions.where((t) =>
      !t.date.isBefore(todayStart)).length;

  // Build progress map for goals
  final progressMap = <String, GoalProgress>{};
  for (final goal in goals) {
    progressMap[goal.id] = ref.read(goalProgressProvider(goal));
  }

  // Evaluate
  final won = StreakEngine().didUserWinToday(
    anomalies: anomalies,
    goals: goals,
    progressMap: progressMap,
    todayTransactionCount: todayTxCount,
    healthScore: healthScore.score,
  );

  if (won) {
    streak = streak.increment();
    debugPrint('🔥 Streak incremented to ${streak.current} (best: ${streak.best})');
  } else {
    streak = streak.reset();
    debugPrint('🔥 Streak reset to 0');
  }

  await repo.save(streak);
  return streak;
});
