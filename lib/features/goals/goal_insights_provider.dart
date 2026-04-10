import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'behavior_engine.dart';
import 'goal_progress.dart';
import 'goal_providers.dart';

/// Behavioral nudges generated from active goals + their progress.
/// Consumed by Insights tab and AI assistant.
final goalInsightsProvider = FutureProvider<List<Nudge>>((ref) async {
  final goals = await ref.watch(activeGoalsProvider.future);
  if (goals.isEmpty) return [];

  final progressMap = <String, GoalProgress>{};
  for (final goal in goals) {
    progressMap[goal.id] = ref.read(goalProgressProvider(goal));
  }

  return BehaviorEngine().generate(
    goals: goals,
    progressMap: progressMap,
  );
});
