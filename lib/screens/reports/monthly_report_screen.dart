import 'package:flutter/material.dart';

import '../../services/financial_health_service.dart';
import '../../utils/app_format.dart';

class MonthlyReportScreen extends StatefulWidget {
  const MonthlyReportScreen({super.key});

  @override
  State<MonthlyReportScreen> createState() => _MonthlyReportScreenState();
}

class _MonthlyReportScreenState extends State<MonthlyReportScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final summary = await FinancialHealthService.instance.getMonthlySummary(
      DateTime.now(),
    );
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monthly Report')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _MetricCard(
                  label: 'Income',
                  value: AppFormat.currency(
                    (_summary?['income'] as num?)?.toDouble() ?? 0,
                  ),
                ),
                _MetricCard(
                  label: 'Expenses',
                  value: AppFormat.currency(
                    (_summary?['expenses'] as num?)?.toDouble() ?? 0,
                  ),
                ),
                _MetricCard(
                  label: 'Savings',
                  value: AppFormat.currency(
                    (_summary?['savings'] as num?)?.toDouble() ?? 0,
                  ),
                ),
              ],
            ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(label),
        trailing: Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
