import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../utils/app_format.dart';
import '../data/providers.dart';
import '../models/reports_summary.dart';

import 'reports/monthly_report_screen.dart';

/// Full financial reports screen with 5 tabs.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  late AnimationController _chartAnimCtrl;
  late Animation<double> _chartAnim;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });

    _chartAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _chartAnim = CurvedAnimation(
      parent: _chartAnimCtrl,
      curve: Curves.easeOutCubic,
    );
    _chartAnimCtrl.forward();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _chartAnimCtrl.dispose();
    super.dispose();
  }

  void _onPeriodChanged(int months) {
    ref.read(reportsPeriodProvider.notifier).state = months;
    _chartAnimCtrl.reset();
    _chartAnimCtrl.forward();
  }

  @override
  Widget build(BuildContext context) {
    final reportsAsync = ref.watch(reportsProvider);
    final period = ref.watch(reportsPeriodProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial Reports'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurfaceVariant,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Spending'),
            Tab(text: 'Credit'),
            Tab(text: 'Loans'),
            Tab(text: 'Lending'),
          ],
        ),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.tune),
            onSelected: _onPeriodChanged,
            itemBuilder: (_) => [
              for (final m in [3, 6, 12])
                PopupMenuItem(
                  value: m,
                  child: Text(
                    period == m ? '\u2713 Last $m Months' : 'Last $m Months',
                  ),
                ),
            ],
          ),
        ],
      ),
      body: reportsAsync.when(
        data: (summary) => TabBarView(
          controller: _tabController,
          children: [
            _OverviewTab(summary: summary, anim: _chartAnim),
            _SpendingTab(summary: summary, anim: _chartAnim),
            _CreditTab(summary: summary, anim: _chartAnim),
            _LoansTab(summary: summary, anim: _chartAnim),
            _LendingTab(summary: summary, anim: _chartAnim),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err')),
      ),
    );
  }
}

// =========================================================================
// OVERVIEW TAB
// =========================================================================

class _OverviewTab extends StatelessWidget {
  final ReportsSummary summary;
  final Animation<double> anim;
  const _OverviewTab({required this.summary, required this.anim});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final net = summary.netSavings;
    final isPositive = net >= 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── KPI Cards ──────────────────────────────
          Row(
            children: [
              Expanded(child: _KpiCard(
                label: 'Income', value: AppFormat.currency(summary.totalIncome),
                icon: Icons.trending_up, color: cs.primary)),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                label: 'Expense', value: AppFormat.currency(summary.totalExpense),
                icon: Icons.trending_down, color: cs.error)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _KpiCard(
                label: 'Net Savings', value: AppFormat.currency(net),
                icon: Icons.savings, color: isPositive ? Colors.green : cs.error)),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                label: 'Savings Rate',
                value: '${summary.savingsRate.toStringAsFixed(1)}%',
                icon: Icons.percent, color: summary.savingsRate >= 20 ? Colors.green : Colors.orange)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _KpiCard(
                label: 'Avg Daily Spend',
                value: AppFormat.currency(summary.avgDailySpending),
                icon: Icons.today, color: cs.tertiary)),
              const SizedBox(width: 10),
              if (summary.salarySourceCount > 0)
                Expanded(child: _KpiCard(
                  label: 'Salary Earned',
                  value: AppFormat.currency(summary.totalSalaryEarned),
                  icon: Icons.account_balance_wallet, color: Colors.blue))
              else
                const Expanded(child: SizedBox()),
            ],
          ),

          const SizedBox(height: 24),
          _SectionLabel('Income vs Expense'),
          const SizedBox(height: 12),
          _IncomeExpenseChart(data: summary.monthlyTrend, anim: anim),

          const SizedBox(height: 24),
          _SectionLabel('Monthly Net'),
          const SizedBox(height: 12),
          ...summary.monthlyTrend.map((d) => _NetRow(data: d)),

          const SizedBox(height: 24),
          Card(
            color: cs.primary.withValues(alpha: 0.05),
            child: ListTile(
              leading: Icon(Icons.analytics_outlined, color: cs.primary),
              title: const Text('Detailed Monthly Analysis'),
              subtitle: Text(
                  'View deep insights for ${DateFormat('MMMM').format(DateTime.now())}'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 14),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const MonthlyReportScreen())),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// =========================================================================
