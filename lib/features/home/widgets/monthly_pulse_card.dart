import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../screens/reports_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
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
      cashflowNote = 'New calendar month • Record income or expenses to track flow.';
    } else if (netCashFlow > 0) {
      cashflowNote = 'Positive cashflow • Retaining $savingsRate% of monthly income.';
    } else if (netCashFlow == 0) {
      cashflowNote = 'Balanced cashflow • Income matches expenses exactly.';
    } else {
      cashflowNote = 'Expenses exceed income by ${AppFormat.currency(netCashFlow.abs())} this month.';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF161922), Color(0xFF13161F)]
                : const [Color(0xFFFFFFFF), Color(0xFFFAF7F0)],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFECE5D8),
            width: 0.9,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.25)
                  : const Color(0x081C1917),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
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
                          color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'MONTHLY CASHFLOW',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.9,
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
                  ],
                ),

                const SizedBox(height: 14),

                // ── Connected Flow Landscape ──────────────────
                Row(
                  children: [
                    // Income Pillar
                    Expanded(
                      flex: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF12261B) : const Color(0xFFF0FDF4),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isDark ? const Color(0x3022C55E) : const Color(0x2516A34A),
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
                                  color: isDark ? const Color(0xFF86EFAC) : const Color(0xFF16A34A),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Income',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? const Color(0xFF86EFAC) : const Color(0xFF15803D),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              AppFormat.currency(income),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                                color: isDark ? Colors.white : const Color(0xFF14532D),
                                fontFeatures: const [FontFeature.tabularFigures()],
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
                          color: isDark
                              ? (netCashFlow >= 0 ? const Color(0x2522C55E) : const Color(0x25F43F5E))
                              : (netCashFlow >= 0 ? const Color(0xFFDCFCE7) : const Color(0xFFFFE4E6)),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          netCashFlow >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                          size: 15,
                          color: netCashFlow >= 0
                              ? const Color(0xFF16A34A)
                              : const Color(0xFFE11D48),
                        ),
                      ),
                    ),

                    // Expenses Pillar
                    Expanded(
                      flex: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF261418) : const Color(0xFFFFF1F2),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isDark ? const Color(0x30F43F5E) : const Color(0x25E11D48),
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
                                  color: isDark ? const Color(0xFFFDA4AF) : const Color(0xFFE11D48),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Expenses',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? const Color(0xFFFDA4AF) : const Color(0xFFBE123C),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              AppFormat.currency(expense),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                                color: isDark ? Colors.white : const Color(0xFF881337),
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Mindful Status Note
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : const Color(0xFFF4EFE6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          cashflowNote,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF57534E),
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
    );
  }
}
