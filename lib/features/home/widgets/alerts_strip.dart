import '../../../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../alerts/data/app_alert.dart';
import '../providers/home_providers.dart';
import '../../../utils/app_format.dart';

/// Horizontal scrollable strip of alert cards shown on the Home dashboard.
/// Each card has a title, amount, and two actions: Mark Done + Snooze.
class AlertsStrip extends ConsumerWidget {
  const AlertsStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsAsync = ref.watch(homeAlertsProvider);

    return alertsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (alerts) {
        if (alerts.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    'Alerts',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .error
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${alerts.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Horizontal scrollable alert cards
            SizedBox(
              height: 110,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: alerts.length,
                itemBuilder: (context, index) {
                  final alert = alerts[index];
                  return _AlertCard(
                    alert: alert,
                    onMarkDone: () {
                      HapticService.instance.tap();
                      ref
                          .read(homeAlertsProvider.notifier)
                          .markDone(alert.id);
                    },
                    onSnooze: () {
                      HapticService.instance.selection();
                      ref
                          .read(homeAlertsProvider.notifier)
                          .snooze(alert.id);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AppAlert alert; // Using AppAlert from models
  final VoidCallback onMarkDone;
  final VoidCallback onSnooze;

  const _AlertCard({
    required this.alert,
    required this.onMarkDone,
    required this.onSnooze,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: 200,
      margin: const EdgeInsets.only(right: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.error.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      // Use Column so everything is inside the card boundary
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Card top: icon + title + amount
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: cs.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _iconForType(alert.type),
                    size: 16,
                    color: cs.error,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alert.title,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (alert.amount != null)
                        Text(
                          AppFormat.currency(alert.amount!),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Spacer(),

          // Action buttons — always inside the card
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: 'Mark Done',
                    icon: Icons.check_rounded,
                    color: cs.primary,
                    onTap: onMarkDone,
                  ),
                ),
                const SizedBox(width: 6),
                _ActionButton(
                  label: 'Snooze',
                  icon: Icons.access_time_rounded,
                  color: cs.onSurfaceVariant,
                  onTap: onSnooze,
                  compact: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(AlertType type) {
    switch (type) {
      case AlertType.loanDue:
      case AlertType.creditCardDue:
        return Icons.account_balance_rounded;
      case AlertType.salaryDue:
      case AlertType.salaryDelayed:
      case AlertType.partialSalary:
        return Icons.payments_rounded;
      case AlertType.vehicleService:
        return Icons.build_rounded;
      case AlertType.subscriptionDue:
        return Icons.notifications_rounded;
      case AlertType.custom:
        return Icons.notifications_rounded;
    }
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool compact;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: color),
            if (!compact) ...[
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
