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
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surfaceContainerLow,
            ],
          ),
          border: Border.all(
            color: context.borderColor,
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.30)
                  : Theme.of(
                      context,
                    ).colorScheme.shadow.withValues(alpha: 0.08),
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
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.account_balance_wallet_outlined,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'BUDGETS',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: 'View all budgets',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Navigator.push(
                        context,
                        AppPageRoute(
                          builder: (_) => const BudgetManagementScreen(),
                        ),
                      );
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      child: Center(
                        widthFactor: 1,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Horizons',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 15,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Budgets Journey List with Responsive Breakpoint
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 550;
                if (isWide && displayItems.length > 1) {
                  final itemWidth = (constraints.maxWidth - 16) / 2;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 14,
                    children: displayItems.map((item) {
                      return SizedBox(
                        width: itemWidth,
                        child: _buildBudgetItem(context, item, isDark),
                      );
                    }).toList(),
                  );
                }
                return Column(
                  children: List.generate(displayItems.length, (index) {
                    final item = displayItems[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == displayItems.length - 1 ? 0 : 14,
                      ),
                      child: _buildBudgetItem(context, item, isDark),
                    );
                  }),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBudgetItem(
    BuildContext context,
    dynamic item,
    bool isDark,
  ) {
    final spent = item.spent;
    final limit = item.budget.limit;
    final isOver = spent > limit;
    final remaining = limit - spent;
    final ratio = limit > 0 ? (spent / limit).clamp(0.0, 1.0) : 0.0;

    final color = isOver
        ? Theme.of(context).colorScheme.error
        : (ratio > 0.8
              ? Theme.of(context).colorScheme.tertiary
              : (Theme.of(context).colorScheme.secondary));

    final icon = CategoryIconPicker.iconForKey(item.category.icon);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(
                  alpha: isDark ? 0.20 : 0.12,
                ),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${AppFormat.currency(spent)} of ${AppFormat.currency(limit)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: color.withValues(
                  alpha: isDark ? 0.16 : 0.10,
                ),
                borderRadius: BorderRadius.circular(
                  AppRadius.full,
                ),
              ),
              child: Text(
                isOver
                    ? '${AppFormat.currency(remaining.abs())} over'
                    : '${AppFormat.currency(remaining)} cushion',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
                    : Theme.of(context).colorScheme.outline,
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
    );
  }
}
