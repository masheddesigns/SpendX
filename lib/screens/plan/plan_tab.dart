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
import '../../models/goal.dart';
import '../../services/adaptive_personality.dart';
import '../../services/financial_identity_service.dart';
import '../../services/money_score_service.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/spendx_glass.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../goals/add_goal_screen.dart';
import '../goals/goals_screen.dart';
import '../review/review_queue_screen.dart';

/// SpendX 2.0 Forward-Looking Financial Workspace (Planning Screen).
///
/// Implements Section 6 of C15-B:
/// - Distinguishes CURRENT STATE from PLANNED / FUTURE STATE
/// - Planning Overview & Identity Hero (Material 2 — Elevated Glass)
/// - Next Month Outlook Forecast (Material 1 — Base Glass)
/// - Smart Recommendations & Nudges
/// - Active Goals Progress grouped Liquid Glass container
/// - Budget Pulse grouped Liquid Glass container
/// - Strictly consumes canonical providers without duplicating financial values
class PlanTab extends ConsumerWidget {
  final bool embedded;

  const PlanTab({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineAsync = ref.watch(financialTimelineProvider);
    final goalsAsync = ref.watch(activeGoalsProvider);
    final budgetsAsync = ref.watch(smartBudgetProvider);
    final forecastAsync = ref.watch(forecastProvider);
    final saveSugAsync = ref.watch(saveSuggestionProvider);
    final nudgesAsync = ref.watch(smartNudgesProvider);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget content = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(financialTimelineProvider);
        ref.invalidate(activeGoalsProvider);
        ref.invalidate(smartBudgetProvider);
        ref.invalidate(forecastProvider);
        ref.invalidate(smartNudgesProvider);
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Today's Focus / Daily Digest (Elevated Glass) ───
          timelineAsync.when(
            data: (timeline) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: DailyDigestCard(
                  topInsight: timeline.topInsight,
                  onActionTap: () => Navigator.push(
                    context,
                    AppPageRoute(builder: (_) => const ReviewQueueScreen()),
                  ),
                ),
              ),
            ),
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: SpendXLoadingState(count: 1, itemHeight: 100),
              ),
            ),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // ── Identity & Financial Health Hero ────────────────
          timelineAsync.when(
            data: (timeline) => SliverToBoxAdapter(
              child: _IdentityHero(
                identity: timeline.identity,
                score: timeline.moneyScore,
                isDark: isDark,
              ),
            ),
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          // ── Next Month Outlook Forecast ─────────────────────
          forecastAsync.when(
            data: (f) => f.predictedExpense > 0
                ? SliverToBoxAdapter(
                    child: _ForecastGlassCard(forecast: f, isDark: isDark),
                  )
                : const SliverToBoxAdapter(child: SizedBox.shrink()),
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // ── Smart Nudges & What-to-Do ────────────────────────
          nudgesAsync.when(
            data: (nudges) {
              final saveSug = saveSugAsync.valueOrNull;
              if (nudges.isEmpty && saveSug == null) {
                return const SliverToBoxAdapter(child: SizedBox.shrink());
              }
              return SliverToBoxAdapter(
                child: _RecommendationsGlassCard(
                  nudges: nudges,
                  saveSuggestion: saveSug,
                  isDark: isDark,
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // ── Active Goals Section ─────────────────────────────
          goalsAsync.when(
            data: (goals) {
              if (goals.isEmpty) {
                return SliverToBoxAdapter(
                  child: _EmptyGoalsGlassCard(context: context, isDark: isDark),
                );
              }
              return SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SpendXSectionHeader(
                      title: 'Active Goals',
                      count: goals.length,
                      actionLabel: 'View All',
                      onAction: () => Navigator.push(
                        context,
                        AppPageRoute(builder: (_) => const GoalsScreen()),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: SpendXGlassSurface(
                        level: SpendXGlassLevel.base,
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: List.generate(
                            goals.take(4).length,
                            (index) {
                              final goal = goals[index];
                              final isLast = index == goals.take(4).length - 1;
                              final progress = ref.watch(goalProgressProvider(goal));
                              return _GoalRowItem(
                                goal: goal,
                                progress: progress.progressPct,
                                showDivider: !isLast,
                                isDark: isDark,
                                onTap: () => Navigator.push(
                                  context,
                                  AppPageRoute(builder: (_) => const GoalsScreen()),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SpendXLoadingState(count: 2, itemHeight: 60),
              ),
            ),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // ── Budget Pulse Section ─────────────────────────────
          budgetsAsync.when(
            data: (budgets) {
              if (budgets.isEmpty) {
                return const SliverToBoxAdapter(child: SizedBox.shrink());
              }
              final over = budgets.where((b) => b.isOverBudget).toList();
              if (over.isEmpty) {
                return SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: _BudgetAllClearBanner(isDark: isDark),
                  ),
                );
              }
              return SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SpendXSectionHeader(
                      title: 'Budget Pulse',
                      count: budgets.length,
                      actionLabel: '${over.length} Over',
                      onAction: () {},
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: SpendXGlassSurface(
                        level: SpendXGlassLevel.base,
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: List.generate(
                            over.take(4).length,
                            (index) {
                              final b = over[index];
                              final isLast = index == over.take(4).length - 1;
                              return _BudgetRowItem(
                                budget: b,
                                showDivider: !isLast,
                                isDark: isDark,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // Generous bottom clearance above floating navigation bar
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );

    if (!embedded) {
      return SpendXScaffold(
        extendBody: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            'Planning',
            style: AppTextStyles.heading.copyWith(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.add_rounded),
              onPressed: () => Navigator.push(
                context,
                AppPageRoute(builder: (_) => const AddGoalScreen()),
              ),
            ),
          ],
        ),
        body: content,
      );
    }

    return content;
  }
}

// ── Identity & Score Hero ────────────────────────────────────────

class _IdentityHero extends StatelessWidget {
  final FinancialIdentity identity;
  final MoneyScore score;
  final bool isDark;

  const _IdentityHero({
    required this.identity,
    required this.score,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final delta = score.deltaToday;
    final deltaStr = delta >= 0 ? '+$delta' : '$delta';
    final p = AdaptivePersonality(identity.type);

    return SpendXGlassCard(
      level: SpendXGlassLevel.elevated,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      identity.emoji,
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      identity.label,
                      style: TextStyle(
                        color: identity.color,
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  identity.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${score.value}',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: -0.5,
                ),
              ),
              if (delta != 0)
                Text(
                  'today $deltaStr',
                  style: TextStyle(
                    color: delta > 0 ? AppTheme.semanticIncome : AppTheme.semanticExpense,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (score.weeklyDelta != null && score.weeklyDelta != 0)
                Text(
                  score.isImproving
                      ? p.scoreMomentumUp(score.weeklyDelta!)
                      : p.scoreMomentumDown(score.weeklyDelta!),
                  style: TextStyle(
                    color: score.isImproving ? AppTheme.semanticIncome : AppTheme.semanticExpense,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Forecast Glass Card ─────────────────────────────────────────

class _ForecastGlassCard extends StatelessWidget {
  final Forecast forecast;
  final bool isDark;

  const _ForecastGlassCard({
    required this.forecast,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return SpendXGlassCard(
      level: SpendXGlassLevel.base,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_graph_rounded,
                color: AppTheme.primaryBlue,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Next Month Outlook',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _ForecastMetricItem(
                label: 'Income',
                value: AppFormat.currency(forecast.predictedIncome),
                color: AppTheme.semanticIncome,
                isDark: isDark,
              ),
              _ForecastMetricItem(
                label: 'Expense',
                value: AppFormat.currency(forecast.predictedExpense),
                color: AppTheme.semanticExpense,
                isDark: isDark,
              ),
              _ForecastMetricItem(
                label: 'Savings',
                value: AppFormat.currency(forecast.predictedSavings.abs()),
                color: forecast.predictedSavings >= 0
                    ? AppTheme.semanticIncome
                    : AppTheme.semanticExpense,
                isDark: isDark,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ForecastMetricItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool isDark;

  const _ForecastMetricItem({
    required this.label,
    required this.value,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Recommendations Glass Card ──────────────────────────────────

class _RecommendationsGlassCard extends StatelessWidget {
  final List<SmartNudge> nudges;
  final SaveSuggestion? saveSuggestion;
  final bool isDark;

  const _RecommendationsGlassCard({
    required this.nudges,
    required this.saveSuggestion,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return SpendXGlassCard(
      level: SpendXGlassLevel.base,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_fix_high_rounded,
                color: AppTheme.primaryBlue,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Recommended Actions',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (saveSuggestion != null)
            _NudgeGlassRow(
              icon: Icons.savings_rounded,
              color: AppTheme.semanticIncome,
              text: 'Save ${AppFormat.currency(saveSuggestion!.amount)} this month',
              isDark: isDark,
            ),
          for (final n in nudges.take(2))
            _NudgeGlassRow(
              icon: n.type == NudgeType.warning
                  ? Icons.warning_amber_rounded
                  : Icons.lightbulb_outline_rounded,
              color: n.priority == NudgePriority.critical
                  ? AppTheme.semanticExpense
                  : AppTheme.semanticWarning,
              text: n.title,
              isDark: isDark,
            ),
        ],
      ),
    );
  }
}

class _NudgeGlassRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final bool isDark;

  const _NudgeGlassRow({
    required this.icon,
    required this.color,
    required this.text,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Goal Row Item ───────────────────────────────────────────────

class _GoalRowItem extends StatelessWidget {
  final Goal goal;
  final double progress;
  final bool showDivider;
  final bool isDark;
  final VoidCallback onTap;

  const _GoalRowItem({
    required this.goal,
    required this.progress,
    required this.showDivider,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).clamp(0, 100).toInt();

    return InkWell(
      onTap: onTap,
      splashColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        goal.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    Text(
                      '$pct%',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryBlue,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Progress Bar Pill
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                    valueColor: const AlwaysStoppedAnimation(AppTheme.primaryBlue),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Target: ${AppFormat.currency(goal.targetAmount)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      'Saved: ${AppFormat.currency(goal.targetAmount * progress.clamp(0.0, 1.0))}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : const Color(0xFF334155),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (showDivider)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              height: 0.5,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
            ),
        ],
      ),
    );
  }
}

// ── Budget Row Item ─────────────────────────────────────────────

class _BudgetRowItem extends StatelessWidget {
  final SmartBudget budget;
  final bool showDivider;
  final bool isDark;

  const _BudgetRowItem({
    required this.budget,
    required this.showDivider,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.semanticExpense.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: AppTheme.semanticExpense,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      budget.categoryName,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                      ),
                    ),
                    Text(
                      'Spent ${AppFormat.currency(budget.spent)} of ${AppFormat.currency(budget.limit)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                'Over by ${AppFormat.currency(budget.spent - budget.limit)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.semanticExpense,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        if (showDivider)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            height: 0.5,
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
          ),
      ],
    );
  }
}

// ── Budget All Clear Banner ─────────────────────────────────────

class _BudgetAllClearBanner extends StatelessWidget {
  final bool isDark;

  const _BudgetAllClearBanner({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return SpendXGlassSurface(
      level: SpendXGlassLevel.base,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      color: AppTheme.semanticIncome.withValues(alpha: isDark ? 0.12 : 0.08),
      border: Border.all(
        color: AppTheme.semanticIncome.withValues(alpha: isDark ? 0.30 : 0.20),
        width: 0.5,
      ),
      child: const Row(
        children: [
          Icon(Icons.check_circle_rounded, color: AppTheme.semanticIncome, size: 18),
          SizedBox(width: 10),
          Text(
            'All budgets on track for this period',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.semanticIncome,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty Goals Glass Card ──────────────────────────────────────

class _EmptyGoalsGlassCard extends StatelessWidget {
  final BuildContext context;
  final bool isDark;

  const _EmptyGoalsGlassCard({
    required this.context,
    required this.isDark,
  });

  @override
  Widget build(BuildContext outerContext) {
    return SpendXGlassCard(
      level: SpendXGlassLevel.base,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.flag_rounded,
              size: 32,
              color: AppTheme.primaryBlue.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 8),
            Text(
              'No active goals',
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Establish savings targets and earmarks for major milestones.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 14),
            SpendXGlassButton(
              height: 38,
              variant: SpendXGlassButtonVariant.tonal,
              onPressed: () => Navigator.push(
                context,
                AppPageRoute(builder: (_) => const AddGoalScreen()),
              ),
              child: const Text('Create Goal'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Standalone wrapper for pushing the Planning surface onto navigation routes.
class PlansScreen extends StatelessWidget {
  const PlansScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlanTab();
  }
}
