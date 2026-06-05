import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/automation/automation_engine.dart';
import '../../features/automation/automation_providers.dart';
import '../../features/budget/budget_providers.dart';
import '../../features/budget/smart_budget_engine.dart';
import '../../features/forecast/forecast_provider.dart';
import '../../features/goals/goal_providers.dart';
import '../../features/timeline/daily_digest_card.dart';
import '../../features/timeline/financial_timeline_provider.dart';
import '../review/review_queue_screen.dart';
import '../../services/adaptive_personality.dart';
import '../../services/financial_identity_service.dart';
import '../../services/money_score_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../goals/goals_screen.dart';
import '../goals/add_goal_screen.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/skeleton_loader.dart';

/// The Plan tab — focused financial compass.
///
/// Narrative: Who am I → What's coming → What should I do → Am I on track?
///
/// Layout:
///   Identity Banner (who am I + score)
///   ↓
///   Today's Focus (decision card)
///   ↓
///   This Month Forecast (income/expense/savings)
///   ↓
///   Recommendations (smart nudges)
///   ↓
///   Goals Progress (top 3)
///   ↓
///   Budget Pulse (compact: over-budget or "all on track")
class PlanTab extends ConsumerWidget {
  const PlanTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineAsync = ref.watch(financialTimelineProvider);
    final goalsAsync = ref.watch(activeGoalsProvider);
    final budgetsAsync = ref.watch(smartBudgetProvider);
    final forecastAsync = ref.watch(forecastProvider);
    final saveSugAsync = ref.watch(saveSuggestionProvider);
    final nudgesAsync = ref.watch(smartNudgesProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(financialTimelineProvider);
        ref.invalidate(activeGoalsProvider);
        ref.invalidate(smartBudgetProvider);
        ref.invalidate(forecastProvider);
        ref.invalidate(smartNudgesProvider);
      },
      child: ListView(
        padding: AppSpacing.cardPadding,
        children: [
          // ── Identity Banner ──────────────────────────────────
          // ── Daily Digest (one decision OR completion state) ─
          timelineAsync.when(
            data: (timeline) => DailyDigestCard(
              topInsight: timeline.topInsight,
              onActionTap: () => Navigator.push(
                context,
                AppPageRoute(
                    builder: (_) => const ReviewQueueScreen()),
              ),
            ),
            loading: () => const SkeletonLoader.summary(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),

          // ── Identity Banner ──────────────────────────────────
          timelineAsync.when(
            data: (timeline) => _IdentityBanner(
              identity: timeline.identity,
              score: timeline.moneyScore,
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),

          // ── This Month Forecast ───────────────────────────────
          forecastAsync.when(
            data: (f) => f.predictedExpense > 0
                ? _PlanForecastCard(forecast: f)
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),

          // ── Recommendations ───────────────────────────────────
          nudgesAsync.when(
            data: (nudges) {
              final saveSug = saveSugAsync.valueOrNull;
              if (nudges.isEmpty && saveSug == null) {
                return const SizedBox.shrink();
              }
              return _RecommendationsCard(
                  nudges: nudges, saveSuggestion: saveSug);
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),

          // ── Active Goals ──────────────────────────────────────
          goalsAsync.when(
            data: (goals) {
              if (goals.isEmpty) return _EmptyGoalsCard(context: context);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(
                      title: 'Active Goals', count: goals.length),
                  const SizedBox(height: 8),
                  for (final goal in goals.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GoalCard(
                        goal: goal,
                        progress: ref.watch(goalProgressProvider(goal)),
                        onTap: () => Navigator.push(
                            context,
                            AppPageRoute(
                                builder: (_) => const GoalsScreen())),
                      ),
                    ),
                ],
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),

          // ── Budget Pulse ──────────────────────────────────────
          budgetsAsync.when(
            data: (budgets) {
              if (budgets.isEmpty) return const SizedBox.shrink();
              final over =
                  budgets.where((b) => b.isOverBudget).toList();
              if (over.isEmpty) {
                return _BudgetAllClear();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(
                    title: 'Budget Pulse',
                    count: budgets.length,
                    alert: '${over.length} over',
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          for (final b in over.take(5))
                            _BudgetRow(budget: b),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── Identity Banner ─────────────────────────────────────────────────────

class _IdentityBanner extends StatelessWidget {
  final FinancialIdentity identity;
  final MoneyScore score;

  const _IdentityBanner({required this.identity, required this.score});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final delta = score.deltaToday;
    final deltaStr = delta >= 0 ? '+$delta' : '$delta';
    final p = AdaptivePersonality(identity.type);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: identity.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: identity.color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${identity.emoji} ${identity.label}',
                  style: TextStyle(
                    color: identity.color,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  identity.description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
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
                Text(
                  score.isImproving
                      ? p.scoreMomentumUp(score.weeklyDelta!)
                      : p.scoreMomentumDown(score.weeklyDelta!),
                  style: TextStyle(
                      color: score.isImproving ? Colors.green : cs.error,
                      fontSize: 10),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Forecast Card ───────────────────────────────────────────────────────

class _PlanForecastCard extends StatelessWidget {
  final Forecast forecast;

  const _PlanForecastCard({required this.forecast});

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
                Icon(Icons.auto_graph_rounded, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('Next Month Outlook',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _FMini(
                    label: 'Income',
                    value: AppFormat.currency(forecast.predictedIncome),
                    color: const Color(0xFF22C55E)),
                _FMini(
                    label: 'Expense',
                    value: AppFormat.currency(forecast.predictedExpense),
                    color: cs.error),
                _FMini(
                    label: 'Savings',
                    value:
                        AppFormat.currency(forecast.predictedSavings.abs()),
                    color: forecast.predictedSavings >= 0
                        ? const Color(0xFF22C55E)
                        : cs.error),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FMini extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _FMini(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 14)),
        ],
      ),
    );
  }
}

// ── Recommendations ─────────────────────────────────────────────────────

class _RecommendationsCard extends StatelessWidget {
  final List<SmartNudge> nudges;
  final SaveSuggestion? saveSuggestion;

  const _RecommendationsCard({required this.nudges, this.saveSuggestion});

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
                Icon(Icons.auto_fix_high_rounded,
                    color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('What to do',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            if (saveSuggestion != null)
              _NudgeRow(
                icon: Icons.savings_rounded,
                color: const Color(0xFF22C55E),
                text:
                    'Save ${AppFormat.currency(saveSuggestion!.amount)} this month',
              ),
            for (final n in nudges.take(2))
              _NudgeRow(
                icon: n.type == NudgeType.warning
                    ? Icons.warning_amber_rounded
                    : Icons.lightbulb_outline_rounded,
                color: n.priority == NudgePriority.critical
                    ? cs.error
                    : const Color(0xFFF59E0B),
                text: n.title,
              ),
          ],
        ),
      ),
    );
  }
}

class _NudgeRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _NudgeRow(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

// ── Empty Goals ─────────────────────────────────────────────────────────

class _EmptyGoalsCard extends StatelessWidget {
  final BuildContext context;

  const _EmptyGoalsCard({required this.context});

  @override
  Widget build(BuildContext outerContext) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.flag_rounded,
                size: 36,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.4)),
            const SizedBox(height: 8),
            Text('No active goals',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('Set a savings target to get started',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => Navigator.push(context,
                  AppPageRoute(builder: (_) => const AddGoalScreen())),
              child: const Text('Create Goal'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Budget All Clear ────────────────────────────────────────────────────

class _BudgetAllClear extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF22C55E).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF22C55E).withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded,
              color: Color(0xFF22C55E), size: 20),
          const SizedBox(width: 10),
          Text('All budgets on track',
              style: TextStyle(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w500,
                  fontSize: 13)),
        ],
      ),
    );
  }
}

// ── Section Header ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final String? alert;

  const _SectionHeader(
      {required this.title, required this.count, this.alert});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(width: 6),
        Text('($count)',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant)),
        if (alert != null) ...[
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cs.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(alert!,
                style: TextStyle(
                    color: cs.error,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ],
    );
  }
}

// ── Budget Row ──────────────────────────────────────────────────────────

class _BudgetRow extends StatelessWidget {
  final SmartBudget budget;

  const _BudgetRow({required this.budget});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final barColor = budget.isOverBudget
        ? cs.error
        : budget.usagePct > 0.8
            ? const Color(0xFFF59E0B)
            : const Color(0xFF22C55E);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(budget.categoryName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500)),
              Text(
                '${AppFormat.currency(budget.spent)} / ${AppFormat.currency(budget.limit)}',
                style: TextStyle(
                  fontSize: 11,
                  color:
                      budget.isOverBudget ? cs.error : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: budget.usagePct.clamp(0, 1),
              minHeight: 5,
              backgroundColor: cs.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ],
      ),
    );
  }
}
