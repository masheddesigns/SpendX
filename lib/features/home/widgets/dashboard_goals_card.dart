import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../screens/goals/goal_detail_screen.dart';
import '../../../screens/goals/goals_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_format.dart';
import '../../goals/goal_providers.dart';

/// Savings Landmarks: Mindful waypoint journeys for active goals.
///
/// Replaces generic horizontal progress bars with an organic milestone
/// path showing progress, target horizons, and encouraging feedback.
class DashboardGoalsCard extends ConsumerWidget {
  const DashboardGoalsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final goalsAsync = ref.watch(activeGoalsProvider);

    final goals = goalsAsync.valueOrNull ?? [];
    if (goals.isEmpty) return const SizedBox.shrink();

    final displayGoals = goals.take(2).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF161922), Color(0xFF13151E)]
                : const [Color(0xFFFFFFFF), Color(0xFFFAF7F0)],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.10)
                : const Color(0xFFECE5D8),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.30)
                  : const Color(0x0A1C1917),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.savings_outlined,
                      size: 16,
                      color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'SAVINGS GOALS',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                      ),
                    ),
                  ],
                ),
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      AppPageRoute(builder: (_) => const GoalsScreen()),
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'All Milestones',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 15,
                        color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Goals Journey
            Column(
              children: List.generate(displayGoals.length, (index) {
                final goal = displayGoals[index];
                final target = goal.targetAmount;
                final saved = goal.currentAmount;
                final progress = target > 0 ? (saved / target).clamp(0.0, 1.0) : 0.0;
                final percentText = '${(progress * 100).toInt()}%';

                final isCompleted = saved >= target && target > 0;
                final statusLabel = isCompleted
                    ? 'Completed'
                    : progress > 0.5
                        ? 'Halfway'
                        : 'On Track';

                return InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    Navigator.push(
                      context,
                      AppPageRoute(
                        builder: (_) => GoalDetailScreen(goal: goal),
                      ),
                    );
                  },
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: index == displayGoals.length - 1 ? 0 : 14,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.03)
                            : const Color(0xFFF6F2EA),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          // Organic Progress Ring Pebble
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 44,
                                height: 44,
                                child: CircularProgressIndicator(
                                  value: progress,
                                  strokeWidth: 4,
                                  backgroundColor: isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : const Color(0xFFE2DDD2),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    isCompleted
                                        ? const Color(0xFF16A34A)
                                        : const Color(0xFF4F46E5),
                                  ),
                                ),
                              ),
                              Text(
                                percentText,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 12),

                          // Goal details
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  goal.title,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Saved: ${AppFormat.currency(saved)} of ${AppFormat.currency(target)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Mindful Milestone badge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isCompleted
                                  ? const Color(0x2016A34A)
                                  : const Color(0x184F46E5),
                              borderRadius: BorderRadius.circular(AppRadius.full),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: isCompleted
                                    ? const Color(0xFF16A34A)
                                    : (isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4338CA)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
