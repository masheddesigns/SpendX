import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../screens/reports_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_format.dart';

/// Monthly Cashflow: Clean, connected income vs expense relationship.
///
/// Features clear financial terminology (Income, Expenses, Net),
/// vector tokens (no emojis), and a connected visual progress track.
class MonthlyPulseCard extends ConsumerWidget {
  const MonthlyPulseCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final analytics = ref.watch(analyticsSummaryProvider);

    final income = analytics.monthlyIncome;
    final expense = analytics.monthlyExpense;
    final netCashFlow = income - expense;
    final hasData = income > 0 || expense > 0;

    final savingsRate = income > 0
        ? ((netCashFlow / income) * 100).clamp(-100, 100).toInt()
        : 0;

    String cashflowNote;
    if (!hasData) {
      cashflowNote =
          'New calendar month • Record income or expenses to track flow.';
    } else if (netCashFlow > 0) {
      cashflowNote =
          'Positive cashflow • Retaining $savingsRate% of monthly income.';
    } else if (netCashFlow == 0) {
      cashflowNote = 'Balanced cashflow • Income matches expenses exactly.';
    } else {
      cashflowNote =
          'Expenses exceed income by ${AppFormat.currency(netCashFlow.abs())} this month.';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.surfaceContainerLow,
            ],
          ),
          border: Border.all(
            color: isDark
                ? context.borderColor
                : Theme.of(context).colorScheme.outline,
            width: 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.shadow.withValues(alpha: isDark ? 0.25 : 0.08),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Semantics(
          button: true,
          label: 'Monthly Pulse: View reports',
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: () {
                Navigator.push(
                  context,
                  AppPageRoute(builder: (_) => const ReportsScreen()),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header: Title & Reports Link
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.insights_rounded,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'MONTHLY CASHFLOW',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.9,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Reports',
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
                  ],
                ),

                const SizedBox(height: 14),

                // ── Connected Flow Landscape (Responsive) ──────────────────
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 500;
                    return Row(
                      children: [
                        // Income Pillar
                        Expanded(
                          flex: isWide ? 5 : 4,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: isWide ? 18 : 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.25),
                                width: 0.8,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.arrow_downward_rounded,
                                      size: 13,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.secondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Income',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSecondaryContainer,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  AppFormat.currency(income),
                                  style: TextStyle(
                                    fontSize: isWide ? 17 : 15,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSecondaryContainer,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Central Flow Bridge
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: netCashFlow >= 0
                                  ? Theme.of(context).colorScheme.secondaryContainer
                                  : Theme.of(context).colorScheme.errorContainer,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              netCashFlow >= 0
                                  ? Icons.trending_up_rounded
                                  : Icons.trending_down_rounded,
                              size: 15,
                              color: netCashFlow >= 0
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),

                        // Expenses Pillar
                        Expanded(
                          flex: isWide ? 5 : 4,
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: isWide ? 18 : 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.error.withValues(alpha: 0.25),
                                width: 0.8,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.arrow_outward_rounded,
                                      size: 13,
                                      color: Theme.of(context).colorScheme.error,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Expenses',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  AppFormat.currency(expense),
                                  style: TextStyle(
                                    fontSize: isWide ? 17 : 15,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 12),

                // Mindful Status Note
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7.5,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          cashflowNote,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);
}
}
