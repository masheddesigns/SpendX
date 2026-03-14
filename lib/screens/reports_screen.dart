import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/database_helper.dart';
import '../utils/app_format.dart';
import '../theme/app_theme.dart';
import '../widgets/spendx_app_bar.dart';

import 'reports/monthly_report_screen.dart';

/// Full financial reports screen with tabs: Overview (income/expense), Credit, Fuel
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  late AnimationController _chartAnimationController;
  late Animation<double> _chartAnimation;
  bool _isLoading = true;
  String _period = 'monthly'; // 'monthly' or 'yearly'

  // Overview data
  List<_MonthData> _monthlyData = [];
  double _totalIncome = 0;
  double _totalExpense = 0;

  // Credit data
  List<_CreditCardSummary> _creditSummaries = [];

  // Fuel data
  List<_FuelMonthData> _fuelMonthData = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });

    _chartAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _chartAnimation = CurvedAnimation(
      parent: _chartAnimationController,
      curve: Curves.easeOutCubic,
    );

    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _chartAnimationController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    _chartAnimationController.reset();
    try {
      await Future.wait([_loadOverviewData(), _loadCreditData(), _loadVehicleData()]);
      _chartAnimationController.forward();
    } catch (e) {
      debugPrint('ReportsScreen load error: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadOverviewData() async {
    final monthsBack = _period == 'yearly' ? 12 : 6;
    final stats = await DatabaseHelper.instance.getMonthlyStats(monthsBack);
    
    double inc = 0, exp = 0;
    List<_MonthData> monthlyData = [];

    // Monthly stats are already grouped and summed by SQL
    for (var s in stats.reversed) {
      final monthStr = s['month'] as String; // YYYY-MM
      final dateTime = DateTime.parse('$monthStr-01');
      final label = DateFormat('MMM yy').format(dateTime);
      final income = (s['income'] as num).toDouble();
      final expense = (s['expense'] as num).toDouble();
      
      monthlyData.add(_MonthData(label: label, income: income, expense: expense));
      inc += income;
      exp += expense;
    }

    if (mounted) {
      setState(() {
        _monthlyData = monthlyData;
        _totalIncome = inc;
        _totalExpense = exp;
      });
    }
  }

  Future<void> _loadCreditData() async {
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    _creditSummaries = cards.map((c) => _CreditCardSummary(
      name: '${c.bank} ${c.last4}',
      outstanding: c.outstanding,
      limit: c.creditLimit,
      utilPct: c.utilizationPct,
      daysLeft: c.daysUntilDue,
    )).toList();
  }

  Future<void> _loadVehicleData() async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now();
    final monthVehicleMap = <String, double>{};
    for (int i = 5; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i, 1);
      monthVehicleMap[DateFormat('MMM yy').format(m)] = 0;
    }
    
    // Add fuel costs
    final fuel = await db.query(DatabaseHelper.tableFuelLogs, orderBy: 'date ASC');
    for (final f in fuel) {
      final date = DateTime.tryParse(f['date'] as String? ?? '');
      if (date == null) continue;
      final key = DateFormat('MMM yy').format(date);
      if (!monthVehicleMap.containsKey(key)) continue;
      monthVehicleMap[key] = (monthVehicleMap[key]! + (f['total_cost'] as num).toDouble());
    }

    // Add other vehicle-linked expenses
    final other = await db.query('transactions', where: 'vehicle_id IS NOT NULL', orderBy: 'date ASC');
    for (final o in other) {
      final date = DateTime.tryParse(o['date'] as String? ?? '');
      if (date == null) continue;
      final key = DateFormat('MMM yy').format(date);
      if (!monthVehicleMap.containsKey(key)) continue;
      monthVehicleMap[key] = (monthVehicleMap[key]! + (o['amount'] as num).toDouble());
    }

    _fuelMonthData = monthVehicleMap.entries.map((e) => _FuelMonthData(label: e.key, cost: e.value)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Reports',

        bottom: TabBar(
          controller: _tabController,
          indicatorWeight: 3,
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Credit'),
            Tab(text: 'Vehicles'),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            icon: const Icon(Icons.tune),
            onSelected: (v) { setState(() => _period = v); _loadData(); },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'monthly', child: Text(_period == 'monthly' ? '✓ Last 6 Months' : 'Last 6 Months')),
              PopupMenuItem(value: 'yearly', child: Text(_period == 'yearly' ? '✓ Last 12 Months' : 'Last 12 Months')),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildOverviewTab(),
                _buildCreditTab(),
                _buildVehicleTab(),
              ],
            ),
    );
  }

  // ─── OVERVIEW TAB ─────────────────────────────────────────────────────────

  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Summary row
        Row(children: [
          Expanded(child: _summaryCard('Total Income', AppFormat.currency(_totalIncome), Theme.of(context).colorScheme.primary, Icons.trending_up)),
          const SizedBox(width: 10),
          Expanded(child: _summaryCard('Total Expense', AppFormat.currency(_totalExpense), Theme.of(context).colorScheme.error, Icons.trending_down)),
        ]),
        const SizedBox(height: 10),
        _buildNetSavingsCard(),
        const SizedBox(height: 24),

        _sectionLabel('Income vs Expense'),
        const SizedBox(height: 12),
        _buildIncomeExpenseBarChart(),
        const SizedBox(height: 24),

        _sectionLabel('Monthly Net'),
        const SizedBox(height: 12),
        _buildNetLineIndicators(),
        const SizedBox(height: 24),

        // Link to Detailed Monthly Report
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Icon(Icons.analytics_outlined, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Detailed Monthly Analysis', style: TextStyle(fontWeight: FontWeight.w600)),
                    Text('View deep insights for ${DateFormat('MMMM').format(DateTime.now())}', 
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MonthlyReportScreen())),
                icon: const Icon(Icons.arrow_forward_ios, size: 16),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
      ]),
    );
  }

  Widget _buildIncomeExpenseBarChart() {
    if (_monthlyData.isEmpty) return _emptyChart('No transactions yet');
    final maxVal = _monthlyData.fold<double>(0.0, (m, d) => [m, d.income, d.expense].reduce((a, b) => a > b ? a : b));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _legend(Theme.of(context).colorScheme.primary, 'Income'),
          const SizedBox(width: 16),
          _legend(Theme.of(context).colorScheme.error, 'Expense'),
        ]),

        const SizedBox(height: 16),
        SizedBox(
          height: 200,
          child: AnimatedBuilder(
            animation: _chartAnimation,
            builder: (context, child) {
              return BarChart(BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxVal * 1.2,
                barTouchData: BarTouchData(enabled: true),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= _monthlyData.length) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_monthlyData[i].label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w600)),
                      );
                    },
                  )),
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1))),
                borderData: FlBorderData(show: false),
                barGroups: _monthlyData.asMap().map((i, d) => MapEntry(i, BarChartGroupData(
                  x: i,
                  barsSpace: 8, // More space between bars in a group
                  barRods: [
                    BarChartRodData(
                      toY: d.income * _chartAnimation.value, 
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
                      width: 14, // Slightly wider rods
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                    ),
                    BarChartRodData(
                      toY: d.expense * _chartAnimation.value, 
                      color: Theme.of(context).colorScheme.error.withValues(alpha: 0.9),
                      width: 14, // Slightly wider rods
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                    ),

                  ],
                ))).values.toList(),
              ));
            },
          ),
        ),
      ]),
    );
  }

  Widget _buildNetLineIndicators() {
    return Column(children: _monthlyData.map((d) {
      final net = d.income - d.expense;
      final isPositive = net >= 0;
      final color = isPositive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error;
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(children: [
          Text(d.label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13, fontWeight: FontWeight.w500)),
          const Spacer(),
          Icon(isPositive ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: color),
          const SizedBox(width: 4),
          Text(AppFormat.currency(net.abs()), style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      );
    }).toList());
  }

  // ─── CREDIT TAB ────────────────────────────────────────────────────────────

  Widget _buildCreditTab() {
    if (_creditSummaries.isEmpty) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.credit_card_off, size: 60, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('No credit cards added yet', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 16)),
        ]),
      ));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionLabel('Outstanding per Card'),
        const SizedBox(height: 12),
        _buildCreditBarChart(),
        const SizedBox(height: 24),

        _sectionLabel('Card Details'),
        const SizedBox(height: 12),
        ..._creditSummaries.map(_buildCreditDetailCard),
        const SizedBox(height: 40),
      ]),
    );
  }

  Widget _buildCreditBarChart() {
    final maxOutstanding = _creditSummaries.fold<double>(0.0, (m, c) => m > c.outstanding ? m : c.outstanding);
    if (maxOutstanding == 0) return _emptyChart('No outstanding dues');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        height: 180,
        child: AnimatedBuilder(
          animation: _chartAnimation,
          builder: (context, child) {
            return BarChart(BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxOutstanding * 1.2,
              barTouchData: BarTouchData(enabled: true),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
                    if (i < 0 || i >= _creditSummaries.length) return const SizedBox.shrink();
                    final parts = _creditSummaries[i].name.split(' ');
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(parts.first, style: const TextStyle(color: Colors.grey, fontSize: 9)),
                    );
                  },
                )),
                leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10)),
              borderData: FlBorderData(show: false),
              barGroups: _creditSummaries.asMap().map((i, c) => MapEntry(i, BarChartGroupData(
                x: i,
                barRods: [BarChartRodData(
                  toY: c.outstanding * _chartAnimation.value,
                  gradient: LinearGradient(colors: [Theme.of(context).colorScheme.error, Theme.of(context).colorScheme.error.withValues(alpha: 0.6)], begin: Alignment.bottomCenter, end: Alignment.topCenter),
                  width: 20,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                )],
              ))).values.toList(),
            ));
          },
        ),
      ),
    );
  }

  Widget _buildCreditDetailCard(_CreditCardSummary c) {
    final utilColor = c.utilPct >= 80 ? Colors.red : c.utilPct >= 50 ? Colors.orange : Colors.green;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(c.name, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 14)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: (c.daysLeft <= 5 ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.secondary).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('Due in ${c.daysLeft}d', style: TextStyle(color: c.daysLeft <= 5 ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.secondary, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (c.utilPct / 100).clamp(0.0, 1.0),
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation(utilColor),
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Outstanding: ${AppFormat.currency(c.outstanding)}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
          Text('${c.utilPct.toStringAsFixed(0)}% used', style: TextStyle(color: utilColor, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }

  // ─── FUEL TAB ──────────────────────────────────────────────────────────────

  Widget _buildVehicleTab() {
    final hasData = _fuelMonthData.any((d) => d.cost > 0);
    if (!hasData) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.directions_car, size: 60, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('No vehicle data yet', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 16)),
        ]),
      ));
    }

    final totalSpend = _fuelMonthData.fold<double>(0, (s, d) => s + d.cost);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _summaryCard('Total Vehicle Spend (6M)', AppFormat.currency(totalSpend), Colors.orange, Icons.directions_car),
        const SizedBox(height: 20),
        _sectionLabel('Monthly Vehicle Costs'),
        const SizedBox(height: 12),
        _buildFuelBarChart(),
        const SizedBox(height: 20),
        ..._fuelMonthData.where((d) => d.cost > 0).map((d) => Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            Icon(Icons.directions_car, color: Theme.of(context).colorScheme.secondary, size: 16),
            const SizedBox(width: 8),
            Text(d.label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13)),
            const Spacer(),
            Text(AppFormat.currency(d.cost), style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        )),
        const SizedBox(height: 40),
      ]),
    );
  }

  Widget _buildFuelBarChart() {
    final maxVal = _fuelMonthData.fold<double>(0, (m, d) => m > d.cost ? m : d.cost);
    if (maxVal == 0) return _emptyChart('No fuel data');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        height: 160,
        child: AnimatedBuilder(
          animation: _chartAnimation,
          builder: (context, child) {
            return BarChart(BarChartData(
              maxY: maxVal * 1.2,
              alignment: BarChartAlignment.spaceAround,
              barTouchData: BarTouchData(enabled: true),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
                    if (i < 0 || i >= _fuelMonthData.length) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(_fuelMonthData[i].label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 9)),
                    );
                  },
                )),
                leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10)),
              borderData: FlBorderData(show: false),
              barGroups: _fuelMonthData.asMap().map((i, d) => MapEntry(i, BarChartGroupData(
                x: i,
                barRods: [BarChartRodData(
                  toY: d.cost * _chartAnimation.value,
                  gradient: const LinearGradient(colors: [Colors.orange, Colors.deepOrange], begin: Alignment.bottomCenter, end: Alignment.topCenter),
                  width: 18,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                )],
              ))).values.toList(),
            ));
          },
        ),
      ),
    );
  }

  // ─── HELPERS ───────────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Text(
    text,
    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2),
  );

  Widget _buildNetSavingsCard() {
    final netSavings = _totalIncome - _totalExpense;
    final isPositive = netSavings >= 0;
    final color = isPositive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error;

    // Calculate percentage change from previous month
    double pctChange = 0;
    if (_monthlyData.length >= 2) {
      final lastMonth = _monthlyData[_monthlyData.length - 2];
      final lastNet = lastMonth.income - lastMonth.expense;
      if (lastNet != 0) {
        pctChange = ((netSavings - lastNet) / lastNet.abs()) * 100;
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24), // Increased padding
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.2), color.withValues(alpha: 0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20), // Larger radius
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.savings, color: color, size: 32), // Larger icon
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Net Savings',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  AppFormat.currency(netSavings),
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 24, // Larger font
                  ),
                ),
                if (pctChange != 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        pctChange > 0 ? Icons.trending_up : Icons.trending_down,
                        size: 16,
                        color: pctChange > 0 ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${pctChange > 0 ? '+' : ''}${pctChange.toStringAsFixed(1)}% from last month',
                        style: TextStyle(
                          color: pctChange > 0 ? Colors.green : Colors.red,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(String title, String value, Color color, IconData icon) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 0),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.05)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 17)),
        ])),
      ]),
    );
  }

  Widget _legend(Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 5),
    Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
  ]);

  Widget _emptyChart(String msg) => Container(
    height: 160,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(20)),
    child: Text(msg, style: const TextStyle(color: Colors.grey)),
  );
}

class _MonthData {
  final String label;
  double income;
  double expense;
  _MonthData({required this.label, required this.income, required this.expense});
}

class _CreditCardSummary {
  final String name;
  final double outstanding;
  final double limit;
  final double utilPct;
  final int daysLeft;
  const _CreditCardSummary({required this.name, required this.outstanding, required this.limit, required this.utilPct, required this.daysLeft});
}

class _FuelMonthData {
  final String label;
  final double cost;
  const _FuelMonthData({required this.label, required this.cost});
}
