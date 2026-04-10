import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../budget/budget_providers.dart';
import '../goals/goal_progress.dart';
import '../cashflow/runway_provider.dart';
import '../dashboard/insights_providers.dart';
import '../goals/goal_providers.dart';
import '../health/health_score_provider.dart';
import '../liabilities/providers/credit_health_providers.dart';
import '../streak/streak_provider.dart';
import 'automation_engine.dart';
import 'daily_decision.dart';

export 'daily_decision.dart' show DailyDecision, DailyDecisionType;

/// Auto-save suggestion based on income surplus.
final saveSuggestionProvider = FutureProvider<SaveSuggestion?>((ref) async {
  final stats = await ref.watch(currentMonthStatsProvider.future);
  if (stats == null) return null;

  return AutoSaveEngine().suggest(
    monthlyIncome: stats.income,
    monthlyExpense: stats.expense,
  );
});

/// Budget tightening recommendations.
final budgetAdjustmentProvider =
    FutureProvider<List<BudgetAdjustment>>((ref) async {
  final budgets = await ref.watch(smartBudgetProvider.future);
  final runway = await ref.watch(runwayProvider.future);

  return BudgetAdjuster().adjust(budgets: budgets, runway: runway);
});

/// Prioritized smart nudges from all system signals.
final smartNudgesProvider = FutureProvider<List<SmartNudge>>((ref) async {
  final runway = await ref.watch(runwayProvider.future);
  final budgets = await ref.watch(smartBudgetProvider.future);
  final stats = await ref.watch(currentMonthStatsProvider.future);
  final credit = await ref.watch(creditHealthProvider.future);
  final health = await ref.watch(financialHealthScoreProvider.future);
  final goals = await ref.watch(activeGoalsProvider.future);

  final progressMap = <String, GoalProgress>{};
  for (final goal in goals) {
    progressMap[goal.id] = ref.read(goalProgressProvider(goal));
  }

  return NudgeEngine().generate(
    runway: runway,
    budgets: budgets,
    savingsRate: stats?.savingsRate ?? 0,
    creditUtilizationPct: credit.utilizationPct,
    goals: goals,
    goalProgress: progressMap,
    healthScore: health.score,
  );
});

/// Today's single decision — the ONE thing the user should focus on.
final dailyDecisionProvider = FutureProvider<DailyDecision>((ref) async {
  final runway = await ref.watch(runwayProvider.future);
  final budgets = await ref.watch(smartBudgetProvider.future);
  final stats = await ref.watch(currentMonthStatsProvider.future);
  final health = await ref.watch(financialHealthScoreProvider.future);
  final streak = await ref.watch(streakProvider.future);

  return DailyDecisionEngine().decide(
    runway: runway,
    budgets: budgets,
    savingsRate: stats?.savingsRate ?? 0,
    healthScore: health.score,
    streakDays: streak.current,
  );
});
