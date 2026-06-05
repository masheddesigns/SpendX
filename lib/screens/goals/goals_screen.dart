import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/goals/goal_progress.dart';
import '../../features/goals/goal_providers.dart';
import '../../features/goals/goal_insights_provider.dart';
import '../../features/goals/behavior_engine.dart';
import '../../models/goal.dart';
import '../../utils/app_format.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../shared/widgets/error_state_widget.dart';
import 'add_goal_screen.dart';
import 'goal_detail_screen.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/app_tap_scale.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalsAsync = ref.watch(activeGoalsProvider);
    final nudgesAsync = ref.watch(goalInsightsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Goals')),
      body: goalsAsync.when(
        loading: () => const SkeletonLoader.transactions(),
        error: (err, _) => ErrorStateWidget(
          error: err,
          onRetry: () => ref.invalidate(activeGoalsProvider),
        ),
        data: (goals) {
          if (goals.isEmpty) return _buildEmptyState(context);

          final nudges = nudgesAsync.valueOrNull ?? [];

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(goalsProvider);
              ref.invalidate(goalInsightsProvider);
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Nudges banner
                if (nudges.isNotEmpty) ...[
                  _NudgesBanner(nudges: nudges),
                  const SizedBox(height: 16),
                ],

                // Goal cards
                for (final goal in goals) ...[
                  GoalCard(
                    goal: goal,
                    progress: ref.watch(goalProgressProvider(goal)),
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        AppPageRoute(
                          builder: (_) => GoalDetailScreen(goal: goal),
                        ),
                      );
                      if (result == true) {
                        ref.invalidate(goalsProvider);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await Navigator.push(
            context,
            AppPageRoute(builder: (_) => const AddGoalScreen()),
          );
          if (result == true) {
            ref.invalidate(goalsProvider);
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('Add Goal'),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.flag_rounded,
            size: 64,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'No goals yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Set a savings target, spending limit, or debt payoff goal.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Goal Card ────────────────────────────────────────────────────────────

class GoalCard extends StatelessWidget {
  final Goal goal;
  final GoalProgress progress;
  final VoidCallback? onTap;

  const GoalCard({
    super.key,
    required this.goal,
    required this.progress,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = progress.progressPct.clamp(0.0, 1.0);
    final barColor = _progressColor(pct, progress.isOverBudget);
    final pctText = (pct * 100).round();

    final IconData typeIcon;
    switch (goal.type) {
      case GoalType.savings:
        typeIcon = Icons.savings_rounded;
      case GoalType.spendingLimit:
        typeIcon = Icons.speed_rounded;
      case GoalType.debtPayoff:
        typeIcon = Icons.credit_score_rounded;
    }

    return AppTapScale(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(typeIcon, size: 18, color: barColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      goal.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: barColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$pctText%',
                      style: TextStyle(
                        color: barColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 8,
                  backgroundColor: cs.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(barColor),
                ),
              ),

              const SizedBox(height: 8),

              // Stats row
              Row(
                children: [
                  Expanded(
                    child: Text(
                      progress.isCompleted
                          ? 'Completed!'
                          : progress.isOverBudget
                              ? 'Over budget by ${AppFormat.currency((progress.currentSpent ?? 0) - goal.targetAmount)}'
                              : '${AppFormat.currency(progress.remaining)} left',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '${progress.daysLeft} days left',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),

              // Daily requirement
              if (!progress.isCompleted && progress.requiredDaily > 0) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.bolt_rounded,
                      size: 14,
                      color: progress.isBehindSchedule
                          ? cs.error
                          : const Color(0xFFF59E0B),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      goal.type == GoalType.spendingLimit
                          ? '${AppFormat.currency(progress.requiredDaily)}/day available'
                          : '${AppFormat.currency(progress.requiredDaily)}/day needed',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: progress.isBehindSchedule
                            ? cs.error
                            : const Color(0xFFF59E0B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Color _progressColor(double pct, bool isOverBudget) {
    if (isOverBudget) return const Color(0xFFEF4444);
    if (pct >= 0.7) return const Color(0xFF22C55E);
    if (pct >= 0.4) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }
}

// ── Nudges Banner ────────────────────────────────────────────────────────

class _NudgesBanner extends StatelessWidget {
  final List<Nudge> nudges;

  const _NudgesBanner({required this.nudges});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final nudge in nudges)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      nudge.type == NudgeType.positive
                          ? Icons.check_circle_rounded
                          : nudge.type == NudgeType.warning
                              ? Icons.warning_amber_rounded
                              : Icons.lightbulb_outline_rounded,
                      size: 16,
                      color: nudge.type == NudgeType.positive
                          ? const Color(0xFF22C55E)
                          : nudge.type == NudgeType.warning
                              ? const Color(0xFFF59E0B)
                              : cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        nudge.text,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
