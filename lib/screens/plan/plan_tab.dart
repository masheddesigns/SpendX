import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/automation/automation_engine.dart';
import '../../features/automation/automation_providers.dart';
import '../../features/budget/budget_providers.dart';
import '../../features/budget/smart_budget_engine.dart';
import '../../features/forecast/forecast_provider.dart';
import '../../features/goals/goal_progress.dart';
import '../../features/goals/goal_providers.dart';
import '../../features/review_queue/providers/review_providers.dart';
import '../../features/salary/screens/salary_screen.dart';
import '../../features/timeline/financial_timeline_provider.dart';
import '../../models/goal.dart';
import '../../services/financial_identity_service.dart';
import '../../services/money_score_service.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/spendx_glass.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../goals/add_goal_screen.dart';
import '../goals/goal_detail_screen.dart';
import '../goals/goals_screen.dart';
import '../home/transactions_screen.dart';
import '../recurring/recurring_payments_screen.dart';
import '../review/review_queue_screen.dart';
import '../settings/budget_management_screen.dart';

/// SpendX Mindful Financial Horizon (Planning Screen).
///
/// Implements SpendX Visual Language Rulebook:
/// - Replaces the 8-card stack with unified, living financial horizons
/// - Unified Financial Health & Identity Horizon (zero system emojis)
/// - Organic milestone runway journeys for budgets and goals
/// - Calm, dignified indicators without aggressive red alert styling
/// - Cardless empty states with conversational encouragement
/// - Unified Foundations & Commitments container
/// - Preserves 100% canonical double-entry accounting invariants & providers
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
        ref.invalidate(saveSuggestionProvider);
      },
      color: AppTheme.primaryBlue,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Subtitle / Horizon Orientation ────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF4F46E5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Your financial outlook',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Section 1: Unified Financial Horizon Card ──────
          timelineAsync.when(
            data: (timeline) {
              final forecast = forecastAsync.valueOrNull;
              final nudges = nudgesAsync.valueOrNull ?? const [];
              final saveSug = saveSugAsync.valueOrNull;
              return SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: _FinancialHorizonCard(
                    identity: timeline.identity,
                    score: timeline.moneyScore,
                    forecast: forecast,
                    nudges: nudges,
                    saveSuggestion: saveSug,
                    topInsightText: timeline.topInsight?.title,
                    isDark: isDark,
                    onActionTap: () {
                      final reviewCount =
                          ref.read(reviewQueueCountProvider).valueOrNull ?? 0;
                      if (reviewCount > 0) {
                        Navigator.push(
                          context,
                          AppPageRoute(builder: (_) => const ReviewQueueScreen()),
                        );
                      } else {
                        Navigator.push(
                          context,
                          AppPageRoute(
                            builder: (_) =>
                                const TransactionListScreen(isFullScreen: true),
                          ),
                        );
                      }
                    },
                  ),
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SpendXLoadingState(count: 1, itemHeight: 140),
              ),
            ),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 14)),

          // ── Section 2: Budget Horizons (Pacing & Consumption)
          budgetsAsync.when(
            data: (budgets) {
              return SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SpendXSectionHeader(
                      title: 'Budget Horizons',
                      count: budgets.isNotEmpty ? budgets.length : null,
                      actionLabel: 'Manage',
                      onAction: () => Navigator.push(
                        context,
                        AppPageRoute(
                          builder: (_) => const BudgetManagementScreen(),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: budgets.isEmpty
                          ? _EmptyBudgetCard(context: context, isDark: isDark)
                          : _BudgetHorizonsList(budgets: budgets, isDark: isDark),
                    ),
                  ],
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SpendXLoadingState(count: 2, itemHeight: 64),
              ),
            ),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 14)),

          // ── Section 3: Savings Landmarks (Goal Waypoint Journeys)
          goalsAsync.when(
            data: (goals) {
              return SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SpendXSectionHeader(
                      title: 'Savings Landmarks',
                      count: goals.isNotEmpty ? goals.length : null,
                      actionLabel: goals.isNotEmpty ? 'View All' : null,
                      onAction: () => Navigator.push(
                        context,
                        AppPageRoute(builder: (_) => const GoalsScreen()),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: goals.isEmpty
                          ? _EmptyGoalsCard(context: context, isDark: isDark)
                          : _GoalsLandmarkList(goals: goals, isDark: isDark),
                    ),
                  ],
                ),
              );
            },
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SpendXLoadingState(count: 2, itemHeight: 64),
              ),
            ),
            error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 14)),

          // ── Section 4: Foundations & Commitments ───────────
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SpendXSectionHeader(
                  title: 'Foundations & Commitments',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
                      border: Border.all(
                        color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
                        width: 0.9,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark ? Colors.black.withValues(alpha: 0.25) : const Color(0x081C1917),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _FoundationsRowTile(
                          icon: Icons.repeat_rounded,
                          iconColor: const Color(0xFF6366F1),
                          title: 'Subscriptions & Bills',
                          subtitle: 'Manage upcoming recurring charges and bills',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => const RecurringPaymentsScreen(),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Divider(
                            height: 1,
                            thickness: 0.5,
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : const Color(0xFFF0ECE4),
                          ),
                        ),
                        _FoundationsRowTile(
                          icon: Icons.payments_rounded,
                          iconColor: const Color(0xFF10B981),
                          title: 'Salary & Paycheck Structure',
                          subtitle: 'Employer details, salary schedule, and deductions',
                          isDark: isDark,
                          onTap: () => Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => const SalaryScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Clearance tuned to floating glass navigation height + safe-area inset
          SliverToBoxAdapter(
            child: SizedBox(
              height: (MediaQuery.paddingOf(context).bottom > 0
                      ? MediaQuery.paddingOf(context).bottom + 72.0
                      : 80.0) +
                  16.0,
            ),
          ),
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
            style: AppTextStyles.heading.copyWith(
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: 'Add Goal',
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

// ─────────────────────────────────────────────────────────────────
// 1. Unified Financial Horizon Card (Zero Emojis, Atmospheric)
// ─────────────────────────────────────────────────────────────────

class _FinancialHorizonCard extends StatelessWidget {
  final FinancialIdentity identity;
  final MoneyScore score;
  final Forecast? forecast;
  final List<SmartNudge> nudges;
  final SaveSuggestion? saveSuggestion;
  final String? topInsightText;
  final bool isDark;
  final VoidCallback onActionTap;

  const _FinancialHorizonCard({
    required this.identity,
    required this.score,
    required this.forecast,
    required this.nudges,
    required this.saveSuggestion,
    required this.topInsightText,
    required this.isDark,
    required this.onActionTap,
  });

  IconData _resolveIdentityIcon(IdentityType type) {
    return switch (type) {
      IdentityType.disciplined => Icons.verified_outlined,
      IdentityType.stable => Icons.anchor_rounded,
      IdentityType.improving => Icons.trending_up_rounded,
      IdentityType.impulsive => Icons.explore_outlined,
      IdentityType.atRisk => Icons.crisis_alert_rounded,
    };
  }

  Color _resolveIdentityColor(IdentityType type) {
    return switch (type) {
      IdentityType.disciplined => const Color(0xFF16A34A),
      IdentityType.stable => const Color(0xFF0284C7),
      IdentityType.improving => const Color(0xFF4F46E5),
      IdentityType.impulsive => const Color(0xFFD97706),
      IdentityType.atRisk => const Color(0xFFE11D48),
    };
  }

  void _showHabitScoreExplanation(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E222D) : const Color(0xFFFFFFFF),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final textPrimary = isDark ? Colors.white : const Color(0xFF1C1917);
        final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C);
        final surface = isDark ? const Color(0xFF282D3C) : const Color(0xFFFAF7F2);
        final border = isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFEDE6DA);

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : const Color(0xFFE2DDD2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isDark ? const Color(0x204F46E5) : const Color(0xFFEEF2FF),
                      ),
                      child: Icon(
                        Icons.track_changes_rounded,
                        size: 20,
                        color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Habit Score (${score.value} / 100)',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: textPrimary,
                            ),
                          ),
                          Text(
                            'App activity & habits, not wealth',
                            style: TextStyle(
                              fontSize: 12,
                              color: textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Habit Score is an activity signal measuring how actively you engage with SpendX — opening the app, logging transactions, assigning categories, and resolving data issues. It starts at a baseline of 70 and changes based on user activity — it is not a credit score or financial health rating.',
                  style: TextStyle(
                    fontSize: 13,
                    color: textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border, width: 0.8),
                  ),
                  child: Column(
                    children: [
                      _HabitScoreDeltaRow(
                        delta: '+1',
                        label: 'Opening the app daily',
                        isPositive: true,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _HabitScoreDeltaRow(
                        delta: '+1',
                        label: 'Adding a transaction',
                        isPositive: true,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _HabitScoreDeltaRow(
                        delta: '+2',
                        label: 'Assigning a category to an expense',
                        isPositive: true,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _HabitScoreDeltaRow(
                        delta: '+3',
                        label: 'Resolving an audit discrepancy',
                        isPositive: true,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _HabitScoreDeltaRow(
                        delta: '-2',
                        label: 'Budget category overspend detected',
                        isPositive: false,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _HabitScoreDeltaRow(
                        delta: '-5',
                        label: 'Duplicate transaction found',
                        isPositive: false,
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final identityColor = _resolveIdentityColor(identity.type);
    final identityIcon = _resolveIdentityIcon(identity.type);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withValues(alpha: 0.25) : const Color(0x081C1917),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Identity & Score Row ───────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // SpendX Vector Identity Badge (Zero System Emojis)
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: identityColor.withValues(alpha: isDark ? 0.20 : 0.12),
                  border: Border.all(
                    color: identityColor.withValues(alpha: isDark ? 0.35 : 0.25),
                    width: 0.8,
                  ),
                ),
                child: Icon(identityIcon, size: 20, color: identityColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          identity.label.toUpperCase(),
                          style: TextStyle(
                            color: identityColor,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Cashflow Outlook',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      topInsightText ?? identity.description,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Money Score Display with Info Affordance
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showHabitScoreExplanation(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${score.value}',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : const Color(0xFF1C1917),
                        fontFeatures: const [FontFeature.tabularFigures()],
                        letterSpacing: -0.5,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Habit Score',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          Icons.info_outline_rounded,
                          size: 11,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          // ── Forecast Metrics Grid ──────────────────────────
          if (forecast != null && (forecast!.predictedExpense > 0 || forecast!.predictedIncome > 0)) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFFAF7F2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFEDE6DA),
                  width: 0.7,
                ),
              ),
              child: Row(
                children: [
                  _ForecastMetric(
                    label: 'EST. INFLOW',
                    amount: forecast!.predictedIncome,
                    color: const Color(0xFF16A34A),
                    isDark: isDark,
                  ),
                  Container(
                    width: 0.5,
                    height: 24,
                    color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2DDD2),
                  ),
                  _ForecastMetric(
                    label: 'EST. OUTFLOW',
                    amount: forecast!.predictedExpense,
                    color: const Color(0xFFE11D48),
                    isDark: isDark,
                  ),
                  Container(
                    width: 0.5,
                    height: 24,
                    color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2DDD2),
                  ),
                  _ForecastMetric(
                    label: forecast!.predictedSavings >= 0 ? 'EST. SURPLUS' : 'EST. SHORTFALL',
                    amount: forecast!.predictedSavings.abs(),
                    color: forecast!.predictedSavings >= 0
                        ? const Color(0xFF16A34A)
                        : const Color(0xFFD97706),
                    isDark: isDark,
                  ),
                ],
              ),
            ),
          ],

          // ── Mindful Guidance / Nudge Pebble ────────────────
          if (saveSuggestion != null || nudges.isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: onActionTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0x184F46E5) : const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark ? const Color(0x354F46E5) : const Color(0xFFC7D2FE),
                    width: 0.6,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 15,
                      color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        saveSuggestion != null
                            ? 'Save ${AppFormat.currency(saveSuggestion!.amount)} this month to strengthen runway'
                            : nudges.first.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark ? const Color(0xFFE0E7FF) : const Color(0xFF3730A3),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ForecastMetric extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;
  final bool isDark;

  const _ForecastMetric({
    required this.label,
    required this.amount,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            AppFormat.currency(amount),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _HabitScoreDeltaRow extends StatelessWidget {
  final String delta;
  final String label;
  final bool isPositive;
  final bool isDark;

  const _HabitScoreDeltaRow({
    required this.delta,
    required this.label,
    required this.isPositive,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final color = isPositive ? const Color(0xFF16A34A) : const Color(0xFFE11D48);
    return Row(
      children: [
        Container(
          width: 28,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isDark ? 0.20 : 0.10),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            delta,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF44403C),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// 2. Budget Horizons Section (Organic Milestone Runway)
// ─────────────────────────────────────────────────────────────────

class _BudgetHorizonsList extends StatelessWidget {
  final List<SmartBudget> budgets;
  final bool isDark;

  const _BudgetHorizonsList({
    required this.budgets,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    // Show top 4 budgets prioritized by usage
    final sorted = List<SmartBudget>.from(budgets)
      ..sort((a, b) => b.usagePct.compareTo(a.usagePct));
    final displayBudgets = sorted.take(4).toList();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withValues(alpha: 0.25) : const Color(0x081C1917),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: List.generate(displayBudgets.length, (index) {
          final b = displayBudgets[index];
          final isLast = index == displayBudgets.length - 1;
          return Column(
            children: [
              _BudgetHorizonRow(budget: b, isDark: isDark),
              if (!isLast)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(
                    height: 1,
                    thickness: 0.5,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFFF0ECE4),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _BudgetHorizonRow extends StatelessWidget {
  final SmartBudget budget;
  final bool isDark;

  const _BudgetHorizonRow({
    required this.budget,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final isOver = budget.isOverBudget;
    final isClose = !isOver && budget.usagePct >= 0.85;

    final statusColor = isOver
        ? const Color(0xFFE11D48)
        : (isClose ? const Color(0xFFD97706) : const Color(0xFF16A34A));

    final statusText = isOver
        ? 'Over by ${AppFormat.currency(budget.spent - budget.limit)}'
        : (isClose
            ? '${AppFormat.currency(budget.remaining)} remaining (${(budget.usagePct * 100).toInt()}%)'
            : '${AppFormat.currency(budget.remaining)} remaining');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Category & Status Headline
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                budget.categoryName,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: isDark ? 0.20 : 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Milestone Runway Path
          _MilestoneTrack(
            progress: budget.usagePct,
            activeColor: statusColor,
            isOver: isOver,
            isDark: isDark,
          ),
          const SizedBox(height: 6),

          // Spending Metrics
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Spent ${AppFormat.currency(budget.spent)}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF44403C),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'Limit ${AppFormat.currency(budget.limit)}',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyBudgetCard extends StatelessWidget {
  final BuildContext context;
  final bool isDark;

  const _EmptyBudgetCard({required this.context, required this.isDark});

  @override
  Widget build(BuildContext _) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
          width: 0.8,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? const Color(0x204F46E5) : const Color(0xFFEEF2FF),
            ),
            child: Icon(
              Icons.tune_rounded,
              size: 20,
              color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'No budget horizons yet',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Establish comfortable spending boundaries for categories like Food, Transport, and Shopping.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              AppPageRoute(builder: (_) => const BudgetManagementScreen()),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF4F46E5) : const Color(0xFF1C1917),
                borderRadius: BorderRadius.circular(100),
              ),
              child: const Text(
                '+ Set Budget Horizon',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// 3. Savings Landmarks Section (Goal Waypoint Journeys)
// ─────────────────────────────────────────────────────────────────

class _GoalsLandmarkList extends ConsumerWidget {
  final List<Goal> goals;
  final bool isDark;

  const _GoalsLandmarkList({
    required this.goals,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayGoals = goals.take(4).toList();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withValues(alpha: 0.25) : const Color(0x081C1917),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: List.generate(displayGoals.length, (index) {
          final goal = displayGoals[index];
          final progress = ref.watch(goalProgressProvider(goal));
          final isLast = index == displayGoals.length - 1;

          return Column(
            children: [
              _GoalLandmarkRow(
                goal: goal,
                progress: progress,
                isDark: isDark,
                onTap: () => Navigator.push(
                  context,
                  AppPageRoute(
                    builder: (_) => GoalDetailScreen(goal: goal),
                  ),
                ),
              ),
              if (!isLast)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(
                    height: 1,
                    thickness: 0.5,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFFF0ECE4),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _GoalLandmarkRow extends StatelessWidget {
  final Goal goal;
  final GoalProgress progress;
  final bool isDark;
  final VoidCallback onTap;

  const _GoalLandmarkRow({
    required this.goal,
    required this.progress,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (progress.progressPct * 100).clamp(0, 100).toInt();
    final isCompleted = progress.isCompleted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.03),
        child: Padding(
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
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: (isCompleted ? const Color(0xFF16A34A) : const Color(0xFF4F46E5))
                          .withValues(alpha: isDark ? 0.20 : 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isCompleted ? 'Achieved ✦' : '$pct%',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isCompleted ? const Color(0xFF16A34A) : const Color(0xFF4F46E5),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Milestone Runway Path
              _MilestoneTrack(
                progress: progress.progressPct,
                activeColor: isCompleted ? const Color(0xFF16A34A) : const Color(0xFF4F46E5),
                isDark: isDark,
              ),
              const SizedBox(height: 6),

              // Saved vs Target
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Saved ${AppFormat.currency(goal.targetAmount * progress.progressPct.clamp(0.0, 1.0))}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF44403C),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    'Target ${AppFormat.currency(goal.targetAmount)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyGoalsCard extends StatelessWidget {
  final BuildContext context;
  final bool isDark;

  const _EmptyGoalsCard({required this.context, required this.isDark});

  @override
  Widget build(BuildContext _) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
          width: 0.8,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? const Color(0x204F46E5) : const Color(0xFFEEF2FF),
            ),
            child: Icon(
              Icons.flag_outlined,
              size: 20,
              color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'No savings landmarks yet',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Establish milestones for major targets — travel, emergencies, or large milestones.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              AppPageRoute(builder: (_) => const AddGoalScreen()),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF4F46E5) : const Color(0xFF1C1917),
                borderRadius: BorderRadius.circular(100),
              ),
              child: const Text(
                '+ Set First Milestone',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// 4. Milestone Track Widget (Waypoint Spline & Diamond Finish)
// ─────────────────────────────────────────────────────────────────

class _MilestoneTrack extends StatelessWidget {
  final double progress;
  final Color activeColor;
  final bool isOver;
  final bool isDark;

  const _MilestoneTrack({
    required this.progress,
    required this.activeColor,
    this.isOver = false,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final clampedProgress = progress.clamp(0.0, 1.0);
        final currentX = clampedProgress * (w - 14);

        return SizedBox(
          height: 16,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Track background line
              Container(
                height: 4,
                width: w,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : const Color(0xFFEBE5D8),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Active filled line
              Container(
                height: 4,
                width: currentX + 6,
                decoration: BoxDecoration(
                  color: activeColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Target milestone diamond at far right
              Positioned(
                right: 0,
                child: Container(
                  width: 9,
                  height: 9,
                  transform: Matrix4.rotationZ(0.785398),
                  transformAlignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
                    border: Border.all(
                      color: isOver ? const Color(0xFFE11D48) : activeColor,
                      width: 1.8,
                    ),
                  ),
                ),
              ),
              // Current progress node with radiant halo
              Positioned(
                left: currentX,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: activeColor,
                    boxShadow: [
                      BoxShadow(
                        color: activeColor.withValues(alpha: 0.35),
                        blurRadius: 5,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// 5. Foundations Row Tile
// ─────────────────────────────────────────────────────────────────

class _FoundationsRowTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool isDark;
  final VoidCallback onTap;

  const _FoundationsRowTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.03),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: isDark ? 0.18 : 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E),
              ),
            ],
          ),
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
