import 'package:flutter/material.dart';

import '../../../services/haptic_service.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/primary_button.dart';
import '../../../shared/widgets/section_header.dart';
import '../../../shared/widgets/status_chip.dart';
import '../data/app_alert.dart';

class PendingAlertsStrip extends StatelessWidget {
  const PendingAlertsStrip({
    super.key,
    required this.alerts,
    required this.onAlertTap,
    required this.onMarkDone,
    required this.onSnooze,
  });

  final List<AppAlert> alerts;
  final ValueChanged<AppAlert> onAlertTap;
  final Future<void> Function(AppAlert) onMarkDone;
  final Future<void> Function(AppAlert) onSnooze;

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) return const SizedBox.shrink();

    return RepaintBoundary(
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'Pending Alerts'),
            const SizedBox(height: 8),
            Text(
              'Salary, dues, renewals, and smart reminders from one centralized alert engine.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: alerts.length > 4 ? 4 : alerts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final alert = alerts[index];
                return _AlertRow(
                  alert: alert,
                  onTap: () => onAlertTap(alert),
                  onMarkDone: () => onMarkDone(alert),
                  onSnooze: () => onSnooze(alert),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({
    required this.alert,
    required this.onTap,
    required this.onMarkDone,
    required this.onSnooze,
  });

  final AppAlert alert;
  final VoidCallback onTap;
  final Future<void> Function() onMarkDone;
  final Future<void> Function() onSnooze;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final borderColor = switch (alert.severity) {
      AlertSeverity.normal => cs.outlineVariant,
      AlertSeverity.warning => Colors.orange.withValues(alpha: 0.35),
      AlertSeverity.critical => cs.error.withValues(alpha: 0.35),
    };

    final chipType = switch (alert.severity) {
      AlertSeverity.normal => StatusChipType.pending,
      AlertSeverity.warning => StatusChipType.pending,
      AlertSeverity.critical => StatusChipType.delayed,
    };

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        if (alert.severity == AlertSeverity.critical) {
          HapticService.instance.critical();
        } else {
          HapticService.instance.tap();
        }
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    alert.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                StatusChip(
                  label: switch (alert.severity) {
                    AlertSeverity.normal => 'Upcoming',
                    AlertSeverity.warning => 'Due',
                    AlertSeverity.critical => 'Critical',
                  },
                  type: chipType,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              alert.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
            if (alert.triggerDate != null) ...[
              const SizedBox(height: 8),
              Text(
                'Due ${_formatDate(alert.triggerDate!)}',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    label: 'Snooze',
                    tone: PrimaryButtonTone.secondary,
                    hapticType: SpendXHapticType.selection,
                    onPressed: () => onSnooze(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: 'Mark Done',
                    hapticType: SpendXHapticType.success,
                    onPressed: () => onMarkDone(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime date) {
    final month = _monthNames[date.month - 1];
    return '$month ${date.day}';
  }

  static const List<String> _monthNames = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
}
