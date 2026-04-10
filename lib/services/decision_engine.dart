import 'data_audit_service.dart';
import 'forecast_engine.dart';
import 'goal_nudge_engine.dart';
import '../utils/app_format.dart';

/// Priority levels for the decision engine.
/// Risk > Goal > Optimization > Info
enum InsightPriority { critical, high, medium, low }

/// A prioritized, explainable insight.
class DecisionInsight {
  final String title;
  final String body;
  final InsightPriority priority;
  final List<String> reasons;
  final String? actionLabel;

  const DecisionInsight({
    required this.title,
    required this.body,
    required this.priority,
    this.reasons = const [],
    this.actionLabel,
  });
}

/// Single-point decision engine.
///
/// Takes all system signals and returns ONE primary insight
/// plus ordered secondary insights.
///
/// Priority: Risk > Goal delay > Data issues > Optimization > Info
class DecisionEngine {
  DecisionEngine._();
  static final instance = DecisionEngine._();

  /// Compute the prioritized insight stack.
  Future<List<DecisionInsight>> compute() async {
    final insights = <DecisionInsight>[];

    // ── 1. Forecast risk (highest priority) ─────────────────
    try {
      final forecast = await ForecastEngine.instance.compute();

      if (forecast.isOverspendRisk) {
        final driftingCats = forecast.categoryForecasts.values
            .where((c) => c.isTrendingUp)
            .toList()
          ..sort((a, b) => b.driftPercent.compareTo(a.driftPercent));

        insights.add(DecisionInsight(
          title: 'You\'re drifting above your usual spending',
          body: 'At this pace, about ${AppFormat.currency(forecast.overspendAmount)} more than last month.',
          priority: InsightPriority.critical,
          reasons: [
            'Daily spend: ${AppFormat.currency(forecast.dailyBurnRate)}/day',
            'Projected expense: ${AppFormat.currency(forecast.projectedExpense)}',
            if (driftingCats.isNotEmpty)
              '${driftingCats.first.categoryName} up ${driftingCats.first.driftPercent.toStringAsFixed(0)}% vs last month',
          ],
          actionLabel: 'View forecast',
        ));
      } else if (forecast.projectedSavings > 0) {
        insights.add(DecisionInsight(
          title: 'Everything looks on track',
          body: 'You\'re heading towards ${AppFormat.currency(forecast.projectedSavings)} in savings this month.',
          priority: InsightPriority.low,
          reasons: [
            'Daily spend: ${AppFormat.currency(forecast.dailyBurnRate)}/day',
            '${forecast.daysInMonth - forecast.daysElapsed} days remaining',
          ],
        ));
      }
    } catch (_) {}

    // ── 2. Goal delays (high priority) ──────────────────────
    try {
      final nudges = await GoalNudgeEngine.instance.generate();
      final delays = nudges.where((n) => n.type == NudgeType.delayWarning);
      for (final delay in delays) {
        insights.add(DecisionInsight(
          title: delay.title,
          body: delay.body,
          priority: InsightPriority.high,
          actionLabel: 'View goal',
        ));
      }

      // Milestones (positive — low priority)
      final milestones = nudges.where((n) => n.type == NudgeType.milestone);
      for (final m in milestones) {
        insights.add(DecisionInsight(
          title: m.title,
          body: m.body,
          priority: InsightPriority.low,
        ));
      }
    } catch (_) {}

    // ── 3. Data health issues (medium priority) ──────────────
    try {
      final issues = await DataAuditService.instance.runAudit();
      final serious = issues.where((i) => i.severity != AuditSeverity.low);
      if (serious.isNotEmpty) {
        final total = serious.fold<int>(0, (s, i) => s + i.count);
        insights.add(DecisionInsight(
          title: '$total data issue${total == 1 ? '' : 's'} need attention',
          body: serious.map((i) => i.title).join(', '),
          priority: InsightPriority.medium,
          reasons: serious.map((i) => i.impact ?? i.description).toList(),
          actionLabel: 'Fix now',
        ));
      }
    } catch (_) {}

    // Sort by priority
    insights.sort((a, b) => a.priority.index.compareTo(b.priority.index));

    return insights;
  }

  /// Get the single most important insight.
  Future<DecisionInsight?> getTopInsight() async {
    final all = await compute();
    return all.isNotEmpty ? all.first : null;
  }
}
