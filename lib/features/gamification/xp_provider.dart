import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/providers/account_providers.dart';
import '../budget/budget_providers.dart';
import '../goals/goal_providers.dart';
import '../streak/streak_provider.dart';
import '../transactions/providers/transaction_providers.dart';
import 'xp_engine.dart';

export 'xp_engine.dart' show UserXP, Achievement;

/// User XP and level computed from all activity signals.
final xpProvider = FutureProvider<UserXP>((ref) async {
  final txns = await ref.watch(transactionsProvider.future);
  final streak = await ref.watch(streakProvider.future);
  final goals = await ref.watch(goalsProvider.future);
  final budgets = await ref.watch(smartBudgetProvider.future);

  final goalsCompleted = goals.where((g) => !g.isActive).length;
  final budgetsRespected = budgets.where((b) => !b.isOverBudget).length;

  // Estimate "clean days" from streak history
  final cleanDays = streak.best + streak.current;

  return XPEngine().compute(
    totalTransactions: txns.length,
    currentStreak: streak.current,
    bestStreak: streak.best,
    goalsCompleted: goalsCompleted,
    daysWithNoAnomalies: cleanDays,
    budgetsRespected: budgetsRespected,
  );
});

/// Achievement list.
final achievementsProvider = FutureProvider<List<Achievement>>((ref) async {
  final txns = await ref.watch(transactionsProvider.future);
  final streak = await ref.watch(streakProvider.future);
  final goals = await ref.watch(goalsProvider.future);
  final accounts = await ref.watch(accountsProvider.future);

  final goalsCompleted = goals.where((g) => !g.isActive).length;
  final totalSaved = accounts
      .where((a) => a.isAsset)
      .fold<double>(0, (sum, a) => sum + a.balance);

  return XPEngine().achievements(
    totalTransactions: txns.length,
    bestStreak: streak.best,
    goalsCompleted: goalsCompleted,
    totalSaved: totalSaved,
  );
});
