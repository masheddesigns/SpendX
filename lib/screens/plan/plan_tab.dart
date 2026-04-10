import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/automation/automation_engine.dart';
import '../../features/automation/automation_providers.dart';
import '../../features/budget/budget_providers.dart';
import '../../features/budget/smart_budget_engine.dart';
import '../../features/forecast/forecast_provider.dart';
import '../../features/goals/goal_providers.dart';
import '../../features/salary_ledger/salary_ledger_notifier.dart';
import '../../features/salary_ledger/salary_ledger_models.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../goals/goals_screen.dart';
import '../goals/add_goal_screen.dart';
import '../../features/salary/screens/salary_screen.dart';
import '../lending/lending_screen.dart';
import '../../features/timeline/financial_timeline_screen.dart';

/// The Plan tab — user's financial decision hub.
/// Consolidates: goals, salary, lending, budgets, recommendations.
class PlanTab extends ConsumerWidget {
  const PlanTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decisionAsync = ref.watch(dailyDecisionProvider);
    final salaryAsync = ref.watch(salaryLedgerProvider);
    final goalsAsync = ref.watch(activeGoalsProvider);
    final budgetsAsync = ref.watch(smartBudgetProvider);
    final forecastAsync = ref.watch(forecastProvider);
    final saveSugAsync = ref.watch(saveSuggestionProvider);
    final nudgesAsync = ref.watch(smartNudgesProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(activeGoalsProvider);
        ref.invalidate(smartBudgetProvider);
        ref.invalidate(forecastProvider);
        ref.invalidate(smartNudgesProvider);
      },
      child: ListView(
        padding: AppSpacing.cardPadding,
        children: [
          // ── Financial Timeline (Past → Present → Future) ──────────
          const FinancialTimelineScreen(),
          const SizedBox(height: 16),

          // ── Today's Decision ────────────────────────────────────
          decisionAsync.when(
            data: (decision) => _DecisionCard(decision: decision),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ── Quick Actions ──────────────────────────────────────────
          Row(
            children: [
              _QuickAction(
                icon: Icons.flag_rounded,
                label: 'Goals',
                color: const Color(0xFF22C55E),
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const GoalsScreen())),
              ),
              const SizedBox(width: 10),
              _QuickAction(
                icon: Icons.account_balance_wallet_rounded,
                label: 'Salary',
                color: const Color(0xFF0EA5E9),
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SalaryScreen())),
              ),
              const SizedBox(width: 10),
              _QuickAction(
                icon: Icons.swap_horiz_rounded,
                label: 'Lending',
                color: const Color(0xFF8B5CF6),
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const LendingScreen())),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ── Salary Status ──────────────────────────────────────────
          salaryAsync.when(
            data: (salaryState) {
              final current = salaryState.currentMonth;
              if (current == null) return const SizedBox.shrink();

              final cs = Theme.of(context).colorScheme;
              final isPaid = current.status == SalaryStatus.paid;
              final isPartial = current.status == SalaryStatus.partial;
              final statusColor = isPaid
                  ? const Color(0xFF22C55E)
                  : isPartial
                      ? const Color(0xFF0EA5E9)
                      : const Color(0xFFF59E0B);
              final statusText = current.status.label;

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: GestureDetector(
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const SalaryScreen())),
                  child: Card(
                    child: Padding(
                      padding: AppSpacing.cardPadding,
                      child: Row(
                        children: [
                          Container(
                            width: 44, height: 44,
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isPaid ? Icons.check_circle_rounded
                                  : isPartial ? Icons.timelapse_rounded
                                  : Icons.schedule_rounded,
                              color: statusColor, size: 22,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('This Month Salary',
                                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w600)),
                                Text(
                                  '${AppFormat.currency(current.month.expectedAmount)} \u2022 $statusText',
                                  style: TextStyle(color: statusColor, fontWeight: FontWeight.w500, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          // ── Forecast Summary ───────────────────────────────────────
          forecastAsync.when(
            data: (f) => f.predictedExpense > 0
                ? _PlanForecastCard(forecast: f)
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ── Recommendations ────────────────────────────────────────
          nudgesAsync.when(
            data: (nudges) {
              final saveSug = saveSugAsync.valueOrNull;
              if (nudges.isEmpty && saveSug == null) return const SizedBox.shrink();
              return _RecommendationsCard(nudges: nudges, saveSuggestion: saveSug);
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ── Active Goals ───────────────────────────────────────────
          goalsAsync.when(
            data: (goals) {
              if (goals.isEmpty) return _EmptyGoalsCard(context: context);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(title: 'Active Goals', count: goals.length),
                  const SizedBox(height: 8),
                  for (final goal in goals.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GoalCard(
                        goal: goal,
                        progress: ref.watch(goalProgressProvider(goal)),
                        onTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const GoalsScreen())),
                      ),
                    ),
                ],
              );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          const SizedBox(height: 16),

          // ── Smart Budget Status ─────────────────────────────────────
          budgetsAsync.when(
            data: (budgets) {
              if (budgets.isEmpty) return const SizedBox.shrink();
              final over = budgets.where((b) => b.isOverBudget).length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(
                    title: 'Budget Status',
                    count: budgets.length,
                    alert: over > 0 ? '$over over' : null,
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          for (final b in budgets.take(5))
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
        ],
      ),
    );
  }
}

// ── Decision Card ────────────────────────────────────────────────────────

class _DecisionCard extends StatelessWidget {
  final DailyDecision decision;

  const _DecisionCard({required this.decision});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    switch (decision.type) {
      case DailyDecisionType.critical:
        color = Theme.of(context).colorScheme.error;
        icon = Icons.error_rounded;
      case DailyDecisionType.warning:
        color = const Color(0xFFF59E0B);
        icon = Icons.warning_amber_rounded;
      case DailyDecisionType.caution:
        color = const Color(0xFF0EA5E9);
        icon = Icons.info_outline_rounded;
      case DailyDecisionType.positive:
        color = const Color(0xFF22C55E);
        icon = Icons.check_circle_rounded;
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.12), color.withValues(alpha: 0.04)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Today\'s Focus',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  decision.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Quick Action Button ──────────────────────────────────────────────────

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Forecast Card ────────────────────────────────────────────────────────

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
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700)),
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
                    value: AppFormat.currency(forecast.predictedSavings.abs()),
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

  const _FMini({required this.label, required this.value, required this.color});

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

// ── Recommendations ──────────────────────────────────────────────────────

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
                Icon(Icons.auto_fix_high_rounded, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text('What to do',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            if (saveSuggestion != null)
              _NudgeRow(
                icon: Icons.savings_rounded,
                color: const Color(0xFF22C55E),
                text: 'Save ${AppFormat.currency(saveSuggestion!.amount)} this month',
              ),
            for (final n in nudges)
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

  const _NudgeRow({required this.icon, required this.color, required this.text});

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
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

// ── Empty Goals ──────────────────────────────────────────────────────────

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
            Icon(Icons.flag_rounded, size: 36,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
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
                  MaterialPageRoute(builder: (_) => const AddGoalScreen())),
              child: const Text('Create Goal'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Section Header ───────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final String? alert;

  const _SectionHeader({required this.title, required this.count, this.alert});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700)),
        const SizedBox(width: 6),
        Text('($count)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant)),
        if (alert != null) ...[
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cs.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(alert!,
                style: TextStyle(color: cs.error, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ],
      ],
    );
  }
}

// ── Budget Row ───────────────────────────────────────────────────────────

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
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              Text(
                '${AppFormat.currency(budget.spent)} / ${AppFormat.currency(budget.limit)}',
                style: TextStyle(
                  fontSize: 11,
                  color: budget.isOverBudget ? cs.error : cs.onSurfaceVariant,
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