// SPENDING TAB (NEW)
// =========================================================================

class _SpendingTab extends StatelessWidget {
  final ReportsSummary summary;
  final Animation<double> anim;
  const _SpendingTab({required this.summary, required this.anim});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final categories = summary.topExpenseCategories;

    if (categories.isEmpty) {
      return _EmptyState(icon: Icons.pie_chart_outline, text: 'No expenses to analyze');
    }

    final totalExpense = categories.fold<double>(0, (s, c) => s + c.amount);
    final colors = [
      cs.primary, cs.error, cs.tertiary, Colors.orange, Colors.purple,
      Colors.teal, Colors.pink, Colors.indigo, Colors.amber, Colors.cyan,
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Pie Chart ──────────────────────────────
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: AnimatedBuilder(
                    animation: anim,
                    builder: (_, _) => PieChart(
                      PieChartData(
                        sections: categories.asMap().entries.map((e) {
                          final pct = totalExpense > 0
                              ? (e.value.amount / totalExpense) * 100
                              : 0.0;
                          return PieChartSectionData(
                            value: e.value.amount * anim.value,
                            title: pct >= 5 ? '${pct.toStringAsFixed(0)}%' : '',
                            color: colors[e.key % colors.length],
                            radius: 55,
                            titleStyle: const TextStyle(
                              fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                          );
                        }).toList(),
                        sectionsSpace: 2,
                        centerSpaceRadius: 45,
                        centerSpaceColor: cs.surfaceContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: categories.take(6).toList().asMap().entries.map((e) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 10, height: 10,
                          decoration: BoxDecoration(
                            color: colors[e.key % colors.length],
                            shape: BoxShape.circle)),
                        const SizedBox(width: 4),
                        Text(e.value.categoryName,
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
                      ],
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          _SectionLabel('Top Spending Categories'),
          const SizedBox(height: 12),

          // ── Category List ──────────────────────────
          ...categories.asMap().entries.map((e) {
            final c = e.value;
            final pct = totalExpense > 0 ? c.amount / totalExpense : 0.0;
            final color = colors[e.key % colors.length];

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10)),
                        child: Center(
                          child: Text('${e.key + 1}',
                            style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.categoryName,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            Text('${c.transactionCount} transactions',
                              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(AppFormat.currency(c.amount),
                            style: TextStyle(fontWeight: FontWeight.bold, color: cs.error, fontSize: 14)),
                          Text('${(pct * 100).toStringAsFixed(1)}%',
                            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      backgroundColor: cs.outline.withValues(alpha: 0.1),
                      valueColor: AlwaysStoppedAnimation(color),
                      minHeight: 4,
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// =========================================================================
// CREDIT TAB
// =========================================================================

class _CreditTab extends StatelessWidget {
  final ReportsSummary summary;
  final Animation<double> anim;
  const _CreditTab({required this.summary, required this.anim});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (summary.creditSummaries.isEmpty) {
      return _EmptyState(icon: Icons.credit_card_off, text: 'No credit cards added yet');
    }

    final totalOutstanding = summary.creditSummaries.fold<double>(0, (s, c) => s + c.outstanding);
    final totalLimit = summary.creditSummaries.fold<double>(0, (s, c) => s + c.limit);
    final overallUtil = totalLimit > 0 ? (totalOutstanding / totalLimit) * 100 : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Overall credit health
          Row(
            children: [
              Expanded(child: _KpiCard(
                label: 'Total Outstanding',
                value: AppFormat.currency(totalOutstanding),
                icon: Icons.credit_card, color: cs.error)),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                label: 'Overall Utilization',
                value: '${overallUtil.toStringAsFixed(0)}%',
                icon: Icons.donut_large,
                color: overallUtil >= 80 ? Colors.red : overallUtil >= 50 ? Colors.orange : Colors.green)),
            ],
          ),
          const SizedBox(height: 24),

          _SectionLabel('Outstanding per Card'),
          const SizedBox(height: 12),
          _CreditBarChart(summaries: summary.creditSummaries, anim: anim),
          const SizedBox(height: 24),

          _SectionLabel('Card Details'),
          const SizedBox(height: 12),
          ...summary.creditSummaries.map((c) => _CreditDetailCard(card: c)),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// =========================================================================
// LOANS TAB
// =========================================================================

class _LoansTab extends StatelessWidget {
  final ReportsSummary summary;
  final Animation<double> anim;
  const _LoansTab({required this.summary, required this.anim});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (summary.loanSummaries.isEmpty) {
      return _EmptyState(icon: Icons.account_balance_outlined, text: 'No active loans');
    }

    final totalDebt = summary.loanSummaries.fold<double>(0, (s, l) => s + l.remainingPrincipal);
    final totalPaid = summary.loanSummaries.fold<double>(0, (s, l) => s + l.principalPaid);
    final overallProgress = (totalPaid + totalDebt) > 0
        ? totalPaid / (totalPaid + totalDebt) : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _KpiCard(
                label: 'Total Debt',
                value: AppFormat.currency(totalDebt),
                icon: Icons.account_balance, color: cs.error)),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                label: 'Overall Progress',
                value: '${(overallProgress * 100).toStringAsFixed(0)}%',
                icon: Icons.trending_up, color: cs.primary)),
            ],
          ),
          const SizedBox(height: 24),

          _SectionLabel('Principal vs Interest'),
          const SizedBox(height: 12),
          _LoanPieChart(summaries: summary.loanSummaries, anim: anim),
          const SizedBox(height: 24),

          _SectionLabel('Loan Progress'),
          const SizedBox(height: 12),
          ...summary.loanSummaries.map((l) => _LoanProgressCard(loan: l)),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// =========================================================================
// LENDING TAB
// =========================================================================

class _LendingTab extends StatelessWidget {
  final ReportsSummary summary;
  final Animation<double> anim;
  const _LendingTab({required this.summary, required this.anim});

  @override
  Widget build(BuildContext context) {
    if (summary.totalLent == 0 && summary.totalBorrowed == 0) {
      return _EmptyState(icon: Icons.handshake_outlined, text: 'No lending records');
    }

    final netLending = summary.totalLent - summary.totalBorrowed;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _KpiCard(
                label: 'Total Lent', value: AppFormat.currency(summary.totalLent),
                icon: Icons.call_made, color: Colors.green)),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                label: 'Total Borrowed', value: AppFormat.currency(summary.totalBorrowed),
                icon: Icons.call_received, color: Colors.orange)),
            ],
          ),
          const SizedBox(height: 10),
          _KpiCard(
            label: 'Net Position',
            value: '${netLending >= 0 ? "+" : ""}${AppFormat.currency(netLending)}',
            icon: netLending >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
            color: netLending >= 0 ? Colors.green : Colors.orange),
          const SizedBox(height: 24),

          _SectionLabel('Monthly Lending Trend'),
          const SizedBox(height: 12),
          _LendingTrendChart(trend: summary.lendingTrend, anim: anim),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// =========================================================================
// SHARED WIDGETS
// =========================================================================

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _KpiCard({required this.label, required this.value,
    required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0.03)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(
                color: color, fontWeight: FontWeight.w600, fontSize: 16)),
            ],
          )),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2));
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 60, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(text, style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 16)),
        ],
      ),
    ));
  }
}

