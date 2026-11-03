import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../screens/settings/budget_management_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_format.dart';
import '../../../widgets/category_icon_picker.dart';

/// Budget Horizons: Mindful milestone journey for active limits.
///
/// Replaces generic horizontal progress bars with an organic stepping-stone
/// journey path showing pacing and breathing room.
class DashboardBudgetsCard extends ConsumerWidget {
  const DashboardBudgetsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final analytics = ref.watch(analyticsSummaryProvider);

    final progressList = analytics.budgetProgress;
    if (progressList.isEmpty) return const SizedBox.shrink();

    final displayItems = progressList.take(3).toList();

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
                      Icons.account_balance_wallet_outlined,
                      size: 16,
                      color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'BUDGETS',
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
                      AppPageRoute(builder: (_) => const BudgetManagementScreen()),
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Horizons',
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

            // Budgets Journey List
            Column(
              children: List.generate(displayItems.length, (index) {
                final item = displayItems[index];
                final spent = item.spent;
                final limit = item.budget.limit;
                final isOver = spent > limit;
                final remaining = limit - spent;
                final ratio = limit > 0 ? (spent / limit).clamp(0.0, 1.0) : 0.0;

                final color = isOver
                    ? const Color(0xFFE05260)
                    : (ratio > 0.8
                        ? const Color(0xFFF59E0B)
                        : (isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A)));

                final icon = CategoryIconPicker.iconForKey(item.category.icon);

                return Padding(
                  padding: EdgeInsets.only(bottom: index == displayItems.length - 1 ? 0 : 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: isDark ? 0.20 : 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(icon, size: 16, color: color),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.category.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${AppFormat.currency(spent)} of ${AppFormat.currency(limit)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: isDark ? 0.16 : 0.10),
                              borderRadius: BorderRadius.circular(AppRadius.full),
                            ),
                            child: Text(
                              isOver
                                  ? '${AppFormat.currency(remaining.abs())} over'
                                  : '${AppFormat.currency(remaining)} cushion',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: color,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Stepping Stone Progress Horizon
                      Stack(
                        children: [
                          Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : const Color(0xFFEBE5D8),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: ratio,
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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
