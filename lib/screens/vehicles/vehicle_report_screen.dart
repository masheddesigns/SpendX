import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../models/vehicle.dart';
import '../../models/transaction.dart' as spx;
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';

class VehicleReportScreen extends StatefulWidget {
  final Vehicle vehicle;
  const VehicleReportScreen({super.key, required this.vehicle});

  @override
  State<VehicleReportScreen> createState() => _VehicleReportScreenState();
}

class _VehicleReportScreenState extends State<VehicleReportScreen> {
  bool _isLoading = true;
  List<FuelLog> _fuelLogs = [];
  List<spx.Transaction> _otherExpenses = [];
  
  double _totalFuel = 0;
  double _totalOther = 0;
  
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final logs = await DatabaseHelper.instance.getFuelLogsForVehicle(widget.vehicle.id);
    final other = await DatabaseHelper.instance.getTransactionsForVehicle(widget.vehicle.id);
    
    double fuelSum = logs.fold(0, (sum, item) => sum + item.totalCost);
    double otherSum = other.fold(0, (sum, item) => sum + item.amount);

    if (mounted) {
      setState(() {
        _fuelLogs = logs;
        _otherExpenses = other;
        _totalFuel = fuelSum;
        _totalOther = otherSum;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _totalFuel + _totalOther;
    
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.vehicle.name} Report'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummaryCard(total),
                  const SizedBox(height: 24),
                  if (total > 0) ...[
                    _buildCostBreakdownChart(),
                    const SizedBox(height: 24),
                  ],
                  _buildSectionTitle('Cost Breakdown'),
                  _buildBreakdownItem('Fuel Expenses', _totalFuel, Theme.of(context).colorScheme.secondary, Icons.local_gas_station),
                  _buildBreakdownItem('Maintenance & Others', _totalOther, Theme.of(context).colorScheme.primary, Icons.build),
                  const SizedBox(height: 32),
                  _buildSectionTitle('Recent Activity'),
                  _buildActivityList(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
    );
  }

  Widget _buildSummaryCard(double total) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.8), Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        children: [
          Text('Total Ownership Cost', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7), fontSize: 14)),
          const SizedBox(height: 8),
          Text(AppFormat.currency(total), 
            style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 32, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _miniStat(context, 'Fuel', AppFormat.currency(_totalFuel)),
              Container(width: 1, height: 20, color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.2), margin: const EdgeInsets.symmetric(horizontal: 20)),
              _miniStat(context, 'Other', AppFormat.currency(_totalOther)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(BuildContext context, String label, String val) => Column(
    children: [
      Text(val, style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.w600)),
      Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.6), fontSize: 11)),
    ],
  );

  Widget _buildCostBreakdownChart() {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: PieChart(
        PieChartData(
          sectionsSpace: 4,
          centerSpaceRadius: 40,
          sections: [
            if (_totalFuel > 0)
              PieChartSectionData(
                value: _totalFuel,
                color: Theme.of(context).colorScheme.secondary,
                title: '${((_totalFuel / (_totalFuel + _totalOther)) * 100).toStringAsFixed(0)}%',
                radius: 50,
                titleStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSecondary),
              ),
            if (_totalOther > 0)
              PieChartSectionData(
                value: _totalOther,
                color: Theme.of(context).colorScheme.primary,
                title: '${((_totalOther / (_totalFuel + _totalOther)) * 100).toStringAsFixed(0)}%',
                radius: 50,
                titleStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onPrimary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
  );

  Widget _buildBreakdownItem(String label, double amount, Color color, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          CircleAvatar(backgroundColor: color.withValues(alpha: 0.1), child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Text(AppFormat.currency(amount), style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildActivityList() {
    final List<dynamic> combined = [..._fuelLogs, ..._otherExpenses];
    combined.sort((a, b) {
      final dateA = a is FuelLog ? a.date : (a as spx.Transaction).date;
      final dateB = b is FuelLog ? b.date : (b as spx.Transaction).date;
      return dateB.compareTo(dateA);
    });

    if (combined.isEmpty) {
      return Center(child: Text('No activity recorded', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)));
    }

    return Column(
      children: combined.take(20).map((item) {
        if (item is FuelLog) {
          return _activityTile(
            icon: Icons.local_gas_station,
            color: Theme.of(context).colorScheme.secondary,
            title: 'Fuel Fill-up (${item.litres.toStringAsFixed(1)}L)',
            date: item.date,
            amount: item.totalCost,
          );
        } else {
          final t = item as spx.Transaction;
          return _activityTile(
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

  Widget _activityTile({required IconData icon, required Color color, required String title, required DateTime date, required double amount}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.1), child: Icon(icon, color: color, size: 18)),
      title: Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
      subtitle: Text(DateFormat('dd MMM yyyy').format(date), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
      trailing: Text(AppFormat.currency(amount), style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
    );
  }
}
