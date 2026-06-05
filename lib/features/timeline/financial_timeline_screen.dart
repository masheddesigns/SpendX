import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/adaptive_personality.dart';
import '../../services/decision_engine.dart';
import '../../services/financial_identity_service.dart';
import '../../services/forecast_engine.dart';
import '../../services/goal_nudge_engine.dart';
import '../../services/money_score_service.dart';
import '../../services/data_audit_service.dart';
import '../../shared/widgets/error_state_widget.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../utils/app_format.dart';
import '../wrapped/models/wrapped_summary.dart';
import 'financial_timeline_provider.dart';

/// Financial Timeline: Past → Present → Future in one scroll.
/// Answers: "Where was I → Where am I → Where am I going"
class FinancialTimelineScreen extends ConsumerWidget {
  const FinancialTimelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineAsync = ref.watch(financialTimelineProvider);
    final cs = Theme.of(context).colorScheme;

    return timelineAsync.when(
      loading: () => const SkeletonLoader.summary(),
      error: (e, _) => ErrorStateWidget(error: e, onRetry: () => ref.invalidate(financialTimelineProvider)),
      data: (timeline) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── IDENTITY + SCORE (crown layer) ────────
            _IdentityBanner(
              identity: timeline.identity,
              score: timeline.moneyScore,
            ),
            const SizedBox(height: 20),

            // ── PAST ──────────────────────────────────
            _SectionLabel('PAST', Icons.history_rounded, cs.tertiary),
            const SizedBox(height: 8),
            _PastCard(wrapped: timeline.weeklyWrapped),

            const SizedBox(height: 24),

            // ── PRESENT ───────────────────────────────
            _SectionLabel('NOW', Icons.radio_button_checked, cs.primary),
            const SizedBox(height: 8),
            _PresentCard(health: timeline.health),

            const SizedBox(height: 24),

            // ── FUTURE (only if meaningful) ──────────
            // Silence rule: suppress when nothing changes a decision
            if (timeline.forecast.isOverspendRisk ||
                (timeline.topInsight != null &&
                    timeline.topInsight!.priority.index <= InsightPriority.high.index)) ...[
              const SizedBox(height: 24),
              _SectionLabel('FUTURE', Icons.auto_graph_rounded, Colors.orange),
              const SizedBox(height: 8),
              _FutureCard(forecast: timeline.forecast),
            ] else if (timeline.forecast.daysElapsed >= 5) ...[
              // After 5 days, show calm "on track" message
              const SizedBox(height: 24),
              _CardShell(
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 18,
                        color: Colors.green.withValues(alpha: 0.7)),
                    const SizedBox(width: 10),
                    Text('Everything looks on track this month.',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 13)),
                  ],
                ),
              ),
            ],

            // ── DECISION (only if not low priority) ──────
            if (timeline.topInsight != null &&
                timeline.topInsight!.priority != InsightPriority.low) ...[
              const SizedBox(height: 16),
              _DecisionCard(insight: timeline.topInsight!),
            ]
            else if (timeline.nudges.isNotEmpty &&
                timeline.nudges.first.type == NudgeType.milestone) ...[
              const SizedBox(height: 16),
              _NudgeCard(nudge: timeline.nudges.first),
            ],

          ],
        ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// SECTION LABEL
// ══════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  const _SectionLabel(this.text, this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5)),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// PAST CARD
// ══════════════════════════════════════════════════════════════════

