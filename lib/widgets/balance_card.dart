import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/app_format.dart';
import 'animated_widgets.dart';

class BalanceCard extends StatefulWidget {
  final double totalBalance;
  final double totalIncome;
  final double totalExpense;
  final String currentPeriod;
  final Function(String) onPeriodChanged;

  const BalanceCard({
    super.key,
    required this.totalBalance,
    required this.totalIncome,
    required this.totalExpense,
    required this.currentPeriod,
    required this.onPeriodChanged,
  });

  @override
  State<BalanceCard> createState() => _BalanceCardState();
}

class _BalanceCardState extends State<BalanceCard> {
  bool _hideAmount = false;

  Widget _periodSelector(BuildContext context) {
    return PopupMenuButton<String>(
      initialValue: widget.currentPeriod,
      onSelected: (value) {
        if (value != widget.currentPeriod) {
          HapticFeedback.lightImpact();
          widget.onPeriodChanged(value);
        }
      },
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Text(
              _getPeriodLabel(widget.currentPeriod),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5), size: 14),
          ],
        ),
      ),
      itemBuilder: (context) => [
        const PopupMenuItem(value: '1m', child: Text('Last Month')),
        const PopupMenuItem(value: '3m', child: Text('3 Months')),
        const PopupMenuItem(value: '6m', child: Text('6 Months')),
        const PopupMenuItem(value: '1y', child: Text('1 Year')),
        const PopupMenuItem(value: 'lifetime', child: Text('Lifetime')),
      ],
    );
  }

  String _getPeriodLabel(String period) {
    switch (period) {
      case '1m': return '1 Month';
      case '3m': return '3 Months';
      case '6m': return '6 Months';
      case '1y': return '1 Year';
      case 'lifetime': return 'Lifetime';
      default: return 'Period';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedScaleWrapper(
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Total Balance",
                    style: TextStyle(color: cs.primary, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5),
                  ),
                  _periodSelector(context),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _hideAmount
                      ? Text('****', style: TextStyle(color: cs.onSurface, fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -1))
                      : CountUpText(
                          value: widget.totalBalance,
                          prefix: AppFormat.currencySymbol,
                          decimalPlaces: 2,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                          ),
                        ),
                  ),
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      setState(() => _hideAmount = !_hideAmount);
                    },
                    child: Icon(_hideAmount ? Icons.visibility_off : Icons.visibility, color: cs.onSurfaceVariant, size: 24),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _MiniSummary(
                      title: "Income",
                      amount: widget.totalIncome,
                      isMuted: _hideAmount,
                      color: cs.primary, // Positive/Money
                      icon: Icons.arrow_downward,
                    ),
                  ),
                  Container(width: 1, height: 40, color: cs.outline.withValues(alpha: 0.2)),
                  Expanded(
                    child: _MiniSummary(
                      title: "Expense",
                      amount: widget.totalExpense,
                      isMuted: _hideAmount,
                      color: cs.error, // Negative
                      icon: Icons.arrow_upward,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniSummary extends StatelessWidget {
  final String title;
  final double amount;
  final bool isMuted;
  final Color color;
  final IconData icon;

  const _MiniSummary({
    required this.title,
    required this.amount,
    required this.isMuted,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 14),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              isMuted
                ? Text('---', style: TextStyle(color: cs.onSurface, fontSize: 14, fontWeight: FontWeight.w600))
                : CountUpText(
                    value: amount,
                    prefix: AppFormat.currencySymbol,
                    decimalPlaces: 2,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}
