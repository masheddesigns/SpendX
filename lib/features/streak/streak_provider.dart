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
/// Safe to call multiple times — dynamically derived from ledger history and signals.
final evaluateStreakProvider = FutureProvider<Streak>((ref) async {
  final repo = ref.read(streakRepoProvider);
  final saved = await repo.get();

  final transactions = await ref.read(transactionsProvider.future);
  final anomalies = await ref.read(anomalyProvider.future);
  final goals = await ref.read(activeGoalsProvider.future);
  final healthScore = await ref.read(financialHealthScoreProvider.future);

  final now = DateTime.now();

  // Dynamic ledger-based calculation
  var currentStreak = StreakEngine().computeStreak(
    transactions: transactions,
    now: now,
    savedStreak: saved.current,
    lastEvaluated: saved.lastEvaluated,
  );

  // Today win check
  final todayTxCount = transactions.where((t) {
    if (t.isDeleted) return false;
    final local = t.date.toLocal();
    return local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
  }).length;

  final progressMap = <String, GoalProgress>{};
  for (final goal in goals) {
    progressMap[goal.id] = ref.read(goalProgressProvider(goal));
  }

  final wonToday = StreakEngine().didUserWinToday(
    anomalies: anomalies,
    goals: goals,
    progressMap: progressMap,
    todayTransactionCount: todayTxCount,
    healthScore: healthScore.score,
  );

  if (wonToday && currentStreak == 0) {
    currentStreak = 1;
  }

  final bestStreak = currentStreak > saved.best ? currentStreak : saved.best;
  final updated = Streak(
    current: currentStreak,
    best: bestStreak,
    lastEvaluated: now,
  );

  if (updated.current != saved.current || updated.best != saved.best) {
    await repo.save(updated);
    debugPrint('🔥 Streak saved: current=${updated.current}, best=${updated.best}');
  }

  return updated;
});
