import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/vehicle.dart';
import '../../models/transaction.dart' as spx;
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';

class FuelAnalyticsScreen extends StatefulWidget {
  final String vehicleId;
  final String vehicleName;

  const FuelAnalyticsScreen({
    super.key,
    required this.vehicleId,
    required this.vehicleName,
  });

  @override
  State<FuelAnalyticsScreen> createState() => _FuelAnalyticsScreenState();
}

class _FuelAnalyticsScreenState extends State<FuelAnalyticsScreen> {
  List<FuelLog> _logs = [];
  List<spx.Transaction> _otherExpenses = [];
  bool _isLoading = true;

  // Computed analytics
  late _FuelStats _stats;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final logs = await DatabaseHelper.instance.getFuelLogsForVehicle(widget.vehicleId);
    final other = await DatabaseHelper.instance.getTransactionsForVehicle(widget.vehicleId);
    if (mounted) {
      setState(() {
        _logs = logs;
        _otherExpenses = other;
        _stats = _FuelStats.compute(logs, other);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_logs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text('${widget.vehicleName} Analytics'), backgroundColor: Colors.transparent, elevation: 0),
        body: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.analytics_outlined, size: 72, color: Colors.grey[700]),
            const SizedBox(height: 16),
            Text('No fuel logs yet', style: TextStyle(color: Colors.grey[400], fontSize: 18)),
            Text('Add fuel logs to see analytics', style: TextStyle(color: Colors.grey[600])),
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.vehicleName} Analytics'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── Total KMs Hero ───
              _buildTotalKmHero(),
              const SizedBox(height: 20),

              // ─── All-time Overview ───
              _sectionTitle('All-time overview'),
              const SizedBox(height: 12),
              _buildOverviewGrid(),
              const SizedBox(height: 24),

              // ─── Mileage Insights ───
              _sectionTitle('Mileage Insights'),
              const SizedBox(height: 12),
              _buildMileageInsights(),
              const SizedBox(height: 24),

              // ─── Month-wise breakdown ───
              _sectionTitle('Month-wise Breakdown'),
              const SizedBox(height: 12),
              _buildMonthTable(),
              const SizedBox(height: 24),

              // ─── Mileage Trend ───
              _sectionTitle('Mileage Trend'),
              const SizedBox(height: 12),
              _buildMileageTrend(),
              const SizedBox(height: 24),

              // ─── Other Expenses ───
              if (_otherExpenses.isNotEmpty) ...[
                _sectionTitle('Other Vehicle Expenses'),
                const SizedBox(height: 12),
                _buildOtherExpensesList(),
                const SizedBox(height: 24),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOtherExpensesList() {
    return Container(
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(children: [
        ..._otherExpenses.map((t) => ListTile(
          leading: CircleAvatar(backgroundColor: Theme.of(context).colorScheme.primary, child: Icon(Icons.build, color: Theme.of(context).colorScheme.onPrimary, size: 18)),
          title: Text(t.notes.isEmpty ? 'Vehicle Expense' : t.notes, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
          subtitle: Text(DateFormat('dd MMM yyyy').format(t.date), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
          trailing: Text(AppFormat.currency(t.amount), style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600)),
        )),
      ]),
    );
  }

  // ─── Total KMs Hero ────────────────────────────────────────
  Widget _buildTotalKmHero() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Theme.of(context).colorScheme.secondary.withValues(alpha: 0.25), Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.route, color: Theme.of(context).colorScheme.secondary, size: 18),
            const SizedBox(width: 6),
            Text(
              'Tracked with SpendX',
              style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            _stats.totalKm > 0 ? '${_stats.totalKm.toStringAsFixed(0)} km' : '0 km',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 42,
              fontWeight: FontWeight.w600,
              letterSpacing: -1,
            ),
          ),
          Text(
            'Total distance logged across ${_logs.length} fill-ups',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ─── Overview Grid ───────────────────────────────────────
  Widget _buildOverviewGrid() {
    final items = [
      _OverviewItem(Icons.local_gas_station, 'Total Spend', '${AppFormat.currency(_stats.totalCost)}', Theme.of(context).colorScheme.secondary),
      _OverviewItem(Icons.water_drop, 'Total Litres', '${_stats.totalLitres.toStringAsFixed(1)} L', Theme.of(context).colorScheme.tertiary),
      _OverviewItem(Icons.trending_up, 'Cost / KM', _stats.costPerKm != null ? '${AppFormat.currency(_stats.costPerKm!)}' : '--', Theme.of(context).colorScheme.primary),
      _OverviewItem(Icons.show_chart, 'Avg Mileage', _stats.avgMileage != null ? '${_stats.avgMileage!.toStringAsFixed(1)} km/l' : '--', Theme.of(context).colorScheme.primary),
      _OverviewItem(Icons.format_list_numbered, 'Fill-ups', '${_logs.length}', Theme.of(context).colorScheme.secondary),
      _OverviewItem(Icons.local_gas_station, 'Avg Price/L', _stats.avgPricePerLitre != null ? '${AppFormat.currency(_stats.avgPricePerLitre!)}' : '--', Theme.of(context).colorScheme.tertiary),
    ];

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 0.95,
      children: items.map((item) => _buildStatCard(item)).toList(),
    );
  }

