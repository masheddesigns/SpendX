import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../utils/app_format.dart';

class CostSummaryCard extends StatelessWidget {
  final double totalFuelCost;
  final double totalMaintenanceCost;

  const CostSummaryCard({
    super.key,
    required this.totalFuelCost,
    required this.totalMaintenanceCost,
  });

  @override
  Widget build(BuildContext context) {
    final total = totalFuelCost + totalMaintenanceCost;
    final cs = Theme.of(context).colorScheme;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('COST BREAKDOWN', style: AppTextStyles.labelMedium.copyWith(color: cs.primary, letterSpacing: 1.2)),
          const SizedBox(height: 16),
          _costItem(context, 'Fuel', totalFuelCost, total, cs.secondary),
          const SizedBox(height: 12),
          _costItem(context, 'Maintenance', totalMaintenanceCost, total, cs.primary),
          const Divider(height: 32, color: Colors.white10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total Ownership Cost', style: TextStyle(color: Colors.white70, fontSize: 13)),
              Text(AppFormat.currency(total), style: AppTextStyles.titleMedium.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _costItem(BuildContext context, String label, double amount, double total, Color color) {
    final percent = total > 0 ? (amount / total) : 0.0;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70)),
            Text(AppFormat.currency(amount), style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent,
            backgroundColor: Colors.white.withValues(alpha: 0.05),
            color: color,
            minHeight: 6,
          ),
        ),
      ],
    );
  }
}
