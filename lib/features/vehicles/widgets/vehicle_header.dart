import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../utils/app_format.dart';

class VehicleHeader extends StatelessWidget {
  final String name;
  final double totalKm;
  final double avgEfficiency;
  final double totalSpend;

  const VehicleHeader({
    super.key,
    required this.name,
    required this.totalKm,
    required this.avgEfficiency,
    required this.totalSpend,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primary, cs.primaryContainer.withValues(alpha: 0.8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.large),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.2),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            totalKm.toStringAsFixed(0),
            style: AppTextStyles.headlineLarge.copyWith(
              color: cs.onPrimary,
              fontWeight: FontWeight.w900,
              fontSize: 48,
            ),
          ),
          Text(
            'TOTAL DRIVEN (KM)',
            style: AppTextStyles.labelSmall.copyWith(
              color: cs.onPrimary.withValues(alpha: 0.8),
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _miniStat(cs, 'Avg Mileage', '${avgEfficiency.toStringAsFixed(1)} km/l'),
              _miniStat(cs, 'Total Spend', AppFormat.currency(totalSpend)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(ColorScheme cs, String label, String val) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppTextStyles.labelSmall.copyWith(
              color: cs.onPrimary.withValues(alpha: 0.7),
            ),
          ),
          Text(
            val,
            style: AppTextStyles.titleMedium.copyWith(
              color: cs.onPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
}
