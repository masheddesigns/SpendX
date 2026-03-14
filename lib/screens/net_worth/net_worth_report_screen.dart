import 'package:flutter/material.dart';
import '../../services/database_helper.dart';
import '../../utils/app_format.dart';
import '../../theme/app_theme.dart';
import 'package:intl/intl.dart';

class NetWorthReportScreen extends StatefulWidget {
  const NetWorthReportScreen({super.key});

  @override
  State<NetWorthReportScreen> createState() => _NetWorthReportScreenState();
}

class _NetWorthReportScreenState extends State<NetWorthReportScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _rawHistory = [];
  
  // Aggregated data
  List<Map<String, dynamic>> _monthlyReport = [];
  List<Map<String, dynamic>> _yearlyReport = [];

  int _selectedTab = 0; // 0: Snapshots, 1: Monthly, 2: Yearly

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    setState(() => _isLoading = true);
    // Fetch a large enough sample for aggregation (or all)
    final data = await DatabaseHelper.instance.getNetWorthHistory(limit: 500);
    
    if (mounted) {
      setState(() {
        _rawHistory = data;
        _generateAggregatedReports();
        _isLoading = false;
      });
    }
  }

  void _generateAggregatedReports() {
    if (_rawHistory.isEmpty) return;

    // --- Monthly Aggregation ---
    final Map<String, Map<String, dynamic>> monthlyMap = {};
    for (final item in _rawHistory) {
      final date = DateTime.parse(item['timestamp']);
      final key = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      
      // Since history is DESC, the first one we find for a month is the latest
      if (!monthlyMap.containsKey(key)) {
        monthlyMap[key] = Map.from(item);
      }
    }
    
    final sortedMonths = monthlyMap.keys.toList()..sort((a, b) => b.compareTo(a));
    _monthlyReport = sortedMonths.map((k) => monthlyMap[k]!).toList();

    // Calculate changes for monthly
    for (int i = 0; i < _monthlyReport.length - 1; i++) {
      final current = _monthlyReport[i]['net_worth'] as double;
      final previous = _monthlyReport[i + 1]['net_worth'] as double;
      _monthlyReport[i]['change'] = current - previous;
    }

    // --- Yearly Aggregation ---
    final Map<int, Map<String, dynamic>> yearlyMap = {};
    for (final item in _rawHistory) {
      final date = DateTime.parse(item['timestamp']);
      final key = date.year;
      
      if (!yearlyMap.containsKey(key)) {
        yearlyMap[key] = Map.from(item);
      }
    }
    
    final sortedYears = yearlyMap.keys.toList()..sort((a, b) => b.compareTo(a));
    _yearlyReport = sortedYears.map((k) => yearlyMap[k]!).toList();

     // Calculate changes for yearly
    for (int i = 0; i < _yearlyReport.length - 1; i++) {
      final current = _yearlyReport[i]['net_worth'] as double;
      final previous = _yearlyReport[i + 1]['net_worth'] as double;
      _yearlyReport[i]['change'] = current - previous;
    }
  }

  Future<void> _deleteSnapshot(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        title: const Text('Delete Snapshot?'),
        content: const Text('This will remove this specific entry from your history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true), 
            child: const Text('Delete', style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DatabaseHelper.instance.deleteNetWorthSnapshot(id);
      _loadAllData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Net Worth Report'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  _tabItem('Snapshots', 0),
                  _tabItem('Monthly', 1),
                  _tabItem('Yearly', 2),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _rawHistory.isEmpty
              ? const Center(child: Text('No snapshots captured yet.', style: TextStyle(color: Colors.grey)))
              : _buildList(),
    );
  }

  Widget _tabItem(String title, int index) {
    final active = _selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? Colors.blueAccent.withOpacity(0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: active ? Border.all(color: Colors.blueAccent.withOpacity(0.3)) : null,
          ),
          child: Text(
            title,
            style: TextStyle(
              color: active ? Colors.blueAccent : Colors.grey,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    List<Map<String, dynamic>> items;
    bool isAggregated = false;
    
    if (_selectedTab == 0) {
      items = _rawHistory;
    } else if (_selectedTab == 1) {
      items = _monthlyReport;
      isAggregated = true;
    } else {
      items = _yearlyReport;
      isAggregated = true;
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i];
        final date = DateTime.parse(item['timestamp']);
        final netWorth = (item['net_worth'] as num).toDouble();
        final assets = (item['assets'] as num).toDouble();
        final liabilities = (item['liabilities'] as num).toDouble();
        final change = item['change'] as double?;

        String title;
        String subtitle;
        if (_selectedTab == 0) {
          title = DateFormat('dd MMM yyyy').format(date);
          subtitle = DateFormat('hh:mm a').format(date);
        } else if (_selectedTab == 1) {
          title = DateFormat('MMMM yyyy').format(date);
          subtitle = 'Monthly Closing Balance';
        } else {
          title = '${date.year} Report';
          subtitle = 'Yearly Closing Balance';
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                trailing: _selectedTab == 0 
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                      onPressed: () => _deleteSnapshot(item['id']),
                    )
                  : (change != null ? _changePill(change) : null),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  children: [
                    const Divider(color: Colors.white12, height: 1),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _dataItem('Net Worth', AppFormat.currency(netWorth), netWorth >= 0 ? Colors.blueAccent : Colors.red, large: true),
                        _dataItem('Assets', AppFormat.currency(assets), Colors.green),
                        _dataItem('Liabilities', AppFormat.currency(liabilities), Colors.redAccent),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _changePill(double change) {
    final isPositive = change >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (isPositive ? Colors.green : Colors.red).withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPositive ? Icons.trending_up : Icons.trending_down,
            size: 12,
            color: isPositive ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 4),
          Text(
            AppFormat.currency(change.abs()),
            style: TextStyle(
              color: isPositive ? Colors.green : Colors.red,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dataItem(String label, String val, Color color, {bool large = false}) {
    return Column(
      crossAxisAlignment: large ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          val,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: large ? 16 : 13,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(color: Colors.grey[500], fontSize: 10),
        ),
      ],
    );
  }
}
