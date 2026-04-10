import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../models/vehicle.dart';

class FuelSummaryCard extends StatelessWidget {
  final List<FuelLog> logs;
  final double avgEfficiency;
  final double costPerKm;

  const FuelSummaryCard({
    super.key,
    required this.logs,
    required this.avgEfficiency,
    required this.costPerKm,
  });

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) return const SizedBox.shrink();

    final lastLog = logs.last;
    final cs = Theme.of(context).colorScheme;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('FUEL SUMMARY', style: AppTextStyles.labelMedium.copyWith(color: cs.primary, letterSpacing: 1.2)),
              if (lastLog.efficiency != null)
                _EfficiencyIndicator(efficiency: lastLog.efficiency!, avg: avgEfficiency),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _infoItem('Last Mileage', '${lastLog.efficiency?.toStringAsFixed(1) ?? "--"} km/l', Icons.speed),
              _divider(),
              _infoItem('Cost / km', '₹${costPerKm.toStringAsFixed(1)}', Icons.currency_rupee),
              _divider(),
              _infoItem('Refuels', '${logs.length}', Icons.local_gas_station),
            ],
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(height: 30, width: 1, color: Colors.white10, margin: const EdgeInsets.symmetric(horizontal: 12));

  Widget _infoItem(String label, String value, IconData icon) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: Colors.white38),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.white38)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

class _EfficiencyIndicator extends StatelessWidget {
  final double efficiency;
  final double avg;

  const _EfficiencyIndicator({required this.efficiency, required this.avg});

  @override
  Widget build(BuildContext context) {
    final diff = efficiency - avg;
    final isGood = diff >= 0;
    final color = isGood ? Colors.green : Colors.orange;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isGood ? Icons.trending_up : Icons.trending_down, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            isGood ? 'Above Avg' : 'Below Avg',
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
