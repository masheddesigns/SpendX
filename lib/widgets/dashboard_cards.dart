import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../utils/app_format.dart';

class DashboardCards extends StatelessWidget {
  final bool isIncomeDisabled;
  final double totalBalance;
  final double totalIncome;
  final double totalExpense;
  final double monthlyExpense;
  final double previousMonthExpense;
  final String currentPeriod;
  final ValueChanged<String> onPeriodChanged;

  const DashboardCards({
    super.key,
    required this.isIncomeDisabled,
    required this.totalBalance,
    required this.totalIncome,
    required this.totalExpense,
    required this.monthlyExpense,
    required this.previousMonthExpense,
    required this.currentPeriod,
    required this.onPeriodChanged,
  });

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsService>();
    final cs = Theme.of(context).colorScheme;
    final delta = monthlyExpense - previousMonthExpense;
    final deltaPct = previousMonthExpense <= 0
        ? 0.0
        : (delta / previousMonthExpense) * 100;
    final isUp = delta >= 0;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isIncomeDisabled ? 'Total Spending' : 'Total Balance',
                style: TextStyle(
                  color: cs.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const Spacer(),
              _PeriodChip(
                currentPeriod: currentPeriod,
                onPeriodChanged: onPeriodChanged,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Text(
                AppFormat.currency(isIncomeDisabled ? totalExpense : totalBalance),
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isIncomeDisabled
                ? 'This month ${AppFormat.currency(monthlyExpense)}'
                : 'Income ${AppFormat.currency(totalIncome)}  •  Expense ${AppFormat.currency(totalExpense)}',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 24),
          if (isIncomeDisabled)
            Row(
              children: [
                Expanded(
                  child: _MetricTile(
                    title: 'Expense Summary',
                    value: AppFormat.currency(monthlyExpense),
                    icon: Icons.receipt_long_outlined,
                    color: cs.error,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricTile(
                    title: 'Compared to last month',
                    value: previousMonthExpense <= 0
                        ? 'New month'
                        : '${isUp ? '+' : ''}${deltaPct.toStringAsFixed(0)}%',
                    icon: isUp ? Icons.trending_up : Icons.trending_down,
                    color: isUp ? Colors.orange : cs.primary,
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: _MetricTile(
                    title: 'Income',
                    value: AppFormat.currency(totalIncome),
                    icon: Icons.arrow_downward_rounded,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricTile(
                    title: 'Expense',
                    value: AppFormat.currency(totalExpense),
                    icon: Icons.arrow_upward_rounded,
                    color: cs.error,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _MetricTile({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodChip extends StatelessWidget {
  final String currentPeriod;
  final ValueChanged<String> onPeriodChanged;

  const _PeriodChip({
    required this.currentPeriod,
    required this.onPeriodChanged,
  });

  String _label(String period) {
    switch (period) {
      case '1m':
        return '1 Month';
      case '3m':
        return '3 Months';
      case '6m':
        return '6 Months';
      case '1y':
        return '1 Year';
      case 'lifetime':
        return 'Lifetime';
      default:
        return 'Period';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      initialValue: currentPeriod,
      onSelected: onPeriodChanged,
      color: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label(currentPeriod),
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down,
              color: cs.onSurfaceVariant,
              size: 14,
            ),
          ],
        ),
      ),
      itemBuilder: (context) => const [
        PopupMenuItem(value: '1m', child: Text('Last Month')),
        PopupMenuItem(value: '3m', child: Text('3 Months')),
        PopupMenuItem(value: '6m', child: Text('6 Months')),
        PopupMenuItem(value: '1y', child: Text('1 Year')),
        PopupMenuItem(value: 'lifetime', child: Text('Lifetime')),
      ],
    );
  }
}
