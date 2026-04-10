import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../providers/vehicle_providers.dart';
import '../../../models/vehicle.dart';
import '../../../models/transaction.dart' as spx;
import '../../../utils/app_format.dart';

class VehicleReportScreen extends ConsumerWidget {
  final Vehicle vehicle;
  const VehicleReportScreen({super.key, required this.vehicle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(vehicleDetailProvider(vehicle));

    return Scaffold(
      appBar: AppBar(
        title: Text('${vehicle.name} Report'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: detailAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, stack) => Center(child: Text('Error: $err')),
          data: (data) {
            final total = data.totalFuelCost + data.totalOtherCost;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummaryCard(context, data, total),
                  const SizedBox(height: 24),
                  if (total > 0) ...[
                    _buildCostBreakdownChart(context, data),
                    const SizedBox(height: 24),
                  ],
                  _buildSectionTitle(context, 'Cost Breakdown'),
                  _buildBreakdownItem(context, 'Fuel Expenses', data.totalFuelCost, Theme.of(context).colorScheme.secondary, Icons.local_gas_station),
                  _buildBreakdownItem(context, 'Maintenance & Others', data.totalOtherCost, Theme.of(context).colorScheme.primary, Icons.build),
                  const SizedBox(height: 32),
                  _buildSectionTitle(context, 'Recent Activity'),
                  _buildActivityList(context, data),
                  const SizedBox(height: 80),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, VehicleDetailData data, double total) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primary.withValues(alpha: 0.8), cs.primary.withValues(alpha: 0.4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: cs.primary.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        children: [
          Text('Total Ownership Cost', style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.7), fontSize: 14, decoration: TextDecoration.none)),
          const SizedBox(height: 8),
          Text(AppFormat.currency(total), 
            style: TextStyle(color: cs.onPrimary, fontSize: 32, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _miniStat(context, 'Fuel', AppFormat.currency(data.totalFuelCost)),
              Container(width: 1, height: 20, color: cs.onPrimary.withValues(alpha: 0.2), margin: const EdgeInsets.symmetric(horizontal: 20)),
              _miniStat(context, 'Other', AppFormat.currency(data.totalOtherCost)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(BuildContext context, String label, String val) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(val, style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
        Text(label, style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.6), fontSize: 11, decoration: TextDecoration.none)),
      ],
    );
  }

  Widget _buildCostBreakdownChart(BuildContext context, VehicleDetailData data) {
    final total = data.totalFuelCost + data.totalOtherCost;
    if (total <= 0) return const SizedBox.shrink();

    return Container(
      height: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: PieChart(
        PieChartData(
          sectionsSpace: 4,
          centerSpaceRadius: 40,
          sections: [
            if (data.totalFuelCost > 0)
              PieChartSectionData(
                value: data.totalFuelCost,
                color: Theme.of(context).colorScheme.secondary,
                title: '${((data.totalFuelCost / total) * 100).toStringAsFixed(0)}%',
                radius: 50,
                titleStyle: TextStyle(decoration: TextDecoration.none, fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSecondary),
              ),
            if (data.totalOtherCost > 0)
              PieChartSectionData(
                value: data.totalOtherCost,
                color: Theme.of(context).colorScheme.primary,
                title: '${((data.totalOtherCost / total) * 100).toStringAsFixed(0)}%',
                radius: 50,
                titleStyle: TextStyle(decoration: TextDecoration.none, fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onPrimary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface, decoration: TextDecoration.none)),
  );

  Widget _buildBreakdownItem(BuildContext context, String label, double amount, Color color, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          CircleAvatar(backgroundColor: color.withValues(alpha: 0.1), child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, decoration: TextDecoration.none))),
          Text(AppFormat.currency(amount), style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
        ],
      ),
    );
  }

  Widget _buildActivityList(BuildContext context, VehicleDetailData data) {
    final List<dynamic> combined = [...data.logs, ...data.otherExpenses];
    combined.sort((a, b) {
      final dateA = a is FuelLog ? a.date : (a as spx.Transaction).date;
      final dateB = b is FuelLog ? b.date : (b as spx.Transaction).date;
      return dateB.compareTo(dateA);
    });

    if (combined.isEmpty) {
      return Center(child: Text('No activity recorded', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, decoration: TextDecoration.none)));
    }

    return Column(
      children: combined.take(20).map((item) {
        if (item is FuelLog) {
          return _activityTile(
            context,
            icon: Icons.local_gas_station,
            color: Theme.of(context).colorScheme.secondary,
            title: 'Fuel Fill-up (${item.litres.toStringAsFixed(1)}L)',
            date: item.date,
            amount: item.totalCost,
          );
        } else {
          final t = item as spx.Transaction;
          return _activityTile(
            context,
            icon: Icons.build,
            color: Theme.of(context).colorScheme.primary,
            title: t.notes.isEmpty ? 'Vehicle Expense' : t.notes,
            date: t.date,
            amount: t.amount,
          );
        }
      }).toList(),
    );
  }

  Widget _activityTile(BuildContext context, {required IconData icon, required Color color, required String title, required DateTime date, required double amount}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.1), child: Icon(icon, color: color, size: 18)),
      title: Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14, decoration: TextDecoration.none)),
      subtitle: Text(DateFormat('dd MMM yyyy').format(date), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, decoration: TextDecoration.none)),
      trailing: Text(AppFormat.currency(amount), style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
    );
  }
}
