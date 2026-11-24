import 'package:flutter/material.dart';
import 'package:spend_x/theme/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';

import '../data/providers.dart';
import '../models/reports_summary.dart';
import '../services/export_service.dart';
import '../shared/widgets/error_state_widget.dart';
import '../shared/widgets/skeleton_loader.dart';
import '../shared/widgets/glass/spendx_glass_surface.dart';
import '../shared/widgets/glass/spendx_glass_sheet.dart';
import '../shared/widgets/glass/spendx_scaffold.dart';
import '../shared/widgets/spendx_app_bar.dart';
import '../utils/app_format.dart';
import 'reports/reports_category_resolver.dart';

/// SpendX Financial Reports Screen.
///
/// Designed around actual financial data capabilities:
/// 1. Cash Flow Cadence: Executive net savings and flow ratios.
/// 2. Monthly Movement: Left-to-right chronological dual-stem timeline.
/// 3. Where Your Money Went: Exact-mapped category distribution with proportional bars.
/// 4. Debt & Lending History: Peer lending net trend, loan principal amortization, and credit exposure.
/// 5. Persistent Horizon Selector: 3M, 6M, 12M with explicit calendar span.
/// 6. Verified Transaction Export: CSV and JSON via [ExportService].
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _chartAnimCtrl;
  late Animation<double> _chartAnim;

  @override
  void initState() {
    super.initState();
    _chartAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _chartAnim = CurvedAnimation(
      parent: _chartAnimCtrl,
      curve: Curves.easeOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _chartAnimCtrl.value = 1;
      } else {
        _chartAnimCtrl.forward();
      }
    });
  }

  @override
  void dispose() {
    _chartAnimCtrl.dispose();
    super.dispose();
  }

  void _onPeriodChanged(int months) {
    if (ref.read(reportsPeriodProvider) == months) return;
    ref.read(reportsPeriodProvider.notifier).state = months;
    if (MediaQuery.disableAnimationsOf(context)) {
      _chartAnimCtrl.value = 1;
    } else {
      _chartAnimCtrl.reset();
      _chartAnimCtrl.forward();
    }
  }

  void _showExportSheet(BuildContext context) {
    final period = ref.read(reportsPeriodProvider);
    SpendXGlassSheet.show(
      context: context,
      title: 'Export Transactions',
      builder: (ctx) => _ExportTransactionsSheetContent(period: period),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reportsAsync = ref.watch(reportsProvider);
    final period = ref.watch(reportsPeriodProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: 'Financial Reports',
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Export Transactions',
            onPressed: () => _showExportSheet(context),
          ),
        ],
      ),
      body: reportsAsync.when(
        data: (summary) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(reportsProvider),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 8, 16, bottomInset + 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 1. Horizon Selector & Date Span ──────────────────
                _HorizonSelector(
                  selectedPeriod: period,
                  onPeriodChanged: _onPeriodChanged,
                  isDark: isDark,
                ),

                const SizedBox(height: 20),

                // ── 2. Cash Flow Horizon (Cardless Executive Summary) ─
                _CashFlowHorizonSection(summary: summary, isDark: isDark),

                const SizedBox(height: 24),

                // ── 3. Monthly Movement (Chronological Dual-Stem) ─────
                _MonthlyMovementSection(
                  summary: summary,
                  anim: _chartAnim,
                  isDark: isDark,
                ),

                const SizedBox(height: 28),

                // ── 4. Where Your Money Went (Category Trajectory) ────
                _CategoryBreakdownSection(summary: summary, isDark: isDark),

                const SizedBox(height: 28),

                // ── 5. Debt & Lending History ─────────────────────────
                _DebtAndLendingSection(
                  summary: summary,
                  anim: _chartAnim,
                  isDark: isDark,
                ),
              ],
            ),
          ),
        ),
        loading: () => const SkeletonLoader.summary(),
        error: (err, _) => ErrorStateWidget(
          error: err,
          onRetry: () => ref.invalidate(reportsProvider),
        ),
      ),
    );
  }
}

