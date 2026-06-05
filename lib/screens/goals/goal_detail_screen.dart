import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/goals/behavior_engine.dart';
import '../../features/goals/goal_insights_provider.dart';
import '../../features/goals/goal_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../models/goal.dart';
import '../../models/goal_log.dart';
import '../../models/transaction.dart';
import '../../utils/app_format.dart';
import 'add_goal_screen.dart';
import '../../shared/widgets/app_page_route.dart';

class GoalDetailScreen extends ConsumerStatefulWidget {
  final Goal goal;

  const GoalDetailScreen({super.key, required this.goal});

  @override
  ConsumerState<GoalDetailScreen> createState() => _GoalDetailScreenState();
}

class _GoalDetailScreenState extends ConsumerState<GoalDetailScreen> {
  late Goal _goal;

  @override
  void initState() {
    super.initState();
    _goal = widget.goal;
  }

  void _refreshGoal() async {
    final all = await ref.read(goalRepoProvider).getAll();
    final updated = all.where((g) => g.id == _goal.id).firstOrNull;
    if (updated != null && mounted) {
      setState(() => _goal = updated);
    }
  }

  Future<void> _logProgress() async {
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final result = await showDialog<({double amount, String? note})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          _goal.type == GoalType.debtPayoff ? 'Log Payment' : 'Log Savings',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: '\u20b9 ',
                filled: true,
                fillColor: Theme.of(ctx).colorScheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: InputDecoration(
                labelText: 'Note (optional)',
                filled: true,
                fillColor: Theme.of(ctx).colorScheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final raw = amountCtrl.text.trim().replaceAll(',', '');
              final val = double.tryParse(raw);
              if (val != null && val > 0) {
                Navigator.pop(ctx, (
                  amount: val,
                  note: noteCtrl.text.trim().isNotEmpty
                      ? noteCtrl.text.trim()
                      : null,
                ));
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null) {
      final log = GoalLog(
        goalId: _goal.id,
        amount: result.amount,
        note: result.note,
      );
      await ref.read(goalRepoProvider).addLog(log);
      ref.invalidate(goalsProvider);
      ref.invalidate(goalLogsProvider(_goal.id));
      _refreshGoal();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added ${AppFormat.currency(result.amount)}')),
        );
      }
    }
  }

  Future<void> _deleteLog(GoalLog log) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry?'),
        content: Text('Remove ${AppFormat.currency(log.amount)} from this goal?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(goalRepoProvider).deleteLog(log);
      ref.invalidate(goalsProvider);
      ref.invalidate(goalLogsProvider(_goal.id));
      _refreshGoal();
    }
  }

  Future<void> _deleteGoal() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Goal?'),
        content: Text('Delete "${_goal.title}"? All progress logs will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(goalRepoProvider).delete(_goal.id);
      ref.invalidate(goalsProvider);
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _markComplete() async {
    await ref.read(goalRepoProvider).update(
      _goal.copyWith(currentAmount: _goal.targetAmount, isActive: false),
    );
    ref.invalidate(goalsProvider);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _editGoal() async {
    final result = await Navigator.push(
      context,
      AppPageRoute(builder: (_) => AddGoalScreen(existing: _goal)),
    );
    if (result == true) {
      ref.invalidate(goalsProvider);
      _refreshGoal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final progress = ref.watch(goalProgressProvider(_goal));
    final logsAsync = ref.watch(goalLogsProvider(_goal.id));
    final nudgesAsync = ref.watch(goalInsightsProvider);
    final pct = progress.progressPct.clamp(0.0, 1.0);
    final pctText = (pct * 100).round();
    final now = DateTime.now();
    final isOverdue = now.isAfter(_goal.endDate) && !progress.isCompleted;

    final Color barColor;
    if (progress.isOverBudget) {
      barColor = cs.error;
    } else if (progress.isCompleted) {
      barColor = const Color(0xFF22C55E);
    } else if (pct >= 0.7) {
      barColor = const Color(0xFF22C55E);
    } else if (pct >= 0.4) {
      barColor = const Color(0xFFF59E0B);
    } else {
      barColor = cs.error;
    }

    final isManualProgress =
        _goal.type == GoalType.savings || _goal.type == GoalType.debtPayoff;

    return Scaffold(
      appBar: AppBar(
        title: Text(_goal.title),
        actions: [
          IconButton(
            onPressed: _editGoal,
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit goal',
          ),
          IconButton(
            onPressed: _deleteGoal,
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: 'Delete goal',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Edge State Banners ─────────────────────────────────────
          if (progress.isCompleted)
            _Banner(
              icon: Icons.check_circle_rounded,
              text: 'Goal Achieved!',
              color: const Color(0xFF22C55E),
            ),
          if (isOverdue)
            _Banner(
              icon: Icons.warning_amber_rounded,
              text: 'Goal deadline has passed',
              color: cs.error,
            ),

          // ── Progress Ring ──────────────────────────────────────────
          const SizedBox(height: 8),
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: pct),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => SizedBox(
                width: 150,
                height: 150,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 150,
                      height: 150,
                      child: CircularProgressIndicator(
                        value: value,
                        strokeWidth: 12,
                        backgroundColor: cs.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation(barColor),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$pctText%',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: barColor,
                          ),
                        ),
                        Text(
                          progress.isCompleted
                              ? 'Done!'
                              : isOverdue
                                  ? 'Overdue'
                                  : '${progress.daysLeft}d left',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ── Metrics Row ───────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _MetricTile(
                  label: _goal.type == GoalType.spendingLimit ? 'Spent' : 'Saved',
                  value: _goal.type == GoalType.spendingLimit
                      ? AppFormat.currency(progress.currentSpent ?? 0)
                      : AppFormat.currency(_goal.currentAmount),
                  color: progress.isOverBudget ? cs.error : const Color(0xFF22C55E),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricTile(
                  label: 'Remaining',
                  value: AppFormat.currency(progress.remaining),
                  color: cs.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricTile(
                  label: _goal.type == GoalType.spendingLimit ? '/day left' : '/day needed',
                  value: AppFormat.currency(progress.requiredDaily),
                  color: progress.isBehindSchedule ? cs.error : const Color(0xFFF59E0B),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ── Trend Mini-Chart (from logs) ──────────────────────────
          if (isManualProgress)
            logsAsync.when(
              data: (logs) {
                if (logs.length < 2) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _TrendChart(
                    logs: logs.reversed.toList(),
                    target: _goal.targetAmount,
                    color: barColor,
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),

          // ── Nudges ────────────────────────────────────────────────
          nudgesAsync.when(
            data: (nudges) {
              final relevant = nudges.take(2).toList();
              if (relevant.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: relevant.map((n) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              n.type == NudgeType.positive
                                  ? Icons.check_circle_rounded
                                  : n.type == NudgeType.warning
                                      ? Icons.warning_amber_rounded
                                      : Icons.lightbulb_outline_rounded,
                              size: 16,
                              color: n.type == NudgeType.positive
                                  ? const Color(0xFF22C55E)
                                  : n.type == NudgeType.warning
                                      ? const Color(0xFFF59E0B)
                                      : cs.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                n.text,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      )).toList(),
                    ),
                  ),
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          // ── Action Buttons ────────────────────────────────────────
          if (isManualProgress && !progress.isCompleted)
            FilledButton.icon(
              onPressed: _logProgress,
              icon: const Icon(Icons.add_rounded),
              label: Text(
                _goal.type == GoalType.debtPayoff ? 'Log Payment' : 'Log Savings',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),

          if (!progress.isCompleted && !isOverdue) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _markComplete,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Mark as Complete'),
            ),
          ],

          if (_goal.type == GoalType.spendingLimit) ...[
            const SizedBox(height: 12),
            Text(
              'Spending limit updates automatically from transactions.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],

          const SizedBox(height: 24),

          // ── Progress Log ──────────────────────────────────────────
          if (isManualProgress) ...[
            Text(
              'Progress Log',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            logsAsync.when(
              data: (logs) {
                if (logs.isEmpty) {
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          'No entries yet. Tap the button above to log progress.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  );
                }
                return Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < logs.length; i++) ...[
                        _LogTile(log: logs[i], onDelete: () => _deleteLog(logs[i])),
                        if (i < logs.length - 1) const Divider(height: 1, indent: 16, endIndent: 16),
                      ],
                    ],
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ],

          // ── Related Transactions ────────────────────────────────────
          const SizedBox(height: 24),
          _RelatedTransactions(goal: _goal),

          // ── Date Info ─────────────────────────────────────────────
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _StatRow(label: 'Start Date', value: AppFormat.date(_goal.startDate)),
                  const Divider(height: 16),
                  _StatRow(label: 'End Date', value: AppFormat.date(_goal.endDate)),
                  const Divider(height: 16),
                  _StatRow(label: 'Target', value: AppFormat.currency(_goal.targetAmount)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Edge State Banner ────────────────────────────────────────────────────

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _Banner({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Metric Tile ──────────────────────────────────────────────────────────

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MetricTile({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Trend Chart ──────────────────────────────────────────────────────────

class _TrendChart extends StatelessWidget {
  final List<GoalLog> logs;
  final double target;
  final Color color;

  const _TrendChart({required this.logs, required this.target, required this.color});

  @override
  Widget build(BuildContext context) {
    // Build cumulative data points
    final points = <double>[];
    double cumulative = 0;
    for (final log in logs) {
      cumulative += log.amount;
      points.add(cumulative);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Progress Over Time',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 80,
              child: CustomPaint(
                size: const Size(double.infinity, 80),
                painter: _TrendPainter(
                  points: points,
                  target: target,
                  color: color,
                  bgColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${logs.length} entries',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  'Target: ${AppFormat.currency(target)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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

class _TrendPainter extends CustomPainter {
  final List<double> points;
  final double target;
  final Color color;
  final Color bgColor;

  _TrendPainter({required this.points, required this.target, required this.color, required this.bgColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final maxVal = math.max(target, points.reduce(math.max));
    final stepX = points.length > 1 ? size.width / (points.length - 1) : size.width;

    // Target line
    final targetY = size.height - (target / maxVal * size.height * 0.9) - size.height * 0.05;
    final dashPaint = Paint()
      ..color = bgColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, targetY), Offset(size.width, targetY), dashPaint);

    // Progress line
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();

    for (var i = 0; i < points.length; i++) {
      final x = i * stepX;
      final y = size.height - (points[i] / maxVal * size.height * 0.9) - size.height * 0.05;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo((points.length - 1) * stepX, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => true;
}

// ── Stat Row ─────────────────────────────────────────────────────────────

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        )),
        Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        )),
      ],
    );
  }
}

// ── Related Transactions ─────────────────────────────────────────────────

class _RelatedTransactions extends ConsumerWidget {
  final Goal goal;

  const _RelatedTransactions({required this.goal});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final txnsAsync = ref.watch(transactionsProvider);

    return txnsAsync.when(
      data: (allTxns) {
        // Filter transactions related to this goal
        final related = _filterTransactions(allTxns);
        if (related.isEmpty) return const SizedBox.shrink();

        // Show max 20, sorted by date descending
        final display = related.take(20).toList();
        final totalAmount = related.fold<double>(0, (s, t) => s + t.amount);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Transaction History',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${related.length} txns \u2022 ${AppFormat.currency(totalAmount)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < display.length; i++) ...[
                    _TransactionTile(tx: display[i]),
                    if (i < display.length - 1)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  ],
                  if (related.length > 20)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '+ ${related.length - 20} more transactions',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }

  List<Transaction> _filterTransactions(List<Transaction> allTxns) {
    return allTxns.where((tx) {
      // Must be within goal date range
      if (tx.date.isBefore(goal.startDate)) return false;
      if (tx.date.isAfter(goal.endDate)) return false;

      switch (goal.type) {
        case GoalType.spendingLimit:
          // Match expenses for the goal's category
          if (tx.type != 'expense') return false;
          if (goal.categoryId != null && tx.categoryId != goal.categoryId) {
            return false;
          }
          return true;
        case GoalType.savings:
          // Show income transactions (savings contributions)
          return tx.type == 'income';
        case GoalType.debtPayoff:
          // Show transfers/payments (credit card payments, loan payments)
          return tx.source == 'credit_card_payment' ||
              tx.source == 'loan_payment' ||
              tx.type == 'transfer';
      }
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }
}

class _TransactionTile extends StatelessWidget {
  final Transaction tx;

  const _TransactionTile({required this.tx});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isExpense = tx.type == 'expense';
    final color = isExpense ? cs.error : const Color(0xFF22C55E);

    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(
          isExpense ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
          color: color,
          size: 16,
        ),
      ),
      title: Text(
        '${isExpense ? '-' : '+'}${AppFormat.currency(tx.amount)}',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: color,
          fontSize: 14,
        ),
      ),
      subtitle: Text(
        tx.notes.isNotEmpty
            ? tx.notes.length > 40
                ? '${tx.notes.substring(0, 40)}...'
                : tx.notes
            : tx.source,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontSize: 11,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        AppFormat.date(tx.date),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }
}

// ── Log Tile ─────────────────────────────────────────────────────────────

class _LogTile extends StatelessWidget {
  final GoalLog log;
  final VoidCallback onDelete;

  const _LogTile({required this.log, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: const Color(0xFF22C55E).withValues(alpha: 0.12),
        child: const Icon(Icons.add_rounded, color: Color(0xFF22C55E), size: 18),
      ),
      title: Text(AppFormat.currency(log.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        log.note != null
            ? '${AppFormat.date(log.createdAt)} \u2022 ${log.note}'
            : AppFormat.date(log.createdAt),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: Icon(Icons.delete_outline_rounded, size: 20, color: cs.error),
        onPressed: onDelete,
        tooltip: 'Delete entry',
      ),
    );
  }
}
