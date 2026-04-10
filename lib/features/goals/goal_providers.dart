import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/goal_repo.dart';
import '../../models/goal.dart';
import '../../models/goal_log.dart';
import '../transactions/providers/transaction_providers.dart';
import 'goal_progress.dart';

final goalRepoProvider = Provider<GoalRepo>((ref) => GoalRepo());

/// All goals (active and inactive).
final goalsProvider = FutureProvider<List<Goal>>((ref) {
  return ref.watch(goalRepoProvider).getAll();
});

/// Logs for a specific goal.
final goalLogsProvider =
    FutureProvider.family<List<GoalLog>, String>((ref, goalId) {
  return ref.watch(goalRepoProvider).getLogs(goalId);
});

/// Active goals only — derived from goalsProvider so invalidating
/// goalsProvider automatically refreshes this too.
final activeGoalsProvider = FutureProvider<List<Goal>>((ref) async {
  final all = await ref.watch(goalsProvider.future);
  return all.where((g) => g.isActive).toList()
    ..sort((a, b) => a.endDate.compareTo(b.endDate));
});

/// Progress for a single goal.
/// Computes live from transaction/credit data — never stale.
final goalProgressProvider =
    Provider.family<GoalProgress, Goal>((ref, goal) {
  final now = DateTime.now();
  final daysLeft = goal.endDate.difference(now).inDays.clamp(1, 99999);
  final totalDays = goal.endDate.difference(goal.startDate).inDays.clamp(1, 99999);
  final elapsedDays = now.difference(goal.startDate).inDays.clamp(0, totalDays);

  switch (goal.type) {
    case GoalType.savings:
      return _computeSavingsProgress(goal, daysLeft);

    case GoalType.spendingLimit:
      return _computeSpendingProgress(ref, goal, daysLeft, elapsedDays, totalDays);

    case GoalType.debtPayoff:
      return _computeDebtProgress(ref, goal, daysLeft);
  }
});

// ── Savings Progress ─────────────────────────────────────────────────────

GoalProgress _computeSavingsProgress(Goal goal, int daysLeft) {
  final progress = goal.targetAmount > 0
      ? (goal.currentAmount / goal.targetAmount).clamp(0.0, 1.0)
      : 0.0;
  final remaining = (goal.targetAmount - goal.currentAmount).clamp(0.0, double.infinity);
  final requiredDaily = daysLeft > 0 ? remaining / daysLeft : remaining;

  return GoalProgress(
    progressPct: progress,
    remaining: remaining,
    daysLeft: daysLeft,
    requiredDaily: requiredDaily,
    isCompleted: goal.currentAmount >= goal.targetAmount,
    isOverBudget: false,
  );
}

// ── Spending Limit Progress ──────────────────────────────────────────────

GoalProgress _computeSpendingProgress(
  Ref ref,
  Goal goal,
  int daysLeft,
  int elapsedDays,
  int totalDays,
) {
  // Calculate actual spending for the goal's category in current period
  final transactions = ref.watch(transactionsProvider).valueOrNull ?? [];
  double spent = 0;
  for (final tx in transactions) {
    if (tx.type != 'expense') continue;
    if (tx.date.isBefore(goal.startDate)) continue;
    if (tx.date.isAfter(goal.endDate)) continue;
    if (goal.categoryId != null && tx.categoryId != goal.categoryId) continue;
    spent += tx.amount;
  }

  final progress = goal.targetAmount > 0
      ? (spent / goal.targetAmount).clamp(0.0, 2.0)
      : 0.0;
  final remaining = (goal.targetAmount - spent).clamp(0.0, double.infinity);

  // How much can be spent per remaining day
  final dailyBudget = daysLeft > 0 ? remaining / daysLeft : 0.0;

  return GoalProgress(
    progressPct: progress.clamp(0.0, 1.0),
    remaining: remaining,
    daysLeft: daysLeft,
    requiredDaily: dailyBudget,
    isCompleted: false,
    isOverBudget: spent > goal.targetAmount,
    currentSpent: spent,
  );
}

// ── Debt Payoff Progress ─────────────────────────────────────────────────

GoalProgress _computeDebtProgress(Ref ref, Goal goal, int daysLeft) {
  // For debt goals, currentAmount represents how much has been paid off.
  // Progress = paid / target
  final progress = goal.targetAmount > 0
      ? (goal.currentAmount / goal.targetAmount).clamp(0.0, 1.0)
      : 0.0;
  final remaining = (goal.targetAmount - goal.currentAmount).clamp(0.0, double.infinity);
  final requiredDaily = daysLeft > 0 ? remaining / daysLeft : remaining;

  return GoalProgress(
    progressPct: progress,
    remaining: remaining,
    daysLeft: daysLeft,
    requiredDaily: requiredDaily,
    isCompleted: goal.currentAmount >= goal.targetAmount,
    isOverBudget: false,
  );
}