// =========================================================================
// 1. HORIZON SELECTOR (3M, 6M, 12M WITH EXPLICIT DATE SPAN)
// =========================================================================

class _HorizonSelector extends StatelessWidget {
  final int selectedPeriod;
  final ValueChanged<int> onPeriodChanged;
  final bool isDark;

  const _HorizonSelector({
    required this.selectedPeriod,
    required this.onPeriodChanged,
    required this.isDark,
  });

  String _formatDateRange(int months) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - months + 1, 1);
    final fmt = DateFormat('MMM yyyy');
    return '${fmt.format(start)} – ${fmt.format(now)}';
  }

  @override
  Widget build(BuildContext context) {
    final rangeText = _formatDateRange(selectedPeriod);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your money, over time',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _PillButton(
              label: '3 months',
              isSelected: selectedPeriod == 3,
              isDark: isDark,
              onTap: () => onPeriodChanged(3),
            ),
            const SizedBox(width: 8),
            _PillButton(
              label: '6 months',
              isSelected: selectedPeriod == 6,
              isDark: isDark,
              onTap: () => onPeriodChanged(6),
            ),
            const SizedBox(width: 8),
            _PillButton(
              label: '12 months',
              isSelected: selectedPeriod == 12,
              isDark: isDark,
              onTap: () => onPeriodChanged(12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              Icons.date_range_rounded,
              size: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              rangeText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _PillButton({
    required this.label,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeBg = cs.primaryContainer;
    final inactiveBg = cs.surfaceContainer;

    final activeText = cs.onPrimaryContainer;
    final inactiveText = Theme.of(context).colorScheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: isSelected,
      label: '$label period',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected ? activeBg : inactiveBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? cs.primary : cs.outline,
                width: 1,
              ),
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? activeText : inactiveText,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// 2. CASH FLOW HORIZON (CARDLESS EXECUTIVE SUMMARY)
// =========================================================================

class _CashFlowHorizonSection extends StatelessWidget {
  final ReportsSummary summary;
  final bool isDark;

  const _CashFlowHorizonSection({required this.summary, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final net = summary.netSavings;
    final isPositive = net >= 0;

    final primaryInflowColor = Theme.of(context).colorScheme.secondary;
    final primaryOutflowColor = cs.error;
    final netColor = isPositive ? primaryInflowColor : primaryOutflowColor;

    // Semantic savings rate display: handle zero income cleanly
    final String savingsRateText;
    final Color savingsRateColor;
    if (summary.totalIncome > 0) {
      savingsRateText = '${summary.savingsRate.toStringAsFixed(1)}%';
      savingsRateColor = summary.savingsRate >= 20
          ? primaryInflowColor
          : (summary.savingsRate >= 0 ? Colors.orange : cs.error);
    } else if (summary.totalExpense > 0) {
      savingsRateText = 'Deficit (0% Inflow)';
      savingsRateColor = cs.error;
    } else {
      savingsRateText = '0.0%';
      savingsRateColor = context.textMuted;
    }

    return SpendXGlassSurface(
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'CASH FLOW',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  'Income − Expenses',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Large Hero Net Savings Figure
            Text(
              isPositive
                  ? '+${AppFormat.currency(net)}'
                  : '-${AppFormat.currency(net.abs())}',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: netColor,
                letterSpacing: -0.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              isPositive
                  ? 'Net retained savings across this horizon'
                  : 'Net deficit across this horizon (spending exceeded inflows)',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 16),
            Divider(
              color: context.borderColor,
              height: 1,
            ),
            const SizedBox(height: 14),

            // Four Flow Pillars with Responsive Breakpoint
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 600;
                if (isWide) {
                  return Row(
                    children: [
                      Expanded(
                        child: _MetricPillar(
                          label: 'Total Inflow',
                          value: AppFormat.currency(summary.totalIncome),
                          valueColor: primaryInflowColor,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MetricPillar(
                          label: 'Total Outflow',
                          value: AppFormat.currency(summary.totalExpense),
                          valueColor: primaryOutflowColor,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MetricPillar(
                          label: 'Savings Rate',
                          value: savingsRateText,
                          valueColor: savingsRateColor,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MetricPillar(
                          label: 'Avg Daily Spend',
                          value: AppFormat.currency(summary.avgDailySpending),
                          valueColor: Theme.of(context).colorScheme.onSurface,
                          isDark: isDark,
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _MetricPillar(
                            label: 'Total Inflow',
                            value: AppFormat.currency(summary.totalIncome),
                            valueColor: primaryInflowColor,
                            isDark: isDark,
                          ),
                        ),
                        Expanded(
                          child: _MetricPillar(
                            label: 'Total Outflow',
                            value: AppFormat.currency(summary.totalExpense),
                            valueColor: primaryOutflowColor,
                            isDark: isDark,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _MetricPillar(
                            label: 'Savings Rate',
                            value: savingsRateText,
                            valueColor: savingsRateColor,
                            isDark: isDark,
                          ),
                        ),
                        Expanded(
                          child: _MetricPillar(
                            label: 'Avg Daily Spend',
                            value: AppFormat.currency(summary.avgDailySpending),
                            valueColor: Theme.of(context).colorScheme.onSurface,
                            isDark: isDark,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),

            if (summary.salarySourceCount > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: context.onSurfaceOverlay(
                    lightOpacity: 0.03,
                    darkOpacity: 0.04,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.payments_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Verified Salary Received:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      AppFormat.currency(summary.totalSalaryEarned),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.secondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetricPillar extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;
  final bool isDark;

  const _MetricPillar({
    required this.label,
    required this.value,
    required this.valueColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: valueColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// =========================================================================
// 3. MONTHLY MOVEMENT (CHRONOLOGICAL LEFT-TO-RIGHT BAR CHART)
// =========================================================================

class _MonthlyMovementSection extends StatelessWidget {
  final ReportsSummary summary;
  final Animation<double> anim;
  final bool isDark;

  const _MonthlyMovementSection({
    required this.summary,
    required this.anim,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final inflowColor = Theme.of(context).colorScheme.secondary;
    final outflowColor = cs.error;

    // SAFE REVERSAL: The underlying repository and service provide newest-first.
    // We reverse ONLY for chart presentation so time moves left-to-right (past to present).
    final chronologicalData = summary.monthlyTrend.reversed.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'MONTHLY MOVEMENT',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Row(
              children: [
                _ChartLegendDot(color: inflowColor, label: 'Inflow'),
                const SizedBox(width: 12),
                _ChartLegendDot(color: outflowColor, label: 'Outflow'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),

        SpendXGlassSurface(
          level: SpendXGlassLevel.base,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: chronologicalData.isEmpty
                ? SizedBox(
                    height: 160,
                    child: Center(
                      child: Text(
                        'No transaction records in this time horizon.',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                : _buildBarChart(
                    context,
                    chronologicalData,
                    cs,
                    inflowColor,
                    outflowColor,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildBarChart(
    BuildContext context,
    List<MonthData> data,
    ColorScheme cs,
    Color inflowColor,
    Color outflowColor,
  ) {
    final maxVal = data.fold<double>(
      0.0,
      (m, d) => [m, d.income, d.expense].reduce((a, b) => a > b ? a : b),
    );
    final chartCeiling = maxVal > 0 ? maxVal * 1.25 : 1000.0;

    return SizedBox(
      height: 200,
      child: AnimatedBuilder(
        animation: anim,
        builder: (_, _) => BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: chartCeiling,
            barTouchData: BarTouchData(
              enabled: true,
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => cs.surfaceContainer,
                tooltipBorderRadius: BorderRadius.circular(8),
                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                  final item = data[group.x.toInt()];
                  final isIncomeRod = rodIndex == 0;
                  final label = isIncomeRod ? 'Inflow' : 'Outflow';
                  final amount = isIncomeRod ? item.income : item.expense;
                  final currentMonthLabel = DateFormat(
                    'MMM yy',
                  ).format(DateTime.now());
                  final monthTitle = item.label == currentMonthLabel
                      ? '${item.label} (MTD)'
                      : item.label;
                  return BarTooltipItem(
                    '$monthTitle\n$label: ${AppFormat.currency(amount)}',
                    TextStyle(
                      color: context.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  );
                },
              ),
            ),
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
                    if (i < 0 || i >= data.length) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        data[i].label,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  },
                ),
              ),
              leftTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
            ),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(
                color: context.borderColor,
                strokeWidth: 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            barGroups: data.asMap().entries.map((entry) {
              final i = entry.key;
              final d = entry.value;
              final rodWidth = data.length <= 4 ? 14.0 : 10.0;
              return BarChartGroupData(
                x: i,
                barsSpace: 4,
                barRods: [
                  BarChartRodData(
                    toY: d.income * anim.value,
                    color: inflowColor,
                    width: rodWidth,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(5),
                    ),
                  ),
                  BarChartRodData(
                    toY: d.expense * anim.value,
                    color: outflowColor,
                    width: rodWidth,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(5),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _ChartLegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _ChartLegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

// =========================================================================
// 4. WHERE YOUR MONEY WENT (EXACT RESOLVER & PROPORTIONAL BARS)
// =========================================================================

class _CategoryBreakdownSection extends StatelessWidget {
  final ReportsSummary summary;
  final bool isDark;

  const _CategoryBreakdownSection({
    required this.summary,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final categories = summary.topExpenseCategories;
    final totalExpense = categories.fold<double>(0, (s, c) => s + c.amount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'WHERE YOUR MONEY WENT',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (categories.isNotEmpty)
              Text(
                '${categories.length} categories',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),

        if (categories.isEmpty)
          SpendXGlassSurface(
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.section),
              child: Center(
                child: Text(
                  'No categorized expense records in this time horizon.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          )
        else
          SpendXGlassSurface(
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: categories.length,
                separatorBuilder: (_, _) => Divider(
                  color: context.borderColor,
                  height: 16,
                ),
                itemBuilder: (context, i) {
                  final c = categories[i];
                  final humanName = ReportsCategoryResolver.resolve(
                    c.categoryName,
                  );
                  final pct = totalExpense > 0
                      ? (c.amount / totalExpense)
                      : 0.0;

                  return _CategoryProportionRow(
                    name: humanName,
                    amount: c.amount,
                    percentage: pct,
                    transactionCount: c.transactionCount,
                    isDark: isDark,
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _CategoryProportionRow extends StatelessWidget {
  final String name;
  final double amount;
  final double percentage;
  final int transactionCount;
  final bool isDark;

  const _CategoryProportionRow({
    required this.name,
    required this.amount,
    required this.percentage,
    required this.transactionCount,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final trackColor = context.borderColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: context.onSurfaceOverlay(
                        lightOpacity: 0.04,
                        darkOpacity: 0.05,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$transactionCount tx',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                Text(
                  AppFormat.currency(amount),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(percentage * 100).toStringAsFixed(1)}%',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percentage.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: trackColor,
            valueColor: AlwaysStoppedAnimation(
              Theme.of(context).colorScheme.secondary,
            ),
          ),
        ),
      ],
    );
  }
}

// =========================================================================
// 5. DEBT & LENDING HISTORY (PEER LENDING, LOAN PRINCIPAL, REVOLVING CREDIT)
// =========================================================================

class _DebtAndLendingSection extends StatelessWidget {
  final ReportsSummary summary;
  final Animation<double> anim;
  final bool isDark;

  const _DebtAndLendingSection({
    required this.summary,
    required this.anim,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'DEBT & LENDING HISTORY',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Changes in borrowing, obligations & peer lending over time',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),

        // Sub-item 1: Peer Lending Cadence (Genuine Monthly Movement)
        _PeerLendingCadenceCard(
          trend: summary.lendingTrend,
          totalLent: summary.totalLent,
          totalBorrowed: summary.totalBorrowed,
          anim: anim,
          isDark: isDark,
        ),

        const SizedBox(height: 14),

        // Sub-item 2: Loan Principal Amortization (Zero Fake Interest)
        _LoanPrincipalAmortizationCard(
          loans: summary.loanSummaries,
          isDark: isDark,
        ),

        const SizedBox(height: 14),

        // Sub-item 3: Revolving Credit Exposure (Current Outstanding & Util)
        _RevolvingCreditExposureCard(
          cards: summary.creditSummaries,
          isDark: isDark,
        ),
      ],
    );
  }
}

/// Peer lending monthly movement chart and balance sheet.
class _PeerLendingCadenceCard extends StatelessWidget {
  final List<LendingTrendData> trend;
  final double totalLent;
  final double totalBorrowed;
  final Animation<double> anim;
  final bool isDark;

  const _PeerLendingCadenceCard({
    required this.trend,
    required this.totalLent,
    required this.totalBorrowed,
    required this.anim,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final netLending = totalLent - totalBorrowed;
    final isNetLent = netLending >= 0;
    final lentColor = Theme.of(context).colorScheme.secondary;
    final borrowedColor = Theme.of(context).colorScheme.tertiary;

    return SpendXGlassSurface(
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.handshake_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Peer Lending Cadence',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  isNetLent ? 'Net Receivable' : 'Net Payable',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isNetLent ? lentColor : borrowedColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Summary figures
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Lent',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        AppFormat.currency(totalLent),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: lentColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Borrowed',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        AppFormat.currency(totalBorrowed),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: borrowedColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Net Position',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${isNetLent ? '+' : ''}${AppFormat.currency(netLending)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isNetLent ? lentColor : borrowedColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            if (trend.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _ChartLegendDot(color: lentColor, label: 'Lent (+)'),
                  const SizedBox(width: 12),
                  _ChartLegendDot(color: borrowedColor, label: 'Borrowed (−)'),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 120,
                child: _buildLendingTrendChart(
                  lentColor,
                  borrowedColor,
                  Theme.of(context).colorScheme.onSurfaceVariant,
                  Theme.of(context).colorScheme,
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'No peer lending records captured in this period.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLendingTrendChart(
    Color lentColor,
    Color borrowedColor,
    Color neutralColor,
    ColorScheme colorScheme,
  ) {
    final maxVal = trend.fold<double>(
      0.0,
      (m, d) => m > d.net.abs() ? m : d.net.abs(),
    );
    final ceiling = maxVal > 0 ? maxVal * 1.3 : 1000.0;

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: ceiling,
        minY: -ceiling,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => colorScheme.surfaceContainer,
            tooltipBorderRadius: BorderRadius.circular(8),
            getTooltipItem: (group, _, rod, rodIndex) {
              final d = trend[group.x.toInt()];
              final isPositive = d.net >= 0;
              return BarTooltipItem(
                '${d.label}\n${isPositive ? 'Net Lent (+):' : 'Net Borrowed (−):'} ${AppFormat.currency(d.net.abs())}',
                TextStyle(
                  color: isPositive ? lentColor : borrowedColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= trend.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    trend[i].label,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: neutralColor,
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        barGroups: trend.asMap().entries.map((entry) {
          final i = entry.key;
          final d = entry.value;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: d.net,
                color: d.net >= 0 ? lentColor : borrowedColor,
                width: 14,
                borderRadius: BorderRadius.circular(4),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

/// Loan Principal Amortization (Cumulative Principal Paid vs Remaining Balance).
class _LoanPrincipalAmortizationCard extends StatelessWidget {
  final List<LoanSummary> loans;
  final bool isDark;

  const _LoanPrincipalAmortizationCard({
    required this.loans,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final totalDebt = loans.fold<double>(0, (s, l) => s + l.remainingPrincipal);
    final totalPaid = loans.fold<double>(0, (s, l) => s + l.principalPaid);
    final totalOriginal = totalDebt + totalPaid;
    final overallProgress = totalOriginal > 0
        ? (totalPaid / totalOriginal)
        : 0.0;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final errorColor = Theme.of(context).colorScheme.error;

    return SpendXGlassSurface(
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.account_balance_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Loan Principal Amortization',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${(overallProgress * 100).toStringAsFixed(0)}% Repaid',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: primaryColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (loans.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Text(
                    'No active term loans.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Principal Repaid: ${AppFormat.currency(totalPaid)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    'Remaining Debt: ${AppFormat.currency(totalDebt)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: errorColor,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: overallProgress.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: context.onSurfaceOverlay(
                    lightOpacity: 0.12,
                    darkOpacity: 0.10,
                  ),
                  valueColor: AlwaysStoppedAnimation(primaryColor),
                ),
              ),
              const SizedBox(height: 12),

              // Individual loan rows
              ...loans.map(
                (loan) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          loan.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 140,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            '${(loan.progress * 100).toStringAsFixed(0)}% (${AppFormat.currency(loan.remainingPrincipal)} left)',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Revolving Credit Exposure (Current Outstanding & Limit Utilization).
class _RevolvingCreditExposureCard extends StatelessWidget {
  final List<CreditCardSummary> cards;
  final bool isDark;

  const _RevolvingCreditExposureCard({
    required this.cards,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalOutstanding = cards.fold<double>(0, (s, c) => s + c.outstanding);
    final totalLimit = cards.fold<double>(0, (s, c) => s + c.limit);
    final overallUtil = totalLimit > 0
        ? (totalOutstanding / totalLimit) * 100
        : 0.0;

    final utilColor = overallUtil >= 80
        ? cs.error
        : (overallUtil >= 50
              ? cs.tertiary
              : Theme.of(context).colorScheme.secondary);

    return SpendXGlassSurface(
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.credit_card_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Revolving Credit Exposure',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${overallUtil.toStringAsFixed(0)}% Used',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: utilColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (cards.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Text(
                    'No credit cards added.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Total Outstanding: ${AppFormat.currency(totalOutstanding)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.error,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    totalLimit > 0
                        ? 'Limit: ${AppFormat.currency(totalLimit)}'
                        : 'No limit set',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (overallUtil / 100).clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: context.onSurfaceOverlay(
                    lightOpacity: 0.12,
                    darkOpacity: 0.10,
                  ),
                  valueColor: AlwaysStoppedAnimation(utilColor),
                ),
              ),
              const SizedBox(height: 12),

              // Individual card rows
              ...cards.map(
                (card) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                card.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (card.daysLeft <= 5
                                            ? cs.error
                                            : cs.secondary)
                                        .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'Due in ${card.daysLeft}d',
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: card.daysLeft <= 5
                                      ? cs.error
                                      : cs.secondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 130,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            '${AppFormat.currency(card.outstanding)} (${card.utilPct.toStringAsFixed(0)}%)',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// 6. EXPORT TRANSACTIONS SHEET CONTENT (VERIFIED CSV & JSON ONLY)
// =========================================================================

class _ExportTransactionsSheetContent extends StatelessWidget {
  final int period;

  const _ExportTransactionsSheetContent({required this.period});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Export Raw Transactions',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Note: These actions export your underlying transaction records. They do not generate a consolidated visual PDF report.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),

          // Option 1: CSV Export
          _ExportOptionTile(
            icon: Icons.table_chart_outlined,
            title: 'Export Transactions (CSV)',
            subtitle: 'Spreadsheet-ready format for Excel or Google Sheets',
            isDark: isDark,
            onTap: () async {
              Navigator.pop(context);
              await ExportService.instance.exportTransactionsToCsv();
            },
          ),

          const SizedBox(height: 10),

          // Option 2: JSON Export
          _ExportOptionTile(
            icon: Icons.data_object_rounded,
            title: 'Export Transactions (JSON)',
            subtitle: 'Structured raw data format for software backups',
            isDark: isDark,
            onTap: () async {
              Navigator.pop(context);
              await ExportService.instance.exportTransactionsToJson();
            },
          ),
        ],
      ),
    );
  }
}

class _ExportOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isDark;
  final VoidCallback onTap;

  const _ExportOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title, $subtitle',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.onSurfaceOverlay(
            lightOpacity: 0.03,
            darkOpacity: 0.05,
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: context.borderColor,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.15)
                    : Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    ),
  ),
);
}
}