class _NetRow extends StatelessWidget {
  final MonthData data;
  const _NetRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final net = data.net;
    final isPositive = net >= 0;
    final color = isPositive
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Text(data.label, style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface, fontSize: 13, fontWeight: FontWeight.w500)),
          const Spacer(),
          Icon(isPositive ? Icons.arrow_upward : Icons.arrow_downward,
            size: 14, color: color),
          const SizedBox(width: 4),
          Text(AppFormat.currency(net.abs()), style: TextStyle(
            color: color, fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}

// ── Charts ────────────────────────────────────────────────

class _IncomeExpenseChart extends StatelessWidget {
  final List<MonthData> data;
  final Animation<double> anim;
  const _IncomeExpenseChart({required this.data, required this.anim});

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const _ChartEmpty('No transactions yet');
    final cs = Theme.of(context).colorScheme;
    final maxVal = data.fold<double>(0.0,
      (m, d) => [m, d.income, d.expense].reduce((a, b) => a > b ? a : b));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _Legend(color: cs.primary, label: 'Income'),
            const SizedBox(width: 16),
            _Legend(color: cs.error, label: 'Expense'),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: AnimatedBuilder(
              animation: anim,
              builder: (_, _) => BarChart(BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxVal * 1.2,
                barTouchData: BarTouchData(enabled: true),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= data.length) return const SizedBox.shrink();
                      return Padding(padding: const EdgeInsets.only(top: 8),
                        child: Text(data[i].label,
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w600)));
                    },
                  )),
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: FlGridData(show: true, drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(color: cs.outline.withValues(alpha: 0.1))),
                borderData: FlBorderData(show: false),
                barGroups: data.asMap().map((i, d) => MapEntry(i,
                  BarChartGroupData(x: i, barsSpace: 8, barRods: [
                    BarChartRodData(toY: d.income * anim.value, color: cs.primary.withValues(alpha: 0.9),
                      width: 14, borderRadius: const BorderRadius.vertical(top: Radius.circular(6))),
                    BarChartRodData(toY: d.expense * anim.value, color: cs.error.withValues(alpha: 0.9),
                      width: 14, borderRadius: const BorderRadius.vertical(top: Radius.circular(6))),
                  ]),
                )).values.toList(),
              )),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreditBarChart extends StatelessWidget {
  final List<CreditCardSummary> summaries;
  final Animation<double> anim;
  const _CreditBarChart({required this.summaries, required this.anim});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxVal = summaries.fold<double>(0, (m, c) => m > c.outstanding ? m : c.outstanding);
    if (maxVal == 0) return const _ChartEmpty('No outstanding dues');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        height: 180,
        child: AnimatedBuilder(animation: anim, builder: (_, _) => BarChart(BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxVal * 1.2,
          barTouchData: BarTouchData(enabled: true),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= summaries.length) return const SizedBox.shrink();
                return Padding(padding: const EdgeInsets.only(top: 4),
                  child: Text(summaries[i].name.split(' ').first,
                    style: const TextStyle(color: Colors.grey, fontSize: 9)));
              },
            )),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: FlGridData(show: true, drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => const FlLine(color: Colors.white10)),
          borderData: FlBorderData(show: false),
          barGroups: summaries.asMap().map((i, c) => MapEntry(i,
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(toY: c.outstanding * anim.value,
                gradient: LinearGradient(colors: [cs.error, cs.error.withValues(alpha: 0.6)],
                  begin: Alignment.bottomCenter, end: Alignment.topCenter),
                width: 20, borderRadius: const BorderRadius.vertical(top: Radius.circular(6))),
            ]),
          )).values.toList(),
        ))),
      ),
    );
  }
}

