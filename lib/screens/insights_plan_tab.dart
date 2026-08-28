import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/health/health_score_provider.dart';
import '../../features/cashflow/runway_provider.dart';
import '../../features/anomaly/anomaly_provider.dart';
import '../../features/liabilities/providers/credit_health_providers.dart';
import '../../features/dashboard/insights_providers.dart';
import '../../features/timeline/financial_timeline_provider.dart';
import '../../features/goals/goal_providers.dart';
import '../../features/budget/budget_providers.dart';
import '../../features/forecast/forecast_provider.dart';
import '../../features/automation/automation_providers.dart';
import 'plan/plan_tab.dart';
import 'insights/insights_tab.dart';

/// Combined "Insights" tab — what's happening + what to do.
/// Wraps the former Insights and Plan tabs into a single scroll surface.
class InsightsPlanTab extends ConsumerWidget {
  const InsightsPlanTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(financialTimelineProvider);
        ref.invalidate(activeGoalsProvider);
        ref.invalidate(smartBudgetProvider);
        ref.invalidate(forecastProvider);
        ref.invalidate(smartNudgesProvider);
        ref.invalidate(financialHealthScoreProvider);
        ref.invalidate(runwayProvider);
        ref.invalidate(anomalyProvider);
        ref.invalidate(netWorthChangeProvider);
        ref.invalidate(creditHealthProvider);
        ref.invalidate(currentMonthStatsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: PlanTab(embedded: true),
          ),
          _SectionDivider(label: 'Insights'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: InsightsTab(embedded: true),
          ),
        ],
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  final String label;
  const _SectionDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}
