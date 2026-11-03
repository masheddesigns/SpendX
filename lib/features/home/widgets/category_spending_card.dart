import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../utils/app_format.dart';
import '../../../widgets/category_icon_picker.dart';

/// Spending Mosaic: Playful, organic breakdown of top outlays.
///
/// Replaces the sterile percentage-bar card with an expressive mosaic
/// featuring friendly category bubbles and an organic distribution ribbon.
class CategorySpendingCard extends ConsumerWidget {
  const CategorySpendingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final analytics = ref.watch(analyticsSummaryProvider);

    final spending = analytics.categorySpending;
    if (spending.isEmpty) return const SizedBox.shrink();

    final totalSpent = analytics.monthlyExpense;
    final categoriesMap = analytics.categoriesMap;

    // Sort categories by spend descending, take top 4
    final sortedEntries = spending.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topEntries = sortedEntries.take(4).toList();

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
                : const [Color(0xFFFFFFFF), Color(0xFFF9F6EE)],
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
            // Header: Friendly Section Indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.pie_chart_outline_rounded,
                      size: 16,
                      color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'TOP CATEGORIES',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                      ),
                    ),
                  ],
                ),
                Text(
                  'Top ${topEntries.length} sectors',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // Fluid Distribution Ribbon (Petal Mosaic)
            if (totalSpent > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  height: 8,
                  child: Row(
                    children: topEntries.map((entry) {
                      final category = categoriesMap[entry.key];
                      final amount = entry.value;
                      final percentage = (amount / totalSpent).clamp(0.01, 1.0);
                      final color = _resolveColor(category?.color);
                      return Expanded(
                        flex: (percentage * 100).toInt().clamp(1, 100),
                        child: Container(
                          color: color,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],

            // Organic Category Floating Pods
            Column(
              children: List.generate(topEntries.length, (index) {
                final entry = topEntries[index];
                final category = categoriesMap[entry.key];
                final amount = entry.value;
                final percentage = totalSpent > 0
                    ? (amount / totalSpent).clamp(0.0, 1.0)
                    : 0.0;
                final percentText = '${(percentage * 100).toInt()}%';

                final color = _resolveColor(category?.color);
                final icon = category != null
                    ? CategoryIconPicker.iconForKey(category.icon)
                    : Icons.category_rounded;
                final name = category?.name ?? 'Other';

                return Padding(
                  padding: EdgeInsets.only(bottom: index == topEntries.length - 1 ? 0 : 10),
                  child: Row(
                    children: [
                      // Tactile squircle icon pod
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: isDark ? 0.20 : 0.12),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: color.withValues(alpha: isDark ? 0.35 : 0.25),
                            width: 0.8,
                          ),
                        ),
                        child: Icon(icon, size: 19, color: color),
                      ),
                      const SizedBox(width: 12),

                      // Name and share
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$percentText of outlays',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Amount
                      Text(
                        AppFormat.currency(amount),
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Colors.white : const Color(0xFF1C1917),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
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

  Color _resolveColor(String? colorStr) {
    if (colorStr == null || colorStr.isEmpty) return const Color(0xFF6366F1);
    try {
      final hex = colorStr.replaceAll('#', '');
      if (hex.length == 6) return Color(int.parse('0xFF$hex'));
      if (hex.length == 8) return Color(int.parse('0x$hex'));
    } catch (_) {}
    return const Color(0xFF6366F1);
  }
}
