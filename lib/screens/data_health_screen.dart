import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../features/review_queue/providers/review_providers.dart';
import '../services/data_audit_service.dart';
import '../services/inbox_audit_service.dart';
import '../widgets/spendx_app_bar.dart';
import '../shared/widgets/app_page_route.dart';
import 'home/transactions_screen.dart';
import 'review/review_queue_screen.dart';

/// Data Health screen — shows ledger integrity audit and inbox coverage diagnostics.
/// Accessible from: More → Data Health & Integrity.
class DataHealthScreen extends ConsumerStatefulWidget {
  const DataHealthScreen({super.key});

  @override
  ConsumerState<DataHealthScreen> createState() => _DataHealthScreenState();
}

class _DataHealthScreenState extends ConsumerState<DataHealthScreen> {
  List<AuditIssue>? _issues;
  DataHealthScore? _score;
  InboxAuditResult? _inboxResult;
  bool _loading = true;
  bool _scanningInbox = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    final issues = await DataAuditService.instance.runAudit(force: true);
    final score = await DataAuditService.instance.getHealthScore();
    final cachedInbox = await InboxAuditService.instance.loadCachedResult();
    if (mounted) {
      setState(() {
        _issues = issues;
        _score = score;
        _inboxResult = cachedInbox;
        _loading = false;
      });
    }
  }

  Future<void> _runInboxScan() async {
    if (_scanningInbox) return;
    setState(() => _scanningInbox = true);
    try {
      final res = await InboxAuditService.instance.runAudit(
        pushToReviewQueue: true,
      );
      ref.invalidate(reviewQueueProvider);
      ref.invalidate(reviewQueueCountProvider);
      if (mounted) {
        setState(() {
          _inboxResult = res;
          _scanningInbox = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _scanningInbox = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Data Health & Diagnostics'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await _loadAll();
                await _runInboxScan();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildHealthScoreHero(cs),
                  const SizedBox(height: 16),
                  _buildInboxDiagnosticCard(cs),
                  const SizedBox(height: 20),
                  _buildLedgerIssuesSection(cs),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  // ── 1. Health Score Hero ────────────────────────────────────────────────
  Widget _buildHealthScoreHero(ColorScheme cs) {
    final score = _score;
    final scoreVal = score?.score ?? 100.0;
    final scoreColor = scoreVal >= 90
        ? Colors.green
        : scoreVal >= 75
            ? cs.primary
            : scoreVal >= 60
                ? Colors.orange
                : cs.error;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scoreColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scoreColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.shield_rounded, color: scoreColor, size: 28),
              const SizedBox(width: 8),
              Text(
                'Ledger Integrity',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${scoreVal.toInt()}%',
            style: TextStyle(
              color: scoreColor,
              fontSize: 48,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            score?.label ?? 'Excellent',
            style: TextStyle(
              color: scoreColor,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (score != null && score.breakdown.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...score.breakdown.map((b) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '-${b.penalty.toStringAsFixed(0)}',
                        style: TextStyle(
                          color: cs.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        b.title,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }

  // ── 2. Inbox Diagnostic Card ────────────────────────────────────────────
  Widget _buildInboxDiagnosticCard(ColorScheme cs) {
    final result = _inboxResult;

    final isScanning = _scanningInbox;
    final hasRun = result != null;
    final isClean = hasRun && result.isClean;
    final hasMissed = hasRun && result.missedCount > 0;
    final noPermission = hasRun && !result.permissionGranted;

    final cardBorder = isClean
        ? Colors.green.withValues(alpha: 0.3)
        : hasMissed
            ? Colors.orange.withValues(alpha: 0.4)
            : cs.outline.withValues(alpha: 0.15);

    final cardBg = isClean
        ? Colors.green.withValues(alpha: 0.05)
        : hasMissed
            ? Colors.orange.withValues(alpha: 0.06)
            : cs.surfaceContainer;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (hasMissed ? Colors.orange : Colors.blue).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.mark_email_read_rounded,
                  color: hasMissed ? Colors.orange : Colors.blue,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SMS & Notification Audit',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Detects financial alerts missed in your inbox',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (isClean)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded, color: Colors.green, size: 14),
                      SizedBox(width: 4),
                      Text(
                        '100% Captured',
                        style: TextStyle(
                          color: Colors.green,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          if (isScanning) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Scanning recent inbox messages & notifications...',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ] else if (noPermission) ...[
            Text(
              'SMS read permission is required to audit incoming bank messages.',
              style: TextStyle(color: cs.error, fontSize: 12),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () async {
                await Permission.sms.request();
                _runInboxScan();
              },
              icon: const Icon(Icons.security_rounded, size: 16),
              label: const Text('Grant Permission & Audit'),
            ),
          ] else if (hasMissed) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        '${result.missedCount} uncaptured transaction${result.missedCount == 1 ? '' : 's'} found!',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${result.capturedCount} captured • ${result.coveragePercentage}% coverage over the last 14 days.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Preview list of missed alerts
            ...result.missedItems.take(3).map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        item.isCredit ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                        color: item.isCredit ? Colors.green : Colors.red,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.merchant ?? item.bankName ?? item.sender,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${item.isCredit ? '+' : '-'}₹${item.amount.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: item.isCredit ? Colors.green : cs.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        AppPageRoute(builder: (_) => const ReviewQueueScreen()),
                      );
                      _loadAll();
                    },
                    icon: const Icon(Icons.rate_review_rounded, size: 16),
                    label: Text('Review in Queue (${result.missedCount})'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orange.shade800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _runInboxScan,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: 'Rescan Inbox',
                ),
              ],
            ),
          ] else if (isClean) ...[
            Text(
              '${result.capturedCount} recent financial alerts analyzed across SMS & notifications. '
              'All transactions are accurately recorded in your double-entry ledger.',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Scanned ${DateFormat('h:mm a, d MMM').format(result.scannedAt)}',
                  style: TextStyle(color: cs.outline, fontSize: 11),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _runInboxScan,
                  icon: const Icon(Icons.refresh_rounded, size: 15),
                  label: const Text('Scan Again'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ] else ...[
            Text(
              'Audit your inbox and notifications to ensure SpendX has not missed any recent transactions or auto-debits.',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _runInboxScan,
                icon: const Icon(Icons.search_rounded, size: 16),
                label: const Text('Run Inbox Diagnostic'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── 3. Ledger Issues Section ────────────────────────────────────────────
  Widget _buildLedgerIssuesSection(ColorScheme cs) {
    final issues = _issues ?? [];
    final totalIssues = issues.fold<int>(0, (s, i) => s + i.count);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Ledger Data Integrity',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            if (totalIssues > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$totalIssues to fix',
                  style: TextStyle(
                    color: cs.error,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (issues.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified_rounded, color: Colors.green, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'All transactions are categorized, assigned to active accounts, and free of duplicates.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ),
              ],
            ),
          )
        else
          ...issues.map((issue) => _IssueCard(
                issue: issue,
                onFix: () => _handleFix(issue),
              )),
      ],
    );
  }

  void _handleFix(AuditIssue issue) {
    final title = switch (issue.type) {
      'uncategorized' => 'Uncategorized Transactions',
      'no_account' => 'Unassigned Transactions',
      'duplicate' => 'Possible Duplicates',
      'abnormal_amount' => 'Unusual Amounts',
      'future_dated' => 'Future-Dated Transactions',
      _ => 'Transactions to Review',
    };

    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => TransactionListScreen(
          isFullScreen: true,
          filterIds: issue.transactionIds,
          title: title,
        ),
      ),
    );
  }
}

class _IssueCard extends StatelessWidget {
  final AuditIssue issue;
  final VoidCallback? onFix;
  const _IssueCard({required this.issue, this.onFix});

  (IconData, Color) _typeVisuals(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (issue.type) {
      'uncategorized' => (Icons.label_off_outlined, Colors.orange),
      'no_account' => (Icons.account_balance_outlined, cs.onSurfaceVariant),
      'duplicate' => (Icons.content_copy_rounded, cs.error),
      'abnormal_amount' => (Icons.trending_up_rounded, Colors.amber),
      'future_dated' => (Icons.schedule_rounded, cs.tertiary),
      _ => (Icons.info_outline, cs.onSurfaceVariant),
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = _typeVisuals(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline.withValues(alpha: 0.1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  issue.title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  issue.description,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                if (issue.impact != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 12,
                        color: cs.error.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          issue.impact!,
                          style: TextStyle(
                            color: cs.error,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _severityColor(issue.severity).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        issue.severity.name.toUpperCase(),
                        style: TextStyle(
                          color: _severityColor(issue.severity),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (onFix != null)
                      TextButton.icon(
                        onPressed: onFix,
                        icon: const Icon(Icons.build_rounded, size: 14),
                        label: const Text('Fix Now'),
                        style: TextButton.styleFrom(
                          foregroundColor: cs.primary,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _severityColor(AuditSeverity s) => switch (s) {
        AuditSeverity.low => Colors.grey,
        AuditSeverity.medium => Colors.orange,
        AuditSeverity.high => Colors.red,
      };
}
