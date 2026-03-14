import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../services/financial_health_service.dart';
import '../../services/database_helper.dart';
import '../../models/category.dart';
import '../../utils/app_format.dart';
import '../../theme/app_theme.dart';
import '../../widgets/animated_widgets.dart';
import 'package:spend_x/widgets/spendx_app_bar.dart';


import '../../widgets/custom_snackbar.dart';
import 'package:intl/intl.dart';

class MonthlyReportScreen extends StatefulWidget {
  const MonthlyReportScreen({super.key});

  @override
  State<MonthlyReportScreen> createState() => _MonthlyReportScreenState();
}

class _MonthlyReportScreenState extends State<MonthlyReportScreen> with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  Map<String, dynamic>? _reportData;
  Map<String, dynamic>? _healthData;
  double _prevHealthScore = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final startOfCurrentMonth = DateTime(now.year, now.month, 1);
      
      final summary = await FinancialHealthService.instance.getMonthlySummary(now);
      final health = await FinancialHealthService.instance.calculateFinancialHealthScore();
      
      final currentScore = (health['score'] as int).toDouble();
      
      // Auto-calculate historical net worth
      final historicalNW = await FinancialHealthService.instance.getHistoricalNetWorth(startOfCurrentMonth);
      
      // Calculate current NW for comparison
      final accounts = await DatabaseHelper.instance.getAllBankAccounts();
      final cards = await DatabaseHelper.instance.getAllCreditCards();
      final lendings = await DatabaseHelper.instance.getAllLendings(settledFilter: false);
      double assets = accounts.where((a) => a.isAsset).fold(0.0, (s, a) => s + a.balance);
      double liabilities = cards.fold(0.0, (s, c) => s + c.outstanding);
      liabilities += lendings.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + (l.originalAmount - l.paidAmount));
      final currentNW = assets - liabilities;

      final nwChange = currentNW - historicalNW;
      
      if (mounted) {
        setState(() {
          _reportData = summary;
          _healthData = health;
          // Map NW change to a score change proxy
          _prevHealthScore = currentScore - (nwChange / 5000); 
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        CustomSnackBar.show(context, message: 'Error loading report: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monthName = DateFormat('MMMM').format(now);

    return Scaffold(
      appBar: SpendXAppBar(
        title: '$monthName Report',
      ),

      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _reportData!['transactionCount'] == 0
              ? _buildEmptyState()
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(24),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          _buildMainGradientCard(monthName),
                          const SizedBox(height: 32),
                          _buildFinancialHealthChange(),
                          const SizedBox(height: 32),
                          const Text(
                            'Spending by Category',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 24),
                          _buildSpendingChart(),
                          const SizedBox(height: 32),
                          _buildInsights(),
                          const SizedBox(height: 40),
                        ]),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            'No transactions available for this month.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

    Widget _buildMainGradientCard(String monthName) {
    final income = _reportData!['income'] as double;
    final expenses = _reportData!['expenses'] as double;
    final savings = _reportData!['savings'] as double;
    final savingsRate = _reportData!['savingsRate'] as double;
    final score = (_healthData!['score'] as int).toDouble();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$monthName Summary',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text(
                        'Spend:',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(width: 8),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: expenses),
                        duration: const Duration(seconds: 1),
                        builder: (context, value, child) => Text(
                          AppFormat.currency(value),
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                width: 70,
                height: 70,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  shape: BoxShape.circle,
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: score / 100,
                      strokeWidth: 5,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: score),
                      duration: const Duration(seconds: 1),
                      builder: (context, value, child) => Text(
                        '${value.toInt()}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(color: Colors.white24, height: 1),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildCompactMetric('Income', income),
              _buildCompactMetric('Saved', savings),
              _buildCompactMetric('Rate', savingsRate, isPercentage: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMetric(String label, double value, {bool isPercentage = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value),
          duration: const Duration(seconds: 1),
          builder: (context, val, child) => Text(
            isPercentage ? '${val.toInt()}%' : AppFormat.currency(val),
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildFinancialHealthChange() {
    final currentScore = (_healthData!['score'] as int).toDouble();
    final diff = currentScore - _prevHealthScore;
    final isImproved = diff >= 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (isImproved ? Colors.green : Colors.red).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isImproved ? Icons.trending_up : Icons.trending_down,
              color: isImproved ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Financial Health', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  '${diff.abs().toInt()} points ${isImproved ? 'this month' : 'declined'}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                ),
              ],
            ),
          ),
          Text(
            '${isImproved ? '+' : '-'}${diff.abs().toInt()}',
            style: TextStyle(
              color: isImproved ? Colors.green : Colors.red,
              fontWeight: FontWeight.w600,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpendingChart() {
    final Map<String, double> categorySpending = _reportData!['categorySpending'];
    if (categorySpending.isEmpty) return const SizedBox.shrink();

    return FutureBuilder<List<Category>>(
      future: DatabaseHelper.instance.getAllCategories(),
      builder: (context, catSnapshot) {
        final Map<String, String> categoryNames = {};
        if (catSnapshot.hasData) {
          for (var c in catSnapshot.data!) {
            categoryNames[c.id] = c.name;
          }
        }

        final sortedEntries = categorySpending.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        
        final displayEntries = sortedEntries.take(5).toList();

        return SizedBox(
          height: 240,
          child: Column(
            children: [
              Expanded(
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceEvenly,
                    maxY: (displayEntries.isNotEmpty ? displayEntries.first.value : 1.0) * 1.3,
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => Theme.of(context).colorScheme.surfaceContainerHigh,
                        tooltipBorder: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          return BarTooltipItem(
                            AppFormat.currency(rod.toY),
                            TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      show: true,
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 32,
                          getTitlesWidget: (value, meta) {
                            if (value.toInt() >= 0 && value.toInt() < displayEntries.length) {
                              final id = displayEntries[value.toInt()].key;
                              final name = categoryNames[id] ?? id;
                              return Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  name,
                                  style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }
                            return const Text('');
                          },
                        ),
                      ),
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    barGroups: displayEntries.asMap().entries.map((e) {
                      return BarChartGroupData(
                        x: e.key,
                        barRods: [
                          BarChartRodData(
                            toY: e.value.value,
                            color: Theme.of(context).colorScheme.primary,
                            width: 20,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInsights() {
    final comparison = _reportData!['comparison'] as Map<String, dynamic>;
    final expenseChange = comparison['expenseChange'] as double;
    final txnCount = _reportData!['transactionCount'] as int;

    String insight = "You logged $txnCount transactions this month.";
    if (expenseChange != 0) {
      insight = 'You spent ${expenseChange.abs().toStringAsFixed(1)}% ${expenseChange > 0 ? 'more' : 'less'} than last month.';
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline, color: Theme.of(context).colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              const Text('Spending Insights', style: TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 16),
          _insightRow(insight),
          const SizedBox(height: 12),
          _insightRow('Your savings rate is ${(_reportData!['savingsRate'] as double).toStringAsFixed(1)}%.'),
        ],
      ),
    );
  }

  Widget _insightRow(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(width: 6, height: 6, decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4))),
      ],
    );
  }
}
