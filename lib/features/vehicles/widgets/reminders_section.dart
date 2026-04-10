import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../models/vehicle_reminder.dart';

class RemindersSection extends StatelessWidget {
  final List<VehicleReminder> activeReminders;
  final double currentOdometer;
  final Function(VehicleReminder) onAcknowledge;

  const RemindersSection({
    super.key,
    required this.activeReminders,
    required this.currentOdometer,
    required this.onAcknowledge,
  });

  @override
  Widget build(BuildContext context) {
    if (activeReminders.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ACTIVE REMINDERS', style: AppTextStyles.labelMedium.copyWith(color: cs.primary, letterSpacing: 1.2)),
        const SizedBox(height: 12),
        ...activeReminders.map((r) => _reminderTile(context, r, cs)),
      ],
    );
  }

  Widget _reminderTile(BuildContext context, VehicleReminder r, ColorScheme cs) {
    final isOverdue = r.isOverdue(currentOdometer);
    final statusColor = isOverdue ? Colors.red : Colors.orange;
    final icon = r.type == ReminderType.odoBased ? Icons.speed : Icons.event_note;

    return AppCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: statusColor.withValues(alpha: 0.1),
            child: Icon(icon, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.title, style: AppTextStyles.titleSmall),
                const SizedBox(height: 2),
                Text(
                  _getStatusText(r),
                  style: AppTextStyles.bodySmall.copyWith(color: statusColor, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onAcknowledge(r),
            style: TextButton.styleFrom(
              foregroundColor: Colors.green,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _getStatusText(VehicleReminder r) {
    if (r.type == ReminderType.odoBased) {
      final km = r.kmRemaining(currentOdometer);
      if (km == null) return 'No odometer info';
      return km < 0 ? 'Overdue by ${(-km).toStringAsFixed(0)} km' : 'Due in ${km.toStringAsFixed(0)} km';
    } else {
      final days = r.daysRemaining();
      if (days == null) return 'No date info';
      return days < 0 ? 'Overdue by ${(-days)} days' : 'Due in $days days';
    }
  }
}
