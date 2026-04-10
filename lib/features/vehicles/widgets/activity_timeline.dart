import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../utils/app_format.dart';
import '../services/vehicle_service.dart';

class ActivityTimeline extends StatelessWidget {
  final List<VehicleActivity> activities;

  const ActivityTimeline({super.key, required this.activities});

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ACTIVITY TIMELINE', style: AppTextStyles.labelMedium.copyWith(color: cs.primary, letterSpacing: 1.2)),
        const SizedBox(height: 12),
        ...activities.map((item) => _activityItem(context, item, cs)),
      ],
    );
  }

  Widget _activityItem(BuildContext context, VehicleActivity item, ColorScheme cs) {
    final dateStr = DateFormat('MMM d, yyyy').format(item.date);
    final icon = item.type == 'fuel' ? Icons.local_gas_station : Icons.build_circle_outlined;
    final color = item.type == 'fuel' ? cs.primary : cs.secondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.1),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: AppSpacing.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: AppTextStyles.labelMedium.copyWith(color: cs.onSurface)),
                  const SizedBox(height: 2),
                  Text(
                    '$dateStr • ${item.subtitle}',
                    style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Text(
              AppFormat.currency(item.amount),
              style: AppTextStyles.titleMedium.copyWith(color: cs.onSurface, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}
