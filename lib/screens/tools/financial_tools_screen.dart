import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/salary_ledger/salary_ledger_notifier.dart';
import '../../features/dashboard/insights_providers.dart';
import '../../features/health/health_score_provider.dart';
import '../plan/plan_tab.dart';
import '../../features/salary/screens/salary_screen.dart';
import '../../shared/widgets/app_page_route.dart';
import '../credit_card_screen.dart';
import '../financial_health_screen.dart';
import '../goals/goals_screen.dart';
import '../lending/lending_screen.dart';
import '../loans/loans_screen.dart';
import '../net_worth_screen.dart';
import '../recurring/recurring_payments_screen.dart';
import '../reports_screen.dart';

enum FinancialToolSection { cashFlow, wealth }

class FinancialToolsScreen extends ConsumerWidget {
  final FinancialToolSection section;
  const FinancialToolsScreen({super.key, required this.section});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    final salaryState = ref.watch(salaryLedgerProvider).valueOrNull;
    final monthStats = ref.watch(currentMonthStatsProvider).valueOrNull;
    final nw = ref.watch(netWorthChangeProvider).valueOrNull;
    final health = ref.watch(financialHealthScoreProvider).valueOrNull;

    final salaryMonth = salaryState?.currentMonth;
    final expectedIncome =
        salaryMonth == null ? 0.0 : salaryMonth.month.expectedAmount;
    final spent = (monthStats?.expense)?.toDouble() ?? 0;
    final netWorth = (nw?.current)?.toDouble() ?? 0;
    final healthScore = (health?.score)?.toInt() ?? 0;

    final isCashFlow = section == FinancialToolSection.cashFlow;

    final subsections = isCashFlow ? _cashFlowSubsections : _wealthSubsections;
    final Widget insight = isCashFlow
        ? _CashFlowInsight(expectedIncome: expectedIncome, spent: spent)
        : _WealthInsight(netWorth: netWorth, healthScore: healthScore);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          isCashFlow ? 'Cash Flow & Debt' : 'Wealth & Planning',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          isCashFlow
              ? 'Track income, spending and what you owe'
              : 'Grow and plan your net worth',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        insight,
        for (final sub in subsections) ...[
          const SizedBox(height: 20),
          _SectionHeader(title: sub.heading),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.35,
            ),
            itemCount: sub.tools.length,
            itemBuilder: (context, index) => _ToolCard(tool: sub.tools[index]),
          ),
        ],
      ],
    );
  }
}

// ── Cash Flow & Debt tools ──────────────────────────────────────────────────

class _SubSection {
  final String heading;
  final List<_Tool> tools;
  const _SubSection(this.heading, this.tools);
}

const _cashFlowSubsections = <_SubSection>[
  _SubSection('Cash Flow', [
    _Tool(
      icon: Icons.account_balance_wallet_rounded,
      title: 'Income & Salary',
      subtitle: 'Salary, employer reliability',
      color: Color(0xFF3B82F6),
      screen: SalaryScreen(),
    ),
    _Tool(
      icon: Icons.repeat_rounded,
      title: 'Recurring',
      subtitle: 'Rent, subscriptions',
      color: Color(0xFF8B5CF6),
      screen: RecurringPaymentsScreen(),
    ),
    _Tool(
      icon: Icons.credit_card_rounded,
      title: 'Credit Cards',
      subtitle: 'Cards, EMI, dues',
      color: Color(0xFF8B5CF6),
      screen: CreditCardScreen(),
    ),
  ]),
  _SubSection('Debt', [
    _Tool(
      icon: Icons.account_balance_rounded,
      title: 'Loans',
      subtitle: 'Loan repayments',
      color: Color(0xFFF59E0B),
      screen: LoansScreen(),
    ),
    _Tool(
      icon: Icons.swap_horiz_rounded,
      title: 'Lend & Borrow',
      subtitle: 'Money given & owed',
      color: Color(0xFF10B981),
      screen: LendingScreen(),
    ),
  ]),
];

// ── Wealth & Planning tools ─────────────────────────────────────────────────

const _wealthSubsections = <_SubSection>[
  _SubSection('Net Worth', [
    _Tool(
      icon: Icons.pie_chart_rounded,
      title: 'Net Worth',
      subtitle: 'Assets & liabilities',
      color: Color(0xFF0EA5E9),
      screen: NetWorthScreen(),
    ),
    _Tool(
      icon: Icons.flag_rounded,
      title: 'Goals',
      subtitle: 'Savings targets',
      color: Color(0xFF22C55E),
      screen: GoalsScreen(),
    ),
    _Tool(
      icon: Icons.favorite_rounded,
      title: 'Financial Health',
      subtitle: 'Discipline score',
      color: Color(0xFF22C55E),
      screen: FinancialHealthScreen(),
    ),
  ]),
  _SubSection('Planning', [
    _Tool(
      icon: Icons.checklist_rounded,
      title: 'Plans',
      subtitle: 'What to do next',
      color: Color(0xFF22C55E),
      screen: PlansScreen(),
    ),
    _Tool(
      icon: Icons.bar_chart_rounded,
      title: 'Reports',
      subtitle: 'Monthly & category',
      color: Color(0xFF0EA5E9),
      screen: ReportsScreen(),
    ),
  ]),
];

// ── Insight cards ───────────────────────────────────────────────────────────

class _CashFlowInsight extends StatelessWidget {
  final double expectedIncome;
  final double spent;
  const _CashFlowInsight({required this.expectedIncome, required this.spent});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final remaining = expectedIncome - spent;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.trending_up_rounded, color: cs.primary, size: 18),
              const SizedBox(width: 8),
              Text('This month\'s cash flow',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Mini(label: 'Expected in', value: _fmt(expectedIncome), color: const Color(0xFF22C55E)),
              _Mini(label: 'Spent', value: _fmt(spent), color: cs.error),
              _Mini(
                label: 'Free',
                value: _fmt(remaining),
                color: remaining >= 0 ? const Color(0xFF22C55E) : cs.error,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmt(double v) => '₹${v.abs().round()}';
}

class _WealthInsight extends StatelessWidget {
  final double netWorth;
  final int healthScore;
  const _WealthInsight({required this.netWorth, required this.healthScore});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.tertiary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.tertiary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pie_chart_rounded, color: cs.tertiary, size: 18),
              const SizedBox(width: 8),
              Text('Your wealth snapshot',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Mini(label: 'Net worth', value: _fmt(netWorth), color: cs.primary),
              _Mini(
                label: 'Health',
                value: '$healthScore',
                color: healthScore >= 60 ? const Color(0xFF22C55E) : cs.error,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmt(double v) => '₹${v.abs().round()}';
}

class _Mini extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _Mini({required this.label, required this.value, required this.color});

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
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 14)),
        ],
      ),
    );
  }
}

// ── Shared section header + tool tile ───────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  final _Tool tool;
  const _ToolCard({required this.tool});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          AppPageRoute(builder: (_) => tool.screen),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tool.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(tool.icon, color: tool.color, size: 22),
              ),
              const SizedBox(height: 10),
              Text(
                tool.title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Expanded(
                child: Text(
                  tool.subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tool {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final Widget screen;

  const _Tool({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.screen,
  });
}
