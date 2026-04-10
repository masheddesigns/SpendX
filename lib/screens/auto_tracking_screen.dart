import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/sms/providers/sms_providers.dart';
import '../features/sms/services/sms_safe_mode.dart';
import '../features/sms/services/sms_pipeline_logger.dart';
import '../features/transactions/providers/transaction_providers.dart';
import '../features/review_queue/providers/review_providers.dart';
import '../services/haptic_service.dart';
import '../widgets/spendx_app_bar.dart';
import '../widgets/custom_snackbar.dart';

/// Auto Tracking screen — surfaces SMS engine as a user-facing feature.
/// Shows: status, last sync, accuracy, monthly stats, import actions.
class AutoTrackingScreen extends ConsumerStatefulWidget {
  const AutoTrackingScreen({super.key});

  @override
  ConsumerState<AutoTrackingScreen> createState() => _AutoTrackingScreenState();
}

class _AutoTrackingScreenState extends ConsumerState<AutoTrackingScreen> {
  Map<String, dynamic> _lastImport = {};
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    SmsPipelineLogger.getLastImportInfo().then((info) {
      if (mounted) setState(() => _lastImport = info);
    });
  }

  Future<void> _runImport({DateTime? sinceDate}) async {
    if (_importing) return;
    setState(() => _importing = true);

    HapticService.instance.tap();
    ref.read(isSmsEnabledProvider.notifier).state = true;

    final imported = await ref.read(importRecentSmsProvider)(
      limit: 4000,
      sinceDate: sinceDate,
    );

    // Save import history for display
    await SmsPipelineLogger.instance.saveImportHistory();

    ref.invalidate(transactionsProvider);
    ref.read(paginatedTransactionsProvider.notifier).refresh();

    // Refresh stats
    final info = await SmsPipelineLogger.getLastImportInfo();

    if (mounted) {
      setState(() {
        _importing = false;
        _lastImport = info;
      });
      CustomSnackBar.show(context,
          message: imported == 0
              ? 'No new transactions found'
              : 'Imported $imported transactions');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final safeMode = SmsSafeMode.instance;
    final log = SmsPipelineLogger.instance;
    final reviewCount =
        ref.watch(reviewQueueCountProvider).valueOrNull ?? 0;

    final lastSync = _lastImport['lastImport'] as String?;
    final lastCount = _lastImport['count'] as int? ?? 0;
    final lastSkipped = _lastImport['skipped'] as int? ?? 0;

    // Compute accuracy from session stats
    final total = log.totalProcessed;
    final inserted = log.totalInserted;
    final accuracy = total > 0 ? ((inserted / total) * 100).round() : 0;
    final reviewRate =
        total > 0 ? ((log.totalReview / total) * 100).round() : 0;

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Auto Tracking'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Status Card ─────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: safeMode.isEnabled
                      ? [Colors.red.withValues(alpha: 0.15), Colors.red.withValues(alpha: 0.05)]
                      : [cs.primary.withValues(alpha: 0.15), cs.primary.withValues(alpha: 0.05)],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: (safeMode.isEnabled ? Colors.red : cs.primary)
                        .withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: (safeMode.isEnabled ? Colors.red : cs.primary)
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          safeMode.isEnabled
                              ? Icons.shield_rounded
                              : Icons.auto_awesome_rounded,
                          color: safeMode.isEnabled ? Colors.red : cs.primary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              safeMode.isEnabled ? 'Paused' : 'Active',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: safeMode.isEnabled
                                    ? Colors.red
                                    : cs.primary,
                              ),
                            ),
                            Text(
                              safeMode.isEnabled
                                  ? 'Auto-import paused for safety'
                                  : 'Auto-detecting transactions from SMS',
                              style: TextStyle(
                                  color: cs.onSurfaceVariant, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (safeMode.isEnabled) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () async {
                          await safeMode.disable();
                          setState(() {});
                        },
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red),
                        child: const Text('Resume Auto Tracking'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Metrics Grid ────────────────────────────
            Row(
              children: [
                Expanded(
                    child: _MetricCard(
                        label: 'Last Sync',
                        value: _formatAgo(lastSync),
                        icon: Icons.sync)),
                const SizedBox(width: 10),
                Expanded(
                    child: _MetricCard(
                        label: 'Last Import',
                        value: '+$lastCount',
                        icon: Icons.add_circle_outline)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                    child: _MetricCard(
                        label: 'Accuracy',
                        value: total > 0 ? '$accuracy%' : '--',
                        icon: Icons.check_circle_outline,
                        valueColor:
                            accuracy >= 90 ? Colors.green : Colors.orange)),
                const SizedBox(width: 10),
                Expanded(
                    child: _MetricCard(
                        label: 'Review Rate',
                        value: total > 0 ? '$reviewRate%' : '--',
                        icon: Icons.rate_review_outlined)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                    child: _MetricCard(
                        label: 'Pending Review',
                        value: '$reviewCount',
                        icon: Icons.pending_actions,
                        valueColor:
                            reviewCount > 0 ? Colors.orange : Colors.green)),
                const SizedBox(width: 10),
                Expanded(
                    child: _MetricCard(
                        label: 'Skipped',
                        value: '$lastSkipped',
                        icon: Icons.skip_next_outlined)),
              ],
            ),

            const SizedBox(height: 24),

            // ── Import Actions ──────────────────────────
            Text('IMPORT',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: cs.primary)),
            const SizedBox(height: 12),

            _ImportButton(
              icon: Icons.today,
              title: 'Last 7 Days',
              subtitle: 'Quick scan',
              loading: _importing,
              onTap: () => _runImport(
                  sinceDate:
                      DateTime.now().subtract(const Duration(days: 7))),
            ),
            const SizedBox(height: 8),
            _ImportButton(
              icon: Icons.date_range,
              title: 'Last 30 Days',
              subtitle: 'Recommended',
              loading: _importing,
              recommended: true,
              onTap: () => _runImport(
                  sinceDate:
                      DateTime.now().subtract(const Duration(days: 30))),
            ),
            const SizedBox(height: 8),
            _ImportButton(
              icon: Icons.calendar_month,
              title: 'Last 3 Months',
              subtitle: 'Thorough scan',
              loading: _importing,
              onTap: () => _runImport(
                  sinceDate:
                      DateTime.now().subtract(const Duration(days: 90))),
            ),
            const SizedBox(height: 8),
            _ImportButton(
              icon: Icons.all_inclusive,
              title: 'All Messages',
              subtitle: 'Full history — may take a moment',
              loading: _importing,
              onTap: () => _runImport(),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  String _formatAgo(String? isoDate) {
    if (isoDate == null) return 'Never';
    try {
      final date = DateTime.parse(isoDate);
      final diff = DateTime.now().difference(date);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return 'Unknown';
    }
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(label,
                  style:
                      TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: valueColor ?? cs.onSurface)),
        ],
      ),
    );
  }
}

class _ImportButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool loading;
  final bool recommended;
  final VoidCallback onTap;

  const _ImportButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.loading,
    this.recommended = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: recommended
              ? cs.primary.withValues(alpha: 0.08)
              : cs.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: recommended
              ? Border.all(color: cs.primary.withValues(alpha: 0.3))
              : null,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      if (recommended) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.star, size: 14, color: cs.primary),
                      ],
                    ],
                  ),
                  Text(subtitle,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 11)),
                ],
              ),
            ),
            if (loading)
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(Icons.chevron_right,
                  size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
