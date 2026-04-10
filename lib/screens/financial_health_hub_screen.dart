import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/providers.dart';
import 'package:fl_chart/fl_chart.dart';

class FinancialHealthHubScreen extends ConsumerStatefulWidget {
  const FinancialHealthHubScreen({super.key});

  @override
  ConsumerState<FinancialHealthHubScreen> createState() => _FinancialHealthHubScreenState();
}

class _FinancialHealthHubScreenState extends ConsumerState<FinancialHealthHubScreen> {
  bool _isLoading = true;
  double _score = 0;
  String _status = '';
  Map<String, double> _metrics = {};
  List<FlSpot> _nwTrend = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final service = ref.read(financialHealthServiceProvider);
    final health = await service.calculateFinancialHealthScore();
    
    // Load last 6 months NW trend
    List<FlSpot> trend = [];
    for (int i = 5; i >= 0; i--) {
      final date = DateTime(DateTime.now().year, DateTime.now().month - i, 1);
      final nw = await service.getHistoricalNetWorth(date);
      trend.add(FlSpot((5 - i).toDouble(), nw / 1000)); // NW in K for easier display
    }

    if (mounted) {
      setState(() {
        _score = (health['score'] as num).toDouble();
        _status = health['status'] as String;
        _metrics = health['breakdown'] as Map<String, double>;
        _nwTrend = trend;
        _isLoading = false;
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial Health Details'),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // --- Score Overview ---
                _buildScoreOverview(cs),

                const SizedBox(height: 32),

                // --- Net Worth Trend ---
                 Text(
                  'Net Worth Trend (6mo)',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 16),
                _buildNetWorthChart(cs),

                const SizedBox(height: 32),

                // --- Breakdown ---
                Text(
                  'Metric Breakdown',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 16),
                ..._buildBreakdownList(cs),
              ],
            ),
    );
  }

  Widget _buildScoreOverview(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primary, cs.primaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Text(
            '$_score'.split('.').first,
            style: const TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          Text(
            _status.toUpperCase(),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Colors.white70,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Your score is based on savings rate, debt ratio, discipline, consistency, and asset growth.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildNetWorthChart(ColorScheme cs) {
    return Container(
      height: 200,
      padding: const EdgeInsets.only(top: 20, right: 20, left: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: _nwTrend,
              isCurved: true,
              color: cs.primary,
              barWidth: 4,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: cs.primary.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBreakdownList(ColorScheme cs) {
    final labels = {
      'savingsRate': 'Savings Rate',
      'debtRatio': 'Debt Ratio',
      'expenseDiscipline': 'Expense Discipline',
      'consistency': 'Logging Consistency',
      'assetGrowth': 'Asset Growth',
    };

    return _metrics.entries.map((e) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    labels[e.key] ?? e.key,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: e.value,
                      minHeight: 6,
                      backgroundColor: cs.outlineVariant.withValues(alpha: 0.2),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        e.value > 0.7 ? Colors.green : e.value > 0.4 ? Colors.orange : Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Text(
              '${(e.value * 100).toInt()}%',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }).toList();
  }
}