class _CreditDetailCard extends StatelessWidget {
  final CreditCardSummary card;
  const _CreditDetailCard({required this.card});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final utilColor = card.utilPct >= 80 ? Colors.red
        : card.utilPct >= 50 ? Colors.orange : Colors.green;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(card.name, style: TextStyle(
              color: cs.onSurface, fontWeight: FontWeight.w600, fontSize: 14)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: (card.daysLeft <= 5 ? cs.error : cs.secondary).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20)),
              child: Text('Due in ${card.daysLeft}d', style: TextStyle(
                color: card.daysLeft <= 5 ? cs.error : cs.secondary,
                fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 12),
          ClipRRect(borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (card.utilPct / 100).clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation(utilColor), minHeight: 6)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Outstanding: ${AppFormat.currency(card.outstanding)}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            Text('${card.utilPct.toStringAsFixed(0)}% used',
              style: TextStyle(color: utilColor, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ],
      ),
    );
  }
}

class _LoanPieChart extends StatelessWidget {
  final List<LoanSummary> summaries;
  final Animation<double> anim;
  const _LoanPieChart({required this.summaries, required this.anim});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalP = summaries.fold<double>(0, (s, l) => s + l.principalPaid);
    final totalI = summaries.fold<double>(0, (s, l) => s + l.interestPaid);
    if (totalP + totalI == 0) return const _ChartEmpty('No payments recorded');

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: Column(children: [
        SizedBox(height: 160, child: PieChart(PieChartData(
          sections: [
            PieChartSectionData(value: totalP, title: 'Principal', color: cs.primary,
              radius: 50, titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
            PieChartSectionData(value: totalI, title: 'Interest', color: cs.error,
              radius: 50, titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
          sectionsSpace: 2, centerSpaceRadius: 40,
        ))),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _Legend(color: cs.primary, label: 'Principal (${AppFormat.currency(totalP)})'),
          const SizedBox(width: 16),
          _Legend(color: cs.error, label: 'Interest (${AppFormat.currency(totalI)})'),
        ]),
      ]),
    );
  }
}

