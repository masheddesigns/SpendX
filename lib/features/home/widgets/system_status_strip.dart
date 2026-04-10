import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/system_alerts_provider.dart';
import '../../../screens/review/review_queue_screen.dart';
import '../../../screens/data_health_screen.dart';

/// Single-priority system status strip on Home.
///
/// Shows ONE message at a time based on priority:
///   1. Safe Mode (blocking)
///   2. Drift (financial inconsistency)
///   3. Review needed (user action)
///   4. Sync success (passive info)
///
/// Never shows multiple chips — one message = one mental model.
class SystemStatusStrip extends ConsumerWidget {
  const SystemStatusStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsAsync = ref.watch(systemAlertsProvider);

    return alertsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (alerts) {
        // Priority 1: Safe mode
        if (alerts.safeModeActive) {
          return _StatusBanner(
            icon: Icons.shield_rounded,
            label: 'Auto-import paused due to unusual activity',
            color: Colors.red,
          );
        }

        // Priority 2: Drift
        if (alerts.driftMessage != null) {
          return _StatusBanner(
            icon: Icons.warning_amber_rounded,
            label: 'Balance mismatch detected',
            color: Colors.amber,
          );
        }

        // Priority 3: Review needed
        if (alerts.reviewCount > 0) {
          return _StatusBanner(
            icon: Icons.rate_review_rounded,
            label: '${alerts.reviewCount} transaction${alerts.reviewCount == 1 ? '' : 's'} need review',
            color: Colors.orange,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ReviewQueueScreen())),
          );
        }

        // Priority 4: Data health issues
        if (alerts.auditIssueCount > 0) {
          return _StatusBanner(
            icon: Icons.health_and_safety_outlined,
            label: '${alerts.auditIssueCount} data issue${alerts.auditIssueCount == 1 ? '' : 's'} found',
            color: Colors.orange,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DataHealthScreen())),
          );
        }

        // Priority 5: Sync info (subtle, passive)
        if (alerts.hasSync) {
          return _SyncInfo(
            lastSync: alerts.lastSyncAgo!,
            count: alerts.lastSyncCount,
          );
        }

        return const SizedBox.shrink();
      },
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _StatusBanner({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: color, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, size: 16, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncInfo extends StatelessWidget {
  final String lastSync;
  final int count;
  const _SyncInfo({required this.lastSync, required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            count > 0 ? '+$count synced \u00b7 $lastSync' : 'Synced $lastSync',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
