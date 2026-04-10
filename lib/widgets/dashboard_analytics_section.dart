import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/category.dart';
import '../data/providers.dart';
import '../utils/app_format.dart';

class DashboardAnalyticsSection extends ConsumerWidget {
  const DashboardAnalyticsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();

    final summary = ref.watch(analyticsSummaryProvider);
    final budgets = summary.budgetProgress;
    final categorySpend = summary.categorySpending;
    final categoriesMap = summary.categoriesMap;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Budget Summary (only if budgets exist)
        if (budgets.isNotEmpty) ...[
          const _SectionTitle('Budgets This Month'),
          const SizedBox(height: 12),
          ...budgets.map((item) => _buildBudgetRow(context, ref, item)),
          const SizedBox(height: 24),
        ],

        // Category spending pie (only if data exists)
        if (categorySpend.isNotEmpty) ...[
          const _SectionTitle('Spending by Category'),
          const SizedBox(height: 12),
          _buildPieChart(context, categorySpend, categoriesMap),
          const SizedBox(height: 24),
        ],
      ],
    );
  }

  Widget _buildBudgetRow(BuildContext context, WidgetRef ref, dynamic item) {
    final progress = (item.spent / item.budget.limit).clamp(0.0, 1.0);
    final progressColor = progress < 0.7
        ? Theme.of(context).colorScheme.primary
        : progress < 0.9
            ? Colors.orange
            : Theme.of(context).colorScheme.error;
    final catColor = _hexToColor(item.category.color);

    return InkWell(
      onTap: () => _showEditBudgetSheet(context, ref, item),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: progress >= 0.9
              ? Border.all(color: Theme.of(context).colorScheme.error.withValues(alpha: 0.4), width: 1.5)
              : null,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: catColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(child: _buildIcon(item.category.icon, catColor)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(item.category.name,
                      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                ),
                if (progress >= 0.9)
                  const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
                const SizedBox(width: 8),
                const Icon(Icons.edit_outlined, color: Colors.white24, size: 12),
                const SizedBox(width: 4),
                Text(
                  '${AppFormat.currency(item.spent)} / ${AppFormat.currency(item.budget.limit)}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPieChart(BuildContext context, Map<String, double> categorySpend, Map<String, Category> categoriesMap) {
    final total = categorySpend.values.fold(0.0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    final sections = categorySpend.entries.map((e) {
      final cat = categoriesMap[e.key] ?? _getVehicleFallback(e.key);
      final color = _hexToColor(cat?.color ?? '#888888');
      return PieChartSectionData(
        value: e.value,
        color: color,
        radius: 20,
        showTitle: false,
      );
    }).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 200,
            child: Stack(
              children: [
                PieChart(
                  PieChartData(
                    sections: sections,
                    centerSpaceRadius: 60,
                    sectionsSpace: 4,
                    startDegreeOffset: -90,
                  ),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeInOutBack,
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'This Month',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppFormat.currency(total),
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 40,
              crossAxisSpacing: 16,
              mainAxisSpacing: 8,
            ),
            itemCount: categorySpend.length,
            itemBuilder: (context, index) {
              final entry = categorySpend.entries.elementAt(index);
              final cat = categoriesMap[entry.key] ?? _getVehicleFallback(entry.key);
              final color = _hexToColor(cat?.color ?? '#888888');
              final pct = (entry.value / total * 100).toStringAsFixed(0);
              
              return Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(child: _buildIcon(cat?.icon ?? '?', color, size: 14)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          cat?.name ?? 'Other',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '$pct% • ${AppFormat.currency(entry.value)}',
                          style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Category? _getVehicleFallback(String id) {
    if (id == 'vehicle') {
      return Category(
        id: 'vehicle',
        userId: 'default',
        name: 'Vehicle & Fuel',
        icon: 'local_gas_station',
        color: '#F97316',
        type: 'expense',
      );
    }
    return null;
  }

  void _showEditBudgetSheet(BuildContext context, WidgetRef ref, dynamic item) {
    double currentLimit = item.budget.limit;
    final controller = TextEditingController(text: currentLimit.toStringAsFixed(0));
    final catColor = _hexToColor(item.category.color);

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 24, right: 24, bottom: MediaQuery.of(ctx).viewInsets.bottom + 24, top: 20
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: catColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.category, color: catColor),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Adjust ${item.category.name} Budget', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600)),
                        Text('Spending this month: ${AppFormat.currency(item.spent)}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Text('Monthly Limit', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                autofocus: true,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 24, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  prefixText: '${AppFormat.currencySymbol} ',
                  prefixStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 24),
                  border: InputBorder.none,
                ),
                onChanged: (val) {
                  setSheetState(() => currentLimit = double.tryParse(val) ?? 0);
                },
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [500, 1000, 2000, 5000].map((val) => IntrinsicWidth(
                  child: ActionChip(
                    label: Text('+${AppFormat.currency(val.toDouble())}', style: const TextStyle(fontSize: 12)),
                    backgroundColor: Colors.white.withValues(alpha: 0.05),
                    onPressed: () {
                      setSheetState(() {
                        final newLimit = currentLimit + val;
                        currentLimit = newLimit;
                        controller.text = newLimit.toStringAsFixed(0);
                      });
                    },
                  ),
                )).toList(),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () async {
                    if (currentLimit <= 0) return;
                    await ref.read(budgetsProvider.notifier).updateLimit(item.budget.id, currentLimit);
                    if (context.mounted) {
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Text('Update Limit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _hexToColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return Colors.grey;
    }
  }

  Widget _buildIcon(String icon, Color color, {double size = 16}) {
    if (icon.length <= 2) {
      return Text(icon, style: TextStyle(fontSize: size));
    }
    IconData iconData;
    switch (icon) {
      case 'restaurant': iconData = Icons.restaurant; break;
      case 'directions_car': iconData = Icons.directions_car; break;
      case 'local_gas_station': iconData = Icons.local_gas_station; break;
      case 'shopping_bag': iconData = Icons.shopping_bag; break;
      case 'home': iconData = Icons.home; break;
      case 'bolt': iconData = Icons.bolt; break;
      case 'movie': iconData = Icons.movie; break;
      case 'payments': iconData = Icons.payments; break;
      case 'health_and_safety': iconData = Icons.health_and_safety; break;
      default: iconData = Icons.category;
    }
    return Icon(iconData, color: color, size: size);
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
    );
  }
}
