import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';

class SalaryInsightCard extends StatelessWidget {
  const SalaryInsightCard({
    super.key,
    required this.avgDelayDays,
    required this.reliabilityScore,
    required this.totalBonus,
  });

  final double avgDelayDays;
  final double reliabilityScore; // 0.0 to 1.0
  final double totalBonus;

  @override
  Widget build(BuildContext context) {

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.m),
      child: Row(
        children: [
          _InsightItem(
            icon: Icons.timer_outlined,
            label: 'Avg. Delay',
            value: '${avgDelayDays.toStringAsFixed(1)}d',
            color: avgDelayDays > 2 ? AppColors.danger : AppColors.success,
          ),
          _VerticalDivider(),
          _InsightItem(
            icon: Icons.verified_user_outlined,
            label: 'Reliability',
            value: '${(reliabilityScore * 100).toStringAsFixed(0)}%',
            color: reliabilityScore > 0.8 ? AppColors.success : AppColors.warning,
          ),
          _VerticalDivider(),
          _InsightItem(
            icon: Icons.trending_up,
            label: 'Total Bonus',
            value: totalBonus > 0 ? '+${totalBonus.toStringAsFixed(0)}' : '0',
            color: AppColors.primary,
          ),
        ],
      ),
    );
  }
}

class _InsightItem extends StatelessWidget {
  const _InsightItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: AppColors.mutedText),
          const SizedBox(height: 8),
          Text(
            value,
            style: AppTextStyles.titleMedium.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: AppTextStyles.labelSmall.copyWith(color: AppColors.mutedText),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      width: 1,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}
