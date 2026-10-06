import 'package:flutter/material.dart';

import '../../services/financial_health_service.dart';
import '../../utils/app_format.dart';
import '../../shared/widgets/glass/spendx_scaffold.dart';
import '../../shared/widgets/glass/spendx_glass_surface.dart';
import '../../shared/widgets/spendx_app_bar.dart';

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
    return SpendXScaffold(
      appBar: const SpendXAppBar(title: 'Monthly Report'),
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
                  color: Colors.green,
                  icon: Icons.trending_up,
                ),
                _MetricCard(
                  label: 'Expenses',
                  value: AppFormat.currency(
                    (_summary?['expenses'] as num?)?.toDouble() ?? 0,
                  ),
                  color: Theme.of(context).colorScheme.error,
                  icon: Icons.trending_down,
                ),
                _MetricCard(
                  label: 'Savings',
                  value: AppFormat.currency(
                    (_summary?['savings'] as num?)?.toDouble() ?? 0,
                  ),
                  color: Theme.of(context).colorScheme.primary,
                  icon: Icons.savings_outlined,
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
    required this.color,
    required this.icon,
  });

  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SpendXGlassSurface(
        level: SpendXGlassLevel.base,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 14),
              Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
              ),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
