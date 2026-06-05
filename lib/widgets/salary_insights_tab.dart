import 'package:flutter/material.dart';

import '../models/company.dart';
import '../models/salary_contract.dart';
import '../services/salary_insights_service.dart';
import '../utils/app_format.dart';

class SalaryInsightsTab extends StatefulWidget {
  const SalaryInsightsTab({
    super.key,
    required this.company,
    required this.contract,
  });

  final Company company;
  final SalaryContract contract;

  @override
  State<SalaryInsightsTab> createState() => _SalaryInsightsTabState();
}

class _SalaryInsightsTabState extends State<SalaryInsightsTab> {
  late Future<_InsightsBundle> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(widget.company, widget.contract);
  }

  @override
  void didUpdateWidget(covariant SalaryInsightsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.company != widget.company || oldWidget.contract != widget.contract) {
      _future = _load(widget.company, widget.contract);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_InsightsBundle>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final data = snapshot.data!;
        return Column(
          children: [
            _InsightCard(
              title: 'Overview',
              lines: [
                '${AppFormat.currency(data.summary.totalEarned)} earned',
                '${AppFormat.currency(data.summary.totalPending)} pending',
              ],
            ),
            const SizedBox(height: 12),
            _InsightCard(
              title: 'Growth',
              lines: [
                '${AppFormat.currency(data.growth.baseSalary)} -> ${AppFormat.currency(data.growth.currentSalary)}',
                '${data.growth.growthPercent >= 0 ? '+' : ''}${data.growth.growthPercent.toStringAsFixed(0)}%',
              ],
            ),
            const SizedBox(height: 12),
            _InsightCard(
              title: 'Reliability',
              lines: [
                '${data.reliability.score.toStringAsFixed(0)}% Score',
                '${data.reliability.delayCount} delays, ${data.reliability.partialCount} partial months',
              ],
            ),
            const SizedBox(height: 12),
            _InsightCard(
              title: 'Delay Pattern',
              lines: [
                'Avg delay: ${data.delay.averageDelayDays.toStringAsFixed(1)} days',
                'Worst: ${data.delay.mostDelayedMonth} (${data.delay.maxDelayDays} days)',
              ],
            ),
            const SizedBox(height: 12),
            _InsightCard(
              title: 'Increment Timeline',
              lines: data.timeline
                  .map(
                    (item) =>
                        '${item.label}  ${AppFormat.currency(item.amount)}',
                  )
                  .toList(),
            ),
          ],
        );
      },
    );
  }

  Future<_InsightsBundle> _load(
    Company company,
    SalaryContract contract,
  ) async {
    final service = SalaryInsightsService.instance;
    return _InsightsBundle(
      summary: await service.getSalarySummary(company),
      growth: await service.getSalaryGrowth(contract, company),
      reliability: await service.getSalaryReliability(company),
      delay: await service.getDelayStats(company),
      timeline: await service.getIncrementTimeline(company),
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF243145)),
        boxShadow: const [
          BoxShadow(color: Color(0x2218C98F), blurRadius: 18, spreadRadius: 0),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                line,
                style: const TextStyle(
                  color: Color(0xFFB8C3D8),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightsBundle {
  const _InsightsBundle({
    required this.summary,
    required this.growth,
    required this.reliability,
    required this.delay,
    required this.timeline,
  });

  final SalaryOverviewInsight summary;
  final SalaryGrowthInsight growth;
  final SalaryReliabilityInsight reliability;
  final SalaryDelayInsight delay;
  final List<IncrementTimelineItem> timeline;
}
