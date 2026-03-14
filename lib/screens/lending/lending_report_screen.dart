import 'package:flutter/material.dart';
import '../../models/lending.dart';
import '../../services/database_helper.dart';
import '../../utils/app_format.dart';
import '../../theme/app_theme.dart';
import 'package:intl/intl.dart';

class LendingReportScreen extends StatefulWidget {
  const LendingReportScreen({super.key});

  @override
  State<LendingReportScreen> createState() => _LendingReportScreenState();
}

class _LendingReportScreenState extends State<LendingReportScreen> {
  bool _isLoading = true;
  List<Lending> _allLendings = [];
  Map<String, double> _personLentMap = {};
  Map<String, double> _personBorrowedMap = {};
  Map<String, double> _monthlyTrend = {};
  String _selectedTimeline = 'Yearly';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final lendings = await DatabaseHelper.instance.getAllLendings();
    
    final lentMap = <String, double>{};
    final borrowedMap = <String, double>{};
    final trendMap = <String, double>{};

    for (var l in lendings) {
      final name = l.personName;
      final amount = l.originalAmount;
      final dateKey = DateFormat('MMM yyyy').format(l.date);

      if (l.type == 'lent') {
        lentMap[name] = (lentMap[name] ?? 0) + amount;
        trendMap[dateKey] = (trendMap[dateKey] ?? 0) + amount;
      } else {
        borrowedMap[name] = (borrowedMap[name] ?? 0) + amount;
        trendMap[dateKey] = (trendMap[dateKey] ?? 0) - amount;
      }
    }

    // Sort maps by amount
    final sortedLent = Map.fromEntries(
        lentMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
    final sortedBorrowed = Map.fromEntries(
        borrowedMap.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));

    if (mounted) {
      setState(() {
        _allLendings = lendings;
        _personLentMap = sortedLent;
        _personBorrowedMap = sortedBorrowed;
        _monthlyTrend = trendMap;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lending Reports'),
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
                  _buildSummaryCards(),
                  const SizedBox(height: 24),
                  _buildSectionTitle('Top People I Lent To'),
                  _buildPersonList(_personLentMap, Colors.green),
                  const SizedBox(height: 24),
                  _buildSectionTitle('Top People I Borrowed From'),
                  _buildPersonList(_personBorrowedMap, Colors.orange),
                  const SizedBox(height: 24),
                  _buildSectionTitle('Monthly Activity'),
                  _buildMonthlyActivity(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
    );
  }

  Widget _buildSummaryCards() {
    double totalLent = _allLendings.where((l) => l.type == 'lent').fold(0, (sum, item) => sum + item.originalAmount);
    double totalBorrowed = _allLendings.where((l) => l.type == 'borrowed').fold(0, (sum, item) => sum + item.originalAmount);

    return Row(
      children: [
        Expanded(
          child: _summaryCard('Total Lent', AppFormat.currency(totalLent), Colors.green),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _summaryCard('Total Borrowed', AppFormat.currency(totalBorrowed), Colors.orange),
        ),
      ],
    );
  }

  Widget _summaryCard(String label, String val, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
          const SizedBox(height: 8),
          Text(val, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
    );
  }

  Widget _buildPersonList(Map<String, double> map, Color color) {
    if (map.isEmpty) {
      return const Text('No data available', style: TextStyle(color: Colors.grey));
    }
    return Column(
      children: map.entries.take(5).map((e) {
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(e.key, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
              Text(AppFormat.currency(e.value), style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMonthlyActivity() {
    if (_monthlyTrend.isEmpty) {
      return const Text('No activity yet', style: TextStyle(color: Colors.grey));
    }
    final sortedKeys = _monthlyTrend.keys.toList()..sort((a, b) {
      final dateA = DateFormat('MMM yyyy').parse(a);
      final dateB = DateFormat('MMM yyyy').parse(b);
      return dateB.compareTo(dateA);
    });

    return Column(
      children: sortedKeys.map((key) {
        final val = _monthlyTrend[key]!;
        final isPositive = val >= 0;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(key, style: const TextStyle(color: Colors.white)),
          trailing: Text(
            '${isPositive ? '+' : ''}${AppFormat.currency(val)}',
            style: TextStyle(color: isPositive ? Colors.green : Colors.red, fontWeight: FontWeight.w600),
          ),
        );
      }).toList(),
    );
  }
}