class _LoanProgressCard extends StatelessWidget {
  final LoanSummary loan;
  const _LoanProgressCard({required this.loan});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(loan.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          Text('${(loan.progress * 100).toStringAsFixed(1)}%',
            style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold, fontSize: 14)),
        ]),
        const SizedBox(height: 12),
        ClipRRect(borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: loan.progress,
            backgroundColor: Colors.white10,
            valueColor: AlwaysStoppedAnimation(cs.primary), minHeight: 8)),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Paid: ${AppFormat.currency(loan.principalPaid)}',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text('Remaining: ${AppFormat.currency(loan.remainingPrincipal)}',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ]),
    );
  }
}

class _LendingTrendChart extends StatelessWidget {
  final List<LendingTrendData> trend;
  final Animation<double> anim;
  const _LendingTrendChart({required this.trend, required this.anim});

  @override
  Widget build(BuildContext context) {
    if (trend.isEmpty) return const _ChartEmpty('No lending history');
    final cs = Theme.of(context).colorScheme;
    final maxVal = trend.fold<double>(0, (m, d) => m > d.net.abs() ? m : d.net.abs());

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        height: 160,
        child: BarChart(BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxVal * 1.5, minY: -maxVal * 1.5,
          barTouchData: BarTouchData(enabled: true),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= trend.length) return const SizedBox.shrink();
                return Padding(padding: const EdgeInsets.only(top: 4),
                  child: Text(trend[i].label, style: const TextStyle(fontSize: 9, color: Colors.grey)));
              },
            )),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barGroups: trend.asMap().map((i, d) => MapEntry(i,
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(toY: d.net, color: d.net >= 0 ? Colors.green : Colors.orange,
                width: 16, borderRadius: BorderRadius.circular(4)),
            ]),
          )).values.toList(),
        )),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
    ]);
  }
}

class _ChartEmpty extends StatelessWidget {
  final String msg;
  const _ChartEmpty(this.msg);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160, alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20)),
      child: Text(msg, style: const TextStyle(color: Colors.grey)),
    );
  }
}
