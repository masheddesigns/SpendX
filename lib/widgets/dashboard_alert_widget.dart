import 'package:flutter/material.dart';

import '../models/reminder_model.dart';
import '../services/haptic_service.dart';

class DashboardAlertWidget extends StatelessWidget {
  const DashboardAlertWidget({
    super.key,
    required this.reminders,
    required this.onReminderTap,
    required this.onMarkDone,
    required this.onSnooze,
  });

  final List<Reminder> reminders;
  final ValueChanged<Reminder> onReminderTap;
  final Future<void> Function(Reminder) onMarkDone;
  final Future<void> Function(Reminder) onSnooze;

  @override
  Widget build(BuildContext context) {
    if (reminders.isEmpty) return const SizedBox.shrink();

    final grouped = {
      ReminderStatus.overdue: reminders
          .where((item) => item.status == ReminderStatus.overdue)
          .toList(),
      ReminderStatus.dueToday: reminders
          .where((item) => item.status == ReminderStatus.dueToday)
          .toList(),
      ReminderStatus.upcoming: reminders
          .where((item) => item.status == ReminderStatus.upcoming)
          .toList(),
    };

    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Alerts & Reminders',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Stay ahead of due payments, salary delays, and upcoming renewals.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          for (final entry in grouped.entries)
            if (entry.value.isNotEmpty) ...[
              _SectionHeader(status: entry.key),
              const SizedBox(height: 12),
              ...entry.value
                  .take(3)
                  .map(
                    (reminder) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ReminderRow(
                        reminder: reminder,
                        onTap: () => onReminderTap(reminder),
                        onMarkDone: () => onMarkDone(reminder),
                        onSnooze: () => onSnooze(reminder),
                      ),
                    ),
                  ),
            ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.status});

  final ReminderStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ReminderStatus.overdue => Theme.of(context).colorScheme.error,
      ReminderStatus.dueToday => Colors.orange,
      ReminderStatus.upcoming => Colors.amber,
      ReminderStatus.inactive => Theme.of(context).colorScheme.outline,
    };
    final label = switch (status) {
      ReminderStatus.overdue => 'Overdue',
      ReminderStatus.dueToday => 'Due Today',
      ReminderStatus.upcoming => 'Upcoming',
      ReminderStatus.inactive => 'Inactive',
    };

    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _ReminderRow extends StatelessWidget {
  const _ReminderRow({
    required this.reminder,
    required this.onTap,
    required this.onMarkDone,
    required this.onSnooze,
  });

  final Reminder reminder;
  final VoidCallback onTap;
  final Future<void> Function() onMarkDone;
  final Future<void> Function() onSnooze;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (reminder.status) {
      ReminderStatus.overdue => cs.error,
      ReminderStatus.dueToday => Colors.orange,
      ReminderStatus.upcoming => Colors.amber,
      ReminderStatus.inactive => cs.outline,
    };

    return InkWell(
      onTap: () {
        if (reminder.status == ReminderStatus.overdue) {
          HapticService.instance.critical();
        } else {
          HapticService.instance.tap();
        }
        onTap();
      },
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.notifications_active_outlined,
                    color: color,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reminder.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        reminder.notes ?? 'Tap to view details',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      HapticService.instance.selection();
                      await onSnooze();
                    },
                    child: const Text('Snooze'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      HapticService.instance.success();
                      await onMarkDone();
                    },
                    child: const Text('Mark Done'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
