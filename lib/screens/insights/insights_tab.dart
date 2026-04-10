import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math' as math;

import '../../features/anomaly/anomaly_model.dart';
import '../../features/anomaly/anomaly_provider.dart';
import '../../features/cashflow/runway_engine.dart';
import '../../features/cashflow/runway_provider.dart';
import '../../features/dashboard/insights_providers.dart';
import '../../features/forecast/forecast_provider.dart';
import '../../features/gamification/xp_provider.dart';
import '../../features/health/health_score_provider.dart';
import '../../features/liabilities/providers/credit_health_providers.dart';
import '../../features/streak/streak_provider.dart';
import '../../models/streak.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../credit_card_screen.dart';
import '../financial_health_screen.dart';
import '../net_worth_screen.dart';

/// Insights tab — answers "What is happening with my money?"
/// Consolidated into 6 clear sections. Scannable in 5 seconds.
class InsightsTab extends ConsumerWidget {
  const InsightsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthScore = ref.watch(financialHealthScoreProvider);
    final runwayAsync = ref.watch(runwayProvider);
    final anomaliesAsync = ref.watch(anomalyProvider);
    final nwChange = ref.watch(netWorthChangeProvider);
    final creditHealth = ref.watch(creditHealthProvider);
    final monthStats = ref.watch(currentMonthStatsProvider);
    final prevStats = ref.watch(previousMonthStatsProvider);
    final forecastAsync = ref.watch(forecastProvider);
    final streakAsync = ref.watch(streakProvider);
    final xpAsync = ref.watch(xpProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(financialHealthScoreProvider);
        ref.invalidate(runwayProvider);
        ref.invalidate(anomalyProvider);
        ref.invalidate(netWorthChangeProvider);
        ref.invalidate(creditHealthProvider);
        ref.invalidate(currentMonthStatsProvider);
        ref.invalidate(forecastProvider);
      },
      child: ListView(
        padding: EdgeInsets.all(AppSpacing.listHorizontalPadding),
        children: [
          // ═══════════════════════════════════════════════════════════
          // SECTION 1: Health Score (always visible)
          // ═══════════════════════════════════════════════════════════
          healthScore.when(
            data: (score) => GestureDetector(
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const FinancialHealthScreen())),
              child: _HealthScoreCard(score: score),
            ),
            loading: () => const _ShimmerCard(height: 180),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ═══════════════════════════════════════════════════════════
          // SECTION 2: Risk (Runway + Anomalies merged)
          // ═══════════════════════════════════════════════════════════
          _RiskSection(
            runwayAsync: runwayAsync,
            anomaliesAsync: anomaliesAsync,
            streakAsync: streakAsync,
            xpAsync: xpAsync,
          ),

          // ═══════════════════════════════════════════════════════════
          // SECTION 3: Net Worth
          // ═══════════════════════════════════════════════════════════
          nwChange.when(
            data: (data) => _NetWorthBanner(
              current: data.current,
              change: data.change,
              changePct: data.changePct,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const NetWorthScreen())),
            ),
            loading: () => const _ShimmerCard(height: 100),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ═══════════════════════════════════════════════════════════
          // SECTION 4: Credit + EMI (compact)
          // ═══════════════════════════════════════════════════════════
          creditHealth.when(
            data: (health) {
              if (health.totalOutstanding <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _CreditCompactCard(
                  health: health,
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const CreditCardScreen())),
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          // ═══════════════════════════════════════════════════════════
          // SECTION 5: Monthly Summary
          // ═══════════════════════════════════════════════════════════
          monthStats.when(
            data: (stats) {
              if (stats == null) return const SizedBox.shrink();
              return _MonthlySummaryCard(
                stats: stats,
                previous: prevStats.valueOrNull,
              );
            },
            loading: () => const _ShimmerCard(height: 100),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ═══════════════════════════════════════════════════════════
          // SECTION 6: Trends + Forecast
          // ═══════════════════════════════════════════════════════════
          forecastAsync.when(
            data: (f) => f.predictedExpense > 0
                ? _ForecastCard(forecast: f)
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// WIDGET: Risk Section (Runway + Anomalies + Streak + XP merged)
// ══════════════════════════════════════════════════════════════════════════

class _RiskSection extends StatelessWidget {
  final AsyncValue<Runway> runwayAsync;
  final AsyncValue<List<Anomaly>> anomaliesAsync;
  final AsyncValue<Streak> streakAsync;
  final AsyncValue<UserXP> xpAsync;

  const _RiskSection({
    required this.runwayAsync,
    required this.anomaliesAsync,
    required this.streakAsync,
    required this.xpAsync,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final runway = runwayAsync.valueOrNull;
    final anomalies = anomaliesAsync.valueOrNull ?? [];
    final streak = streakAsync.valueOrNull;
    final xp = xpAsync.valueOrNull;

    final hasRunwayRisk = runway != null && runway.status != RunwayStatus.safe;
    final hasAnomalies = anomalies.isNotEmpty;
    final hasStreak = streak != null && streak.current > 0;
    final hasXP = xp != null && xp.xp > 0;

    if (!hasRunwayRisk && !hasAnomalies && !hasStreak && !hasXP) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Runway alert
              if (hasRunwayRisk) ...[
                Row(
                  children: [
                    Icon(
                      runway.status == RunwayStatus.critical
                          ? Icons.error_rounded
                          : Icons.warning_amber_rounded,
                      size: 18,
                      color: runway.status == RunwayStatus.critical
                          ? cs.error
                          : const Color(0xFFF59E0B),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${runway.daysLeft} days runway at ${AppFormat.currency(runway.dailyBurn)}/day',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (hasAnomalies || hasStreak) const SizedBox(height: 8),
              ],

              // Anomalies (compact — max 2)
              if (hasAnomalies)
                for (final a in anomalies.take(2))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 6, height: 6,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: a.severity == AnomalySeverity.high
                                ? cs.error
                                : const Color(0xFFF59E0B),
                          ),
                        ),
                        Expanded(
                          child: Text(a.title,
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ),

              // Streak + XP (inline)
              if (hasStreak || hasXP) ...[
                if (hasRunwayRisk || hasAnomalies) const Divider(height: 16),
                Row(
                  children: [
                    if (hasStreak) ...[
                      Icon(Icons.local_fire_department_rounded,
                          size: 16,
                          color: streak.current >= 7
                              ? const Color(0xFF8B5CF6)
                              : const Color(0xFFF59E0B)),
                      const SizedBox(width: 4),
                      Text('${streak.current}d streak',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600)),
                    ],
                    if (hasStreak && hasXP) const SizedBox(width: 16),
                    if (hasXP) ...[
                      Text('Lv${xp.level}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700)),
                      const SizedBox(width: 4),
                      Text(xp.levelName,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant)),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// WIDGET: Health Score Card
// ══════════════════════════════════════════════════════════════════════════

class _HealthScoreCard extends StatelessWidget {
  final FinancialHealthScore score;

  const _HealthScoreCard({required this.score});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color scoreColor;
    if (score.score >= 80) {
      scoreColor = const Color(0xFF22C55E);
    } else if (score.score >= 60) {
      scoreColor = const Color(0xFF0EA5E9);
    } else if (score.score >= 40) {
      scoreColor = const Color(0xFFF59E0B);
    } else {
      scoreColor = cs.error;
    }

    return Card(
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Row(
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: CustomPaint(
                painter: _ScoreRingPainter(
                  score: score.score,
                  color: scoreColor,
                  bgColor: cs.surfaceContainerHighest,
                ),
                child: Center(
                  child: Text(
                    '${score.score}',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: scoreColor,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Financial Health',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Icon(Icons.arrow_forward_ios_rounded,
                          size: 14, color: cs.onSurfaceVariant),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scoreColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      score.level,
                      style: TextStyle(
                        color: scoreColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Top insight
                  if (score.insights.isNotEmpty)
                    Text(
                      score.insights.first.text,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreRingPainter extends CustomPainter {
  final int score;
  final Color color;
  final Color bgColor;

  _ScoreRingPainter({required this.score, required this.color, required this.bgColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;
    const strokeWidth = 7.0;

    canvas.drawCircle(center, radius,
        Paint()..color = bgColor..style = PaintingStyle.stroke..strokeWidth = strokeWidth);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      (score / 100) * 2 * math.pi,
      false,
      Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = strokeWidth..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ScoreRingPainter old) =>
      old.score != score || old.color != color;
}

// ══════════════════════════════════════════════════════════════════════════
// WIDGET: Net Worth Banner
// ══════════════════════════════════════════════════════════════════════════

class _NetWorthBanner extends StatelessWidget {
  final double current;
  final double change;
  final double changePct;
  final VoidCallback? onTap;

  const _NetWorthBanner({required this.current, required this.change,
      required this.changePct, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPositive = change >= 0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary, cs.primary.withValues(alpha: 0.7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Net Worth',
                      style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.8), fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(AppFormat.currency(current),
                      style: TextStyle(color: cs.onPrimary, fontSize: 24, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            if (change != 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (isPositive ? const Color(0xFF22C55E) : cs.error).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${isPositive ? '+' : ''}${changePct.toStringAsFixed(1)}%',
                  style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: cs.onPrimary.withValues(alpha: 0.6), size: 20),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// WIDGET: Credit Compact Card
// ══════════════════════════════════════════════════════════════════════════

class _CreditCompactCard extends StatelessWidget {
  final CreditHealthSummary health;
  final VoidCallback? onTap;

  const _CreditCompactCard({required this.health, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.credit_card_rounded, color: cs.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Outstanding: ${AppFormat.currency(health.totalOutstanding)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text('${health.utilizationPct.round()}%',
                  style: TextStyle(
                    color: health.utilizationPct > 70 ? cs.error : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  )),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// WIDGET: Monthly Summary
// ══════════════════════════════════════════════════════════════════════════

class _MonthlySummaryCard extends StatelessWidget {
  final MonthlyStats stats;
  final MonthlyStats? previous;

  const _MonthlySummaryCard({required this.stats, this.previous});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rate = (stats.savingsRate * 100).round();

    return Card(
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This Month',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Row(
              children: [
                _Metric(label: 'Income', value: AppFormat.currency(stats.income), color: const Color(0xFF22C55E)),
                _Metric(label: 'Expenses', value: AppFormat.currency(stats.expense), color: cs.error),
                _Metric(label: 'Saved', value: '$rate%', color: cs.primary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _Metric({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15)),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// WIDGET: Forecast Card
// ══════════════════════════════════════════════════════════════════════════

class _ForecastCard extends StatelessWidget {
  final Forecast forecast;

  const _ForecastCard({required this.forecast});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_graph_rounded, color: cs.primary, size: 18),
                const SizedBox(width: 8),
                Text('Next Month',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(forecast.confidenceLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Metric(label: 'Income', value: AppFormat.currency(forecast.predictedIncome),
                    color: const Color(0xFF22C55E)),
                _Metric(label: 'Expense', value: AppFormat.currency(forecast.predictedExpense),
                    color: cs.error),
                _Metric(label: 'Savings', value: AppFormat.currency(forecast.predictedSavings.abs()),
                    color: forecast.predictedSavings >= 0 ? const Color(0xFF22C55E) : cs.error),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// WIDGET: Shimmer Placeholder
// ══════════════════════════════════════════════════════════════════════════

class _ShimmerCard extends StatelessWidget {
  final double height;
  const _ShimmerCard({required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}