  Widget _buildStatCard(_OverviewItem item) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: item.color.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(item.icon, color: item.color, size: 24),
          const SizedBox(height: 8),
          Text(item.value,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(item.label,
            style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ─── Mileage Insights ───────────────────────────────────────
  Widget _buildMileageInsights() {
    final logsWithEff = _logs.where((l) => l.efficiency != null).toList();
    return Column(children: [
      if (_stats.bestMileageLog != null)
        _buildInsightTile(
          icon: Icons.emoji_events,
          color: Theme.of(context).colorScheme.primary,
          label: 'Best Mileage',
          value: '${_stats.bestMileageLog!.efficiency!.toStringAsFixed(1)} km/l',
          sub: DateFormat('dd MMM yyyy').format(_stats.bestMileageLog!.date),
        ),
      if (_stats.worstMileageLog != null)
        _buildInsightTile(
          icon: Icons.warning_amber,
          color: Theme.of(context).colorScheme.error,
          label: 'Worst Mileage',
          value: '${_stats.worstMileageLog!.efficiency!.toStringAsFixed(1)} km/l',
          sub: DateFormat('dd MMM yyyy').format(_stats.worstMileageLog!.date),
        ),
      _buildInsightTile(
        icon: Icons.currency_exchange,
        color: Theme.of(context).colorScheme.secondary,
        label: 'Avg Cost/Fill-up',
        value: '${AppFormat.currency(_stats.totalCost / _logs.length)}',
        sub: '${(_stats.totalLitres / _logs.length).toStringAsFixed(1)} L avg',
      ),
      if (_stats.avgPricePerLitre != null)
        _buildInsightTile(
          icon: Icons.local_gas_station,
          color: Theme.of(context).colorScheme.tertiary,
          label: 'Avg Fuel Price',
          value: '${AppFormat.currency(_stats.avgPricePerLitre!)}/L',
          sub: 'across ${_logs.length} fill-ups',
        ),
    ]);
  }

  Widget _buildInsightTile({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    required String sub,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
            Text(value, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600)),
            Text(sub, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 11)),
          ]),
        ),
      ]),
    );
  }

  // ─── Month Table ───────────────────────────────────────────
  Widget _buildMonthTable() {
    final months = _stats.monthlyBreakdown;
    if (months.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Row(children: [
            Expanded(child: Text('Month', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600))),
            SizedBox(width: 70, child: Text('Cost', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
            SizedBox(width: 55, child: Text('KMs', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
            SizedBox(width: 60, child: Text('Mileage', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
          ]),
        ),
        // Rows
        ...months.asMap().entries.map((entry) {
          final i = entry.key;
          final m = entry.value;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: i < months.length - 1
                  ? const Border(bottom: BorderSide(color: Colors.white10))
                  : null,
            ),
            child: Row(children: [
              Expanded(child: Text(m.label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13, fontWeight: FontWeight.w500))),
              SizedBox(width: 70, child: Text('${AppFormat.currency(m.cost)}', style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontSize: 13, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
              SizedBox(width: 55, child: Text(m.km > 0 ? '${m.km.toStringAsFixed(0)}' : '--', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13), textAlign: TextAlign.right)),
              SizedBox(width: 60, child: Text(m.avgMileage != null ? '${m.avgMileage!.toStringAsFixed(1)}' : '--', style: TextStyle(color: m.avgMileage != null ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w600), textAlign: TextAlign.right)),
            ]),
          );
        }),
      ]),
    );
  }

  // ─── Mileage Trend Bar Chart ────────────────────────────────
  Widget _buildMileageTrend() {
    final logsWithEff = _logs.where((l) => l.efficiency != null).take(10).toList().reversed.toList();
    if (logsWithEff.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
        child: Center(child: Text('Need at least 2 fill-ups to show trend', style: TextStyle(color: Colors.grey[500]))),
      );
    }

    final maxEff = logsWithEff.map((l) => l.efficiency!).reduce((a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Last ${logsWithEff.length} fills (km/l)', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: logsWithEff.map((log) {
            final ratio = maxEff > 0 ? log.efficiency! / maxEff : 0.0;
            final barHeight = (ratio * 80).clamp(6.0, 80.0);
            final isGood = log.efficiency! >= (_stats.avgMileage ?? 0);
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(children: [
                  Text('${log.efficiency!.toStringAsFixed(0)}', style: TextStyle(color: Colors.grey[500], fontSize: 9)),
                  const SizedBox(height: 4),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: isGood ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.8) : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(DateFormat('d/M').format(log.date), style: TextStyle(color: Colors.grey[600], fontSize: 9)),
                ]),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Row(children: [
          _legend(Theme.of(context).colorScheme.primary, 'Above avg'),
          const SizedBox(width: 16),
          _legend(Theme.of(context).colorScheme.secondary, 'Below avg'),
        ]),
      ]),
    );
  }

  Row _legend(Color c, String label) => Row(children: [
    Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
    const SizedBox(width: 4),
    Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
  ]);

  Widget _sectionTitle(String title) => Text(
    title,
    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.1),
  );
}

