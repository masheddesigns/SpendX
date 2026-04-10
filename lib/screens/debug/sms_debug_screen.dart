import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../features/sms/services/sms_pipeline_logger.dart';
import '../../features/sms/services/sms_safe_mode.dart';
import '../../widgets/spendx_app_bar.dart';

/// Internal debug dashboard for SMS pipeline observability.
/// Shows: pipeline stats, last 50 logs, safe mode status, drift alerts.
class SmsDebugScreen extends StatefulWidget {
  const SmsDebugScreen({super.key});

  @override
  State<SmsDebugScreen> createState() => _SmsDebugScreenState();
}

class _SmsDebugScreenState extends State<SmsDebugScreen> {
  Map<String, dynamic> _lastImport = {};

  @override
  void initState() {
    super.initState();
    SmsPipelineLogger.getLastImportInfo().then((info) {
      if (mounted) setState(() => _lastImport = info);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final log = SmsPipelineLogger.instance;
    final safeMode = SmsSafeMode.instance;
    final stats = log.stats;
    final entries = log.logs.reversed.take(50).toList();

    return Scaffold(
      appBar: const SpendXAppBar(title: 'SMS Pipeline Debug'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Safe Mode Banner ─────────────────────────
          if (safeMode.isEnabled)
            Container(
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.shield_rounded, color: Colors.red, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Safe Mode Active',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.red)),
                        Text('Auto-import paused. All SMS routed to review.',
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 12)),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await safeMode.disable();
                      setState(() {});
                    },
                    child: const Text('Disable'),
                  ),
                ],
              ),
            ),

          // ── Session Stats ────────────────────────────
          _SectionHeader('SESSION STATS'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: stats.entries.map((e) {
              final color = switch (e.key) {
                'Inserted' => Colors.green,
                'Failed' => Colors.red,
                'Review' => Colors.orange,
                'Skipped' => Colors.grey,
                _ => cs.primary,
              };
              return _StatChip(label: e.key, value: e.value, color: color);
            }).toList(),
          ),
          const SizedBox(height: 16),

          // ── Last Import Info ─────────────────────────
          if (_lastImport['lastImport'] != null) ...[
            _SectionHeader('LAST IMPORT'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatAgo(_lastImport['lastImport'] as String),
                    style: TextStyle(
                        color: cs.onSurface, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Imported: ${_lastImport['count']}, '
                    'Skipped: ${_lastImport['skipped']}, '
                    'Failed: ${_lastImport['failed']}',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Pipeline Log ─────────────────────────────
          _SectionHeader('PIPELINE LOG (${entries.length})'),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text('No logs yet',
                    style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            )
          else
            ...entries.map((e) => _LogCard(entry: e)),

          const SizedBox(height: 40),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () {
          log.resetStats();
          setState(() {});
        },
        tooltip: 'Clear Logs',
        child: const Icon(Icons.delete_sweep),
      ),
    );
  }

  String _formatAgo(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      final diff = DateTime.now().difference(date);
      if (diff.inMinutes < 1) return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return DateFormat('dd MMM, hh:mm a').format(date);
    } catch (_) {
      return isoDate;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.primary)),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _StatChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text('$value',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 20)),
          Text(label,
              style: TextStyle(color: color, fontSize: 10)),
        ],
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  final PipelineLogEntry entry;
  const _LogCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (entry.result) {
      PipelineResult.success => (Icons.check_circle, Colors.green),
      PipelineResult.skipped => (Icons.skip_next, Colors.grey),
      PipelineResult.review => (Icons.rate_review, Colors.orange),
      PipelineResult.failed => (Icons.error, Colors.red),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(entry.stage.toUpperCase(),
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: color)),
                    const Spacer(),
                    if (entry.durationMs != null)
                      Text('${entry.durationMs}ms',
                          style: TextStyle(
                              fontSize: 9, color: cs.onSurfaceVariant)),
                    const SizedBox(width: 8),
                    Text(
                        DateFormat('HH:mm:ss').format(entry.timestamp),
                        style: TextStyle(
                            fontSize: 9, color: cs.onSurfaceVariant)),
                  ],
                ),
                if (entry.reason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(entry.reason!,
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
                if (entry.amount != null || entry.merchant != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        if (entry.amount != null) '\u{20B9}${entry.amount}',
                        if (entry.merchant != null) entry.merchant,
                        if (entry.confidence != null)
                          '(${(entry.confidence! * 100).toInt()}%)',
                      ].join(' \u00b7 '),
                      style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
