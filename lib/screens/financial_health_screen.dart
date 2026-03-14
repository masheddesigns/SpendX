import 'package:flutter/material.dart';
import '../services/financial_health_service.dart';
import '../widgets/animated_widgets.dart';

class FinancialHealthScreen extends StatelessWidget {
  const FinancialHealthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial Health'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: FutureBuilder<Map<String, double>>(
        future: FinancialHealthService.instance.calculateMetrics(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final metrics = snapshot.data!;
          final score = FinancialHealthService.instance.calculateTotalScore(metrics);
          final status = FinancialHealthService.instance.getScoreStatus(score);
          final color = _getStatusColor(score, context);

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Column(
                    children: [
                      _buildScoreCircle(score, color, context),
                      const SizedBox(height: 16),
                      Text(
                        status,
                        style: TextStyle(
                          color: color,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your financial discipline score',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 48),
                Text(
                  'BREAKDOWN',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                _buildMetricRow('Savings Rate', metrics['savingsRate'] ?? 0, Colors.green, context),
                _buildMetricRow('Debt Ratio', metrics['debtRatio'] ?? 0, Colors.blue, context),
                _buildMetricRow('Expense Discipline', metrics['expenseDiscipline'] ?? 0, Colors.orange, context),
                _buildMetricRow('Consistency', metrics['consistency'] ?? 0, Colors.purple, context),
                _buildMetricRow('Asset Growth', metrics['assetGrowth'] ?? 0, Colors.teal, context),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildScoreCircle(double score, Color color, BuildContext context) {
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withOpacity(0.2), width: 12),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CountUpText(
              value: score,
              style: const TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '/ 100',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, double value, Color color, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${(value * 100).toInt()}%', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 10,
              backgroundColor: color.withOpacity(0.1),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(double score, BuildContext context) {
    if (score < 40) return Colors.red;
    if (score < 70) return Colors.orange;
    if (score < 85) return Colors.green;
    return Colors.greenAccent;
  }
}
