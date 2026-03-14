import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/budget.dart';
import '../models/category.dart';
import '../services/database_helper.dart';
import '../utils/app_format.dart';

class DashboardAnalyticsSection extends StatefulWidget {
  const DashboardAnalyticsSection({super.key});

  @override
  State<DashboardAnalyticsSection> createState() => _DashboardAnalyticsSectionState();
}

class _DashboardAnalyticsSectionState extends State<DashboardAnalyticsSection> {
  List<_BudgetItem> _budgets = [];
  Map<String, double> _categorySpend = {};
  Map<String, Category> _categoriesMap = {};

  @override
  void initState() {
    super.initState();
    _loadAnalytics();
  }

  @override
  void didUpdateWidget(DashboardAnalyticsSection old) {
    super.didUpdateWidget(old);
    _loadAnalytics();
  }

  Future<void> _loadAnalytics() async {
    if (kIsWeb) return;
    try {
      final db = await DatabaseHelper.instance.database;
      final catMaps = await db.query(DatabaseHelper.tableCategories);
      final catMap = {for (var m in catMaps) m['id'] as String: Category.fromMap(m)};

      final budgets = await DatabaseHelper.instance.getAllBudgets();
      List<_BudgetItem> items = [];
      for (var b in budgets) {
        final spent = await DatabaseHelper.instance.getSpentThisMonth(b.categoryId);
        final cat = catMap[b.categoryId];
        if (cat != null) {
          items.add(_BudgetItem(budget: b, category: cat, spent: spent));
        }
      }

      // Optimized Category spending breakdown (this month)
      final now = DateTime.now();
      final startOfMonth = DateTime(now.year, now.month, 1);
      final endOfMonth = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
      
      final spendMap = await DatabaseHelper.instance.getCategorySpending(
        start: startOfMonth,
        end: endOfMonth,
      );

      // Ensure 'vehicle' category exists in map if used
      if (spendMap.containsKey('vehicle') && !catMap.containsKey('vehicle')) {
        catMap['vehicle'] = Category(
          id: 'vehicle', 
          userId: 'default', 
          name: 'Vehicle & Fuel', 
          icon: 'local_gas_station', 
          color: '#F97316', 
          type: 'expense'
        );
      }

      if (mounted) {
        setState(() {
          _budgets = items;
          _categorySpend = spendMap;
          _categoriesMap = catMap;
        });
      }
    } catch (e) {
      debugPrint('DashboardAnalytics error: $e');
    }
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Budget Summary (only if budgets exist)
        if (_budgets.isNotEmpty) ...[
          _SectionTitle('Budgets This Month'),
          const SizedBox(height: 12),
          ..._budgets.map((item) => _buildBudgetRow(item)),
          const SizedBox(height: 24),
        ],

        // Category spending pie (only if data exists)
        if (_categorySpend.isNotEmpty) ...[
          _SectionTitle('Spending by Category'),
          const SizedBox(height: 12),
          _buildPieChart(),
          const SizedBox(height: 24),
        ],
      ],
    );
  }

  Widget _buildBudgetRow(_BudgetItem item) {
    final progress = (item.spent / item.budget.limit).clamp(0.0, 1.0);
    final progressColor = progress < 0.7
        ? Theme.of(context).colorScheme.primary
        : progress < 0.9
            ? Colors.orange
            : Theme.of(context).colorScheme.error;
    final catColor = _hexToColor(item.category.color);

    return InkWell(
      onTap: () => _showEditBudgetSheet(item),
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

  Widget _buildPieChart() {
    final total = _categorySpend.values.fold(0.0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    final sections = _categorySpend.entries.map((e) {
      final cat = _categoriesMap[e.key];
      final color = _hexToColor(cat?.color ?? '#888888');
      return PieChartSectionData(
        value: e.value,
        color: color,
        radius: 20,
        showTitle: false,
        badgeWidget: null,
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
                  swapAnimationDuration: const Duration(milliseconds: 800),
                  swapAnimationCurve: Curves.easeInOutBack,
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
          // Legend Grid
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 40,
              crossAxisSpacing: 16,
              mainAxisSpacing: 8,
            ),
            itemCount: _categorySpend.length,
            itemBuilder: (context, index) {
              final entry = _categorySpend.entries.elementAt(index);
              final cat = _categoriesMap[entry.key];
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

  void _showEditBudgetSheet(_BudgetItem item) {
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
              // Quick Multipliers
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
                    final updated = Budget(
                      id: item.budget.id,
                      categoryId: item.budget.categoryId,
                      limit: currentLimit,
                    );
                    await DatabaseHelper.instance.updateBudget(updated);
                    if (context.mounted) {
                      Navigator.pop(ctx);
                      _loadAnalytics();
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

class _BudgetItem {
  final Budget budget;
  final Category category;
  final double spent;
  const _BudgetItem({required this.budget, required this.category, required this.spent});
}