class _PastCard extends StatelessWidget {
  final WrappedSummary? wrapped;
  const _PastCard({this.wrapped});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (wrapped == null) {
      return _CardShell(
        child: Text('No weekly data yet. Keep tracking!',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
      );
    }

    final savings = wrapped!.totalIncome - wrapped!.totalExpense;
    final isSaving = savings >= 0;

    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This Week',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  isSaving
                      ? 'Saved ${AppFormat.currency(savings)}'
                      : 'Overspent ${AppFormat.currency(savings.abs())}',
                  style: TextStyle(
                    color: isSaving ? Colors.green : cs.error,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text('${wrapped!.transactionCount} txns',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            ],
          ),
          if (wrapped!.topCategories.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Top: ${wrapped!.topCategories.first.categoryName} '
                '(${wrapped!.topCategories.first.percentage.toStringAsFixed(0)}%)',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// PRESENT CARD
// ══════════════════════════════════════════════════════════════════

class _PresentCard extends StatelessWidget {
  final DataHealthScore health;
  const _PresentCard({required this.health});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scoreColor = health.score >= 90
        ? Colors.green
        : health.score >= 75
            ? cs.primary
            : health.score >= 60
                ? Colors.orange
                : cs.error;

    return _CardShell(
      child: Row(
        children: [
          // Score circle
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scoreColor.withValues(alpha: 0.12),
              border: Border.all(color: scoreColor.withValues(alpha: 0.3), width: 2),
            ),
            child: Center(
              child: Text('${health.score.toInt()}',
                  style: TextStyle(
                      color: scoreColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Data Health: ${health.label}',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: cs.onSurface)),
                if (health.breakdown.isNotEmpty)
                  Text(
                    health.breakdown
                        .map((b) => '-${b.penalty.toStringAsFixed(0)} ${b.title}')
                        .join(' · '),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text('All clean',
                      style: TextStyle(color: Colors.green, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// FUTURE CARD
// ══════════════════════════════════════════════════════════════════

class _FutureCard extends StatelessWidget {
  final Forecast forecast;
  const _FutureCard({required this.forecast});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSaving = forecast.projectedSavings >= 0;

    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('End of Month Projection',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            children: [
              _MiniMetric('Expense', AppFormat.currency(forecast.projectedExpense),
                  cs.error),
              const SizedBox(width: 16),
              _MiniMetric('Savings', AppFormat.currency(forecast.projectedSavings.abs()),
                  isSaving ? Colors.green : cs.error),
            ],
          ),
          if (forecast.isOverspendRisk) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 14, color: cs.error),
                  const SizedBox(width: 6),
                  Text(
                    'May overspend by ${AppFormat.currency(forecast.overspendAmount)}',
                    style: TextStyle(
                        color: cs.error, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// NUDGE CARD
// ══════════════════════════════════════════════════════════════════

class _DecisionCard extends StatefulWidget {
  final DecisionInsight insight;
  const _DecisionCard({required this.insight});

  @override
  State<_DecisionCard> createState() => _DecisionCardState();
}

class _DecisionCardState extends State<_DecisionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final insight = widget.insight;
    final color = switch (insight.priority) {
      InsightPriority.critical => cs.error,
      InsightPriority.high => Colors.orange,
      InsightPriority.medium => cs.primary,
      InsightPriority.low => Colors.green,
    };
    final icon = switch (insight.priority) {
      InsightPriority.critical => Icons.warning_rounded,
      InsightPriority.high => Icons.flag_rounded,
      InsightPriority.medium => Icons.info_outline,
      InsightPriority.low => Icons.check_circle_outline,
    };

    return GestureDetector(
      onTap: insight.reasons.isNotEmpty
          ? () => setState(() => _expanded = !_expanded)
          : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(insight.title,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: cs.onSurface)),
                      const SizedBox(height: 2),
                      Text(insight.body,
                          style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.4)),
                    ],
                  ),
                ),
                if (insight.reasons.isNotEmpty)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
              ],
            ),
            // Expandable reasons (why this insight)
            if (_expanded && insight.reasons.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Why:',
                        style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ...insight.reasons.map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('\u2022 ',
                              style: TextStyle(color: color, fontSize: 12)),
                          Expanded(
                            child: Text(r,
                                style: TextStyle(
                                    color: cs.onSurfaceVariant, fontSize: 12)),
                          ),
                        ],
                      ),
                    )),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NudgeCard extends StatelessWidget {
  final Nudge nudge;
  const _NudgeCard({required this.nudge});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (nudge.type) {
      NudgeType.acceleration => (Icons.rocket_launch_rounded, cs.primary),
      NudgeType.delayWarning => (Icons.schedule_rounded, cs.error),
      NudgeType.opportunity => (Icons.lightbulb_outline, Colors.amber),
      NudgeType.milestone => (Icons.emoji_events_rounded, Colors.green),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nudge.title,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: cs.onSurface)),
                const SizedBox(height: 2),
                Text(nudge.body,
                    style: TextStyle(
                        color: cs.onSurfaceVariant, fontSize: 12, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// IDENTITY BANNER (Crown Layer)
// ══════════════════════════════════════════════════════════════════

class _IdentityBanner extends StatelessWidget {
  final FinancialIdentity identity;
  final MoneyScore score;
  const _IdentityBanner({required this.identity, required this.score});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final delta = score.deltaToday;
    final deltaStr = delta >= 0 ? '+$delta' : '$delta';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: identity.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: identity.color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          // Identity emoji + label
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(identity.emoji, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 8),
                    Text(identity.label,
                        style: TextStyle(
                            color: identity.color,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(identity.description,
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Money Score + momentum
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${score.value}',
                  style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 28,
                      fontWeight: FontWeight.w800)),
              if (delta != 0)
                Text('today $deltaStr',
                    style: TextStyle(
                        color: delta > 0 ? Colors.green : cs.error,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              if (score.weeklyDelta != null && score.weeklyDelta != 0)
                Builder(builder: (_) {
                  final p = AdaptivePersonality(identity.type);
                  final text = score.isImproving
                      ? p.scoreMomentumUp(score.weeklyDelta!)
                      : p.scoreMomentumDown(score.weeklyDelta!);
                  return Text(
                    text,
                    style: TextStyle(
                        color: score.isImproving ? Colors.green : cs.error,
                        fontSize: 10),
                  );
                }),
            ],
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// SHARED
// ══════════════════════════════════════════════════════════════════

class _CardShell extends StatelessWidget {
  final Widget child;
  const _CardShell({required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniMetric(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(
            color: color, fontSize: 16, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
