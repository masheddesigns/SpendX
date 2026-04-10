import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../salary_ledger/salary_ledger_notifier.dart';

class SalaryAnalyticsCard extends ConsumerWidget {
  const SalaryAnalyticsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(salaryReportProvider);
    final months = ref.watch(
      salaryLedgerProvider.select((s) => s.valueOrNull?.months ?? []),
    );

    if (months.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Monthly Trend',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            SizedBox(
              height: 180,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: false),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i < 0 || i >= months.length) {
                            return const SizedBox.shrink();
                          }
                          final short = months[i].month.month.split('-').last;
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(short,
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 10)),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: months.asMap().entries.map((e) {
                        return FlSpot(
                            e.key.toDouble(), e.value.totalPaid);
                      }).toList(),
                      isCurved: true,
                      color: Colors.blueAccent,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) =>
                            FlDotCirclePainter(
                          radius: 4,
                          color: Colors.blueAccent,
                          strokeWidth: 2,
                          strokeColor: Colors.black,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blueAccent.withValues(alpha: 0.12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Paid vs Pending',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            SizedBox(
              height: 140,
              child: BarChart(
                BarChartData(
                  gridData: FlGridData(show: false),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i < 0 || i >= months.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                                months[i].month.month.split('-').last,
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 10)),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  barGroups: months.asMap().entries.map((e) {
                    final m = e.value;
                    return BarChartGroupData(
                      x: e.key,
                      barRods: [
                        BarChartRodData(
                          toY: m.totalPaid,
                          color: Colors.greenAccent,
                          width: 8,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        BarChartRodData(
                          toY: m.remaining,
                          color: Colors.orangeAccent,
                          width: 8,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
            if (report.delayedCount > 0) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.redAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${report.delayedCount} delayed payment${report.delayedCount > 1 ? 's' : ''} '
                        'averaging ${report.avgDelay.toStringAsFixed(1)} days late.',
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12),
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
