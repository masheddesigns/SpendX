import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/health/health_score_provider.dart';
import '../shared/widgets/error_state_widget.dart';
import '../shared/widgets/skeleton_loader.dart';

/// Detail screen for financial health — uses the SAME provider as Insights card.
class FinancialHealthScreen extends ConsumerWidget {
  const FinancialHealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scoreAsync = ref.watch(financialHealthScoreProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial Health'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: scoreAsync.when(
          loading: () => const SkeletonLoader.summary(),
          error: (e, _) => ErrorStateWidget(error: e, onRetry: () => ref.invalidate(financialHealthScoreProvider)),
          data: (score) {
            final color = _scoreColor(score.score);
            final bd = score.breakdown;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Score Circle ────────────────────────────
                  Center(
                    child: Column(
                      children: [
                        _ScoreRing(score: score.score, color: color),
                        const SizedBox(height: 16),
                        Text(score.level,
                            style: TextStyle(
                                color: color,
                                fontSize: 24,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text('Your financial discipline score',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 14)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),

                  // ── Breakdown ───────────────────────────────
                  _sectionLabel(context, 'SCORE BREAKDOWN'),
                  const SizedBox(height: 20),
                  _MetricBar(
                      label: 'Savings',
                      score: bd.savingsScore,
                      max: 30,
                      color: Colors.green),
                  _MetricBar(
                      label: 'Debt Management',
                      score: bd.debtScore,
                      max: 25,
                      color: Colors.blue),
                  _MetricBar(
                      label: 'Stability',
                      score: bd.stabilityScore,
                      max: 20,
                      color: Colors.orange),
                  _MetricBar(
                      label: 'Liquidity',
                      score: bd.liquidityScore,
                      max: 15,
                      color: Colors.teal),
                  _MetricBar(
                      label: 'Credit Usage',
                      score: bd.utilizationScore,
                      max: 10,
                      color: Colors.purple),

                  // ── Insights ────────────────────────────────
                  if (score.insights.isNotEmpty) ...[
                    const SizedBox(height: 32),
                    _sectionLabel(context, 'INSIGHTS'),
                    const SizedBox(height: 12),
                    ...score.insights.map((i) => _InsightTile(insight: i)),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Text(text,
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5));
  }

  Color _scoreColor(int score) {
    if (score >= 80) return const Color(0xFF22C55E);
    if (score >= 60) return const Color(0xFF0EA5E9);
    if (score >= 40) return const Color(0xFFF59E0B);
    return Colors.redAccent;
  }
}

class _ScoreRing extends StatelessWidget {
  final int score;
  final Color color;
  const _ScoreRing({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      height: 160,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 160,
            height: 160,
            child: CircularProgressIndicator(
              value: score / 100,
              strokeWidth: 10,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(color),
              strokeCap: StrokeCap.round,
            ),
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$score',
                  style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      color: color)),
              Text('/ 100',
                  style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricBar extends StatelessWidget {
  final String label;
  final int score;
  final int max;
  final Color color;

  const _MetricBar({
    required this.label,
    required this.score,
    required this.max,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 14)),
              Text('$score / $max',
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: max > 0 ? (score / max).clamp(0.0, 1.0) : 0,
              minHeight: 8,
              backgroundColor: color.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightTile extends StatelessWidget {
  final HealthInsight insight;
  const _InsightTile({required this.insight});

  @override
  Widget build(BuildContext context) {
    final icon = switch (insight.type) {
      HealthInsightType.positive => Icons.check_circle_rounded,
      HealthInsightType.warning => Icons.warning_amber_rounded,
      HealthInsightType.actionable => Icons.lightbulb_outline_rounded,
    };
    final color = switch (insight.type) {
      HealthInsightType.positive => const Color(0xFF22C55E),
      HealthInsightType.warning => const Color(0xFFF59E0B),
      HealthInsightType.actionable => const Color(0xFF0EA5E9),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(insight.text,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4)),
          ),
        ],
      ),
    );
  }
}
