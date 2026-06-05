import 'package:flutter/material.dart';

import '../../services/import_validation_log.dart';
import '../../services/retention_events.dart';

/// Internal debug panel for the retention observation window.
///
/// Shows today's metrics + last 7 days. Read-only. No analytics SDK.
/// Hidden from end users — accessed via Debug Hub only.
class RetentionMetricsScreen extends StatefulWidget {
  const RetentionMetricsScreen({super.key});

  @override
  State<RetentionMetricsScreen> createState() => _RetentionMetricsScreenState();
}

class _RetentionMetricsScreenState extends State<RetentionMetricsScreen> {
  RetentionRates? _today;
  RetentionRates? _sevenDayAvg;
  Map<String, Map<String, int>>? _last7Days;
  ImportValidationStats? _import;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = RetentionEvents.instance;
    final today = await events.ratesFor();
    final avg = await events.sevenDayAverage();
    final history = await events.recent(days: 7);
    final import = await ImportValidationLog.instance.snapshot();
    if (!mounted) return;
    setState(() {
      _today = today;
      _sevenDayAvg = avg;
      _last7Days = history;
      _import = import;
      _loading = false;
    });
  }

  Future<void> _resetImport() async {
    await ImportValidationLog.instance.reset();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Retention Metrics'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 7-day average — anchor to prevent overreacting to today
                  _sevenDayAverageBar(_sevenDayAvg!, cs),
                  const SizedBox(height: 16),
                  Text('TODAY',
                      style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          letterSpacing: 1)),
                  const SizedBox(height: 8),
                  _todayCard(_today!, cs),
                  const SizedBox(height: 24),
                  Text('LAST 7 DAYS',
                      style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          letterSpacing: 1)),
                  const SizedBox(height: 8),
                  if (_last7Days!.isEmpty)
                    Text('No data yet',
                        style: TextStyle(color: cs.onSurfaceVariant))
                  else
                    ..._last7Days!.entries.map((e) => _historyTile(e, cs)),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text('IMPORT VALIDATION',
                          style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              letterSpacing: 1)),
                      const Spacer(),
                      TextButton(
                        onPressed: _resetImport,
                        child: const Text('Reset',
                            style: TextStyle(fontSize: 11)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _importCard(_import!, cs),
                  const SizedBox(height: 24),
                  _watchTargets(cs),
                ],
              ),
            ),
    );
  }

  Widget _sevenDayAverageBar(RetentionRates r, ColorScheme cs) {
    String fmt(int? v) => v == null ? '--' : '$v%';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '7d avg: CTA ${fmt(r.ctaClickRate)} · '
              'Review ${fmt(r.reviewCompletionRate)} · '
              'Notif ${fmt(r.notifOpenRate)}',
              style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _todayCard(RetentionRates r, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('App opens', '${r.appOpens}'),
          _row('Digest shown', '${r.digestShown}'),
          _row('CTA taps', '${r.ctaClicked}',
              suffix: r.ctaClickRate != null
                  ? '(${r.ctaClickRate}%)'
                  : null,
              highlight: _ctaColor(r.ctaClickRate)),
          const Divider(height: 24),
          _row('Reviews shown', '${r.reviewShown}'),
          _row(
              'Reviews completed',
              '${r.reviewApproved + r.reviewRejected}',
              suffix: r.reviewCompletionRate != null
                  ? '(${r.reviewCompletionRate}%)'
                  : null,
              highlight: _completionColor(r.reviewCompletionRate)),
          _row('  approved', '${r.reviewApproved}', dim: true),
          _row('  rejected', '${r.reviewRejected}', dim: true),
          const Divider(height: 24),
          _row('Notifications sent', '${r.notifReceived}'),
          _row('Notifications opened', '${r.notifOpened}',
              suffix: r.notifOpenRate != null
                  ? '(${r.notifOpenRate}%)'
                  : null,
              highlight: _notifColor(r.notifOpenRate)),
          const Divider(height: 24),
          _row('All-set shown', '${r.allSetShown}'),
          _row('Recovery shown', '${r.recoveryShown}'),
        ],
      ),
    );
  }

  Widget _historyTile(MapEntry<String, Map<String, int>> entry, ColorScheme cs) {
    final dayLabel = entry.key.replaceFirst('events_', '');
    final c = entry.value;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(dayLabel,
              style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 12)),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: c.entries
                  .map((e) => _miniChip(e.key, e.value, cs))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniChip(String name, int value, ColorScheme cs) {
    final short = _shortName(name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text('$short:$value',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
    );
  }

  Widget _row(String label, String value,
      {String? suffix, Color? highlight, bool dim = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: dim ? Colors.grey : null,
                    fontSize: dim ? 12 : 13,
                    fontWeight: dim ? FontWeight.w400 : FontWeight.w500)),
          ),
          Text(value,
              style: TextStyle(
                  color: highlight,
                  fontWeight: FontWeight.w600,
                  fontSize: 14)),
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Text(suffix,
                style: TextStyle(
                    color: highlight ?? Colors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ],
        ],
      ),
    );
  }

  Widget _importCard(ImportValidationStats s, ColorScheme cs) {
    String pct(int? v) => v == null ? '--' : '$v%';
    String ms(int? v) => v == null ? '--' : '$v ms';

    Color? targetColor(int? actual, int target) {
      if (actual == null) return null;
      return actual >= target ? Colors.green : Colors.orange;
    }

    Color? latencyColor(int? v) {
      if (v == null) return null;
      return v <= 2500 ? Colors.green : Colors.orange;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Imports shown', '${s.total}'),
          const Divider(height: 24),
          _row('Amount accuracy', pct(s.amountAccuracy),
              suffix: '(target ≥ 95%)',
              highlight: targetColor(s.amountAccuracy, 95)),
          _row('Merchant accuracy', pct(s.merchantAccuracy),
              suffix: '(target ≥ 80%)',
              highlight: targetColor(s.merchantAccuracy, 80)),
          _row('Correction rate', pct(s.correctionRate),
              suffix: '(target ≤ 20%)',
              highlight: s.correctionRate == null
                  ? null
                  : (s.correctionRate! <= 20 ? Colors.green : Colors.orange)),
          const Divider(height: 24),
          _row('  amount edits', '${s.amountEdits}', dim: true),
          _row('  merchant edits', '${s.merchantEdits}', dim: true),
          _row('  any correction', '${s.corrected}', dim: true),
          const Divider(height: 24),
          _row('Avg latency (share→preview)', ms(s.avgLatencyMs),
              suffix: '(target ≤ 2500 ms, n=${s.sampleSize})',
              highlight: latencyColor(s.avgLatencyMs)),
        ],
      ),
    );
  }

  Widget _watchTargets(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TARGETS',
              style: TextStyle(
                  color: Colors.blue,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          _bullet('Digest CTA: 40-60% (alert if <25%)'),
          _bullet('Review completion: >40%'),
          _bullet('Notification open: >15%'),
          _bullet('Correction rate: should trend down'),
        ],
      ),
    );
  }

  Widget _bullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('• $text',
          style: const TextStyle(fontSize: 12, height: 1.4)),
    );
  }

  Color? _ctaColor(int? rate) {
    if (rate == null) return null;
    if (rate >= 40) return Colors.green;
    if (rate >= 25) return Colors.orange;
    return Colors.red;
  }

  Color? _completionColor(int? rate) {
    if (rate == null) return null;
    if (rate >= 40) return Colors.green;
    return Colors.red;
  }

  Color? _notifColor(int? rate) {
    if (rate == null) return null;
    if (rate >= 15) return Colors.green;
    return Colors.red;
  }

  String _shortName(String full) {
    return switch (full) {
      'appOpen' => 'open',
      'dailyDigestShown' => 'digest',
      'dailyDigestCtaClicked' => 'cta',
      'allSetShown' => 'allset',
      'recoveryStateShown' => 'recovery',
      'reviewItemShown' => 'rev.shown',
      'reviewItemApproved' => 'rev.ok',
      'reviewItemRejected' => 'rev.no',
      'notificationReceived' => 'notif.in',
      'notificationOpened' => 'notif.tap',
      _ => full,
    };
  }
}