// ─── Data classes ──────────────────────────────────────────────

class _OverviewItem {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  _OverviewItem(this.icon, this.label, this.value, this.color);
}

class _MonthData {
  final String label;
  final double cost;
  final double km; // from odo delta
  final double? avgMileage;
  _MonthData(this.label, this.cost, this.km, this.avgMileage);
}

class _FuelStats {
  final double totalCost;
  final double fuelCost;
  final double otherCost;
  final double totalLitres;
  final double totalKm;
  final double? costPerKm;
  final double? avgMileage;
  final double? avgPricePerLitre;
  final FuelLog? bestMileageLog;
  final FuelLog? worstMileageLog;
  final List<_MonthData> monthlyBreakdown;

  _FuelStats({
    required this.totalCost,
    required this.fuelCost,
    required this.otherCost,
    required this.totalLitres,
    required this.totalKm,
    required this.costPerKm,
    required this.avgMileage,
    required this.avgPricePerLitre,
    required this.bestMileageLog,
    required this.worstMileageLog,
    required this.monthlyBreakdown,
  });

  factory _FuelStats.compute(List<FuelLog> logs, List<spx.Transaction> other) {
    if (logs.isEmpty && other.isEmpty) {
      return _FuelStats(
        totalCost: 0, fuelCost: 0, otherCost: 0, totalLitres: 0, totalKm: 0,
        costPerKm: null, avgMileage: null, avgPricePerLitre: null,
        bestMileageLog: null, worstMileageLog: null, monthlyBreakdown: [],
      );
    }

    final fuelCost = logs.fold(0.0, (s, l) => s + l.totalCost);
    final otherCost = other.fold(0.0, (s, t) => s + t.amount);
    final totalCost = fuelCost + otherCost;
    final totalLitres = logs.fold(0.0, (s, l) => s + l.litres);
    
    // Total KM = max odo - min odo across all logs
    double totalKm = 0;
    if (logs.length >= 2) {
      final maxOdo = logs.map((l) => l.odometer).reduce((a, b) => a > b ? a : b);
      final minOdo = logs.map((l) => l.odometer).reduce((a, b) => a < b ? a : b);
      totalKm = maxOdo - minOdo;
    }

    final costPerKm = totalKm > 0 ? totalCost / totalKm : null;

    // Efficiency (mileage)
    final withEff = logs.where((l) => l.efficiency != null).toList();
    double? avgMileage;
    FuelLog? bestLog, worstLog;
    if (withEff.isNotEmpty) {
      avgMileage = withEff.fold(0.0, (s, l) => s + l.efficiency!) / withEff.length;
      bestLog = withEff.reduce((a, b) => a.efficiency! > b.efficiency! ? a : b);
      worstLog = withEff.reduce((a, b) => a.efficiency! < b.efficiency! ? a : b);
    }

    // Avg price per litre
    final avgPrice = totalLitres > 0
        ? logs.fold(0.0, (s, l) => s + l.pricePerLitre * l.litres) / totalLitres
        : null;

    // Monthly breakdown (group by year-month)
    final Map<String, List<dynamic>> monthly = {};
    for (final log in logs) {
      final key = DateFormat('MMM yyyy').format(log.date);
      monthly.putIfAbsent(key, () => []).add(log);
    }
    for (final t in other) {
       final key = DateFormat('MMM yyyy').format(t.date);
       monthly.putIfAbsent(key, () => []).add(t);
    }

    final monthlyList = monthly.entries.map((e) {
      final mItems = e.value;
      final mFuelLogs = mItems.whereType<FuelLog>().toList();
      final mOtherTrans = mItems.whereType<spx.Transaction>().toList();
      
      final mFuelCost = mFuelLogs.fold(0.0, (s, l) => s + l.totalCost);
      final mOtherCost = mOtherTrans.fold(0.0, (s, t) => s + t.amount);
      final mTotalCost = mFuelCost + mOtherCost;

      // KM for this month within fuel logs
      double mKm = 0;
      if (mFuelLogs.length >= 2) {
        mKm = mFuelLogs.map((l) => l.odometer).reduce((a, b) => a > b ? a : b) - 
              mFuelLogs.map((l) => l.odometer).reduce((a, b) => a < b ? a : b);
      }
      
      final mWithEff = mFuelLogs.where((l) => l.efficiency != null).toList();
      final mAvgEff = mWithEff.isEmpty
          ? null
          : mWithEff.fold(0.0, (s, l) => s + l.efficiency!) / mWithEff.length;

      return _MonthData(e.key, mTotalCost, mKm, mAvgEff);
    }).toList();

    return _FuelStats(
      totalCost: totalCost,
      fuelCost: fuelCost,
      otherCost: otherCost,
      totalLitres: totalLitres,
      totalKm: totalKm,
      costPerKm: costPerKm,
      avgMileage: avgMileage,
      avgPricePerLitre: avgPrice,
      bestMileageLog: bestLog,
      worstMileageLog: worstLog,
      monthlyBreakdown: monthlyList,
    );
  }
}
