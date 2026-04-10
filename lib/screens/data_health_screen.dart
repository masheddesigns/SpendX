import 'package:flutter/material.dart';
import '../services/data_audit_service.dart';
import '../widgets/spendx_app_bar.dart';
import 'home/transactions_screen.dart';

/// Data Health screen — shows audit results with quick-fix actions.
/// Accessible from: More → Data Health, or Home status strip.
class DataHealthScreen extends StatefulWidget {
  const DataHealthScreen({super.key});

  @override
  State<DataHealthScreen> createState() => _DataHealthScreenState();
}

class _DataHealthScreenState extends State<DataHealthScreen> {
  List<AuditIssue>? _issues;
  DataHealthScore? _score;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _runAudit();
  }

  Future<void> _runAudit() async {
    setState(() => _loading = true);
    final issues = await DataAuditService.instance.runAudit(force: true);
    final score = await DataAuditService.instance.getHealthScore();
    if (mounted) setState(() { _issues = issues; _score = score; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Data Health'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _issues == null || _issues!.isEmpty
              ? _buildCleanState(cs)
              : _buildIssuesList(cs),
    );
  }

  Widget _buildCleanState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('100%',
              style: TextStyle(
                  color: Colors.green,
                  fontSize: 56,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('Excellent',
              style: TextStyle(
                  color: Colors.green,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Icon(Icons.verified_rounded, size: 48,
              color: Colors.green.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text('No data issues detected.',
              style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      ),
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
      MaterialPageRoute(
        builder: (_) => TransactionListScreen(
          isFullScreen: true,
          filterIds: issue.transactionIds,
          title: title,
        ),
      ),
    );
  }

  Widget _buildIssuesList(ColorScheme cs) {
    final totalIssues = _issues!.fold<int>(0, (s, i) => s + i.count);
    final score = _score;
    final scoreColor = score != null
        ? (score.score >= 90
            ? Colors.green
            : score.score >= 75
                ? cs.primary
                : score.score >= 60
                    ? Colors.orange
                    : cs.error)
        : cs.onSurfaceVariant;

    return RefreshIndicator(
      onRefresh: _runAudit,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Health Score Hero ───────────────────
          if (score != null)
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: scoreColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: scoreColor.withValues(alpha: 0.2)),
              ),
              child: Column(
                children: [
                  Text('${score.score.toInt()}%',
                      style: TextStyle(
                          color: scoreColor,
                          fontSize: 48,
                          fontWeight: FontWeight.w800)),
                  Text(score.label,
                      style: TextStyle(
                          color: scoreColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  if (score.breakdown.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ...score.breakdown.map((b) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('-${b.penalty.toStringAsFixed(0)}',
                              style: TextStyle(
                                  color: cs.error,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 6),
                          Text(b.title,
                              style: TextStyle(
                                  color: cs.onSurfaceVariant, fontSize: 12)),
                        ],
                      ),
                    )),
                  ],
                ],
              ),
            ),

          // ── Issue count summary ─────────────────
          if (totalIssues > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '$totalIssues issue${totalIssues == 1 ? '' : 's'} to fix',
                style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 16),

          // ── Issue cards ────────────────────────
          ..._issues!.map((issue) => _IssueCard(
            issue: issue,
            onFix: () => _handleFix(issue),
          )),

          const SizedBox(height: 40),
        ],
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
                Text(issue.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 4),
                Text(issue.description,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.4)),
                // Impact message (the "why it matters" line)
                if (issue.impact != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 12,
                          color: cs.error.withValues(alpha: 0.7)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(issue.impact!,
                            style: TextStyle(
                                color: cs.error,
                                fontSize: 11,
                                fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                // Severity + Fix button row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _severityColor(issue.severity)
                            .withValues(alpha: 0.12),
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
                              fontSize: 12, fontWeight: FontWeight.w600),
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
