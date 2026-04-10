import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/providers.dart';
import '../../models/net_worth_snapshot_record.dart';
import '../../shared/widgets/undo_snackbar_listener.dart';
import '../../services/settings_service.dart';
import '../../utils/app_format.dart';

class NetWorthReportScreen extends ConsumerStatefulWidget {
  const NetWorthReportScreen({super.key});

  @override
  ConsumerState<NetWorthReportScreen> createState() =>
      _NetWorthReportScreenState();
}

class _NetWorthReportScreenState extends ConsumerState<NetWorthReportScreen> {
  int _selectedTab = 0;

  Future<void> _deleteSnapshot(NetWorthSnapshotRecord snapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        title: const Text('Delete Snapshot?'),
        content: const Text(
          'This will remove this specific entry from your history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(netWorthHistoryProvider.notifier).remove(snapshot);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsService>();
    final historyAsync = ref.watch(netWorthHistoryProvider);

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is NetWorthSnapshotRecord,
    );

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
                color: Colors.white.withValues(alpha: 0.05),
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
      body: SafeArea(
        child: historyAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Error: $error')),
          data: (history) {
            if (history.isEmpty) {
              return const Center(
                child: Text(
                  'No snapshots captured yet.',
                  style: TextStyle(color: Colors.grey),
                ),
              );
            }

            final rawItems = history;
            final monthlyItems = _aggregate(history, monthly: true);
            final yearlyItems = _aggregate(history, monthly: false);

            final items = switch (_selectedTab) {
              1 => monthlyItems,
              2 => yearlyItems,
              _ => rawItems.map(_SnapshotViewItem.fromRecord).toList(),
            };

            return _buildList(items, isSnapshots: _selectedTab == 0);
          },
        ),
      ),
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
            color: active
                ? Colors.blueAccent.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: active
                ? Border.all(color: Colors.blueAccent.withValues(alpha: 0.3))
                : null,
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

  Widget _buildList(
    List<_SnapshotViewItem> items, {
    required bool isSnapshots,
  }) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                title: Text(
                  item.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                subtitle: Text(
                  item.subtitle,
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
                trailing: isSnapshots
                    ? IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                          size: 20,
                        ),
                        onPressed: () =>
                            _deleteSnapshot(item.originalSnapshot!),
                      )
                    : (item.change != null ? _changePill(item.change!) : null),
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
                        _dataItem(
                          'Net Worth',
                          AppFormat.currency(item.netWorth),
                          item.netWorth >= 0 ? Colors.blueAccent : Colors.red,
                          large: true,
                        ),
                        _dataItem(
                          'Assets',
                          AppFormat.currency(item.assets),
                          Colors.green,
                        ),
                        _dataItem(
                          'Liabilities',
                          AppFormat.currency(item.liabilities),
                          Colors.redAccent,
                        ),
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

  List<_SnapshotViewItem> _aggregate(
    List<NetWorthSnapshotRecord> history, {
    required bool monthly,
  }) {
    final grouped = <String, NetWorthSnapshotRecord>{};
    for (final item in history) {
      final key = monthly
          ? '${item.timestamp.year}-${item.timestamp.month.toString().padLeft(2, '0')}'
          : '${item.timestamp.year}';
      grouped.putIfAbsent(key, () => item);
    }

    final sortedKeys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final items = sortedKeys
        .map(
          (key) =>
              _SnapshotViewItem.fromAggregate(grouped[key]!, monthly: monthly),
        )
        .toList();

    for (var index = 0; index < items.length - 1; index++) {
      final current = items[index];
      final previous = items[index + 1];
      items[index] = current.copyWith(
        change: current.netWorth - previous.netWorth,
      );
    }

    return items;
  }

  Widget _changePill(double change) {
    final isPositive = change >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (isPositive ? Colors.green : Colors.red).withValues(alpha: 0.1),
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

  Widget _dataItem(
    String label,
    String value,
    Color color, {
    bool large = false,
  }) {
    return Column(
      crossAxisAlignment: large
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: large ? 16 : 13,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 10)),
      ],
    );
  }
}

class _SnapshotViewItem {
  const _SnapshotViewItem({
    required this.originalSnapshot,
    required this.timestamp,
    required this.title,
    required this.subtitle,
    required this.netWorth,
    required this.assets,
    required this.liabilities,
    this.change,
  });

  final NetWorthSnapshotRecord? originalSnapshot;
  final DateTime timestamp;
  final String title;
  final String subtitle;
  final double netWorth;
  final double assets;
  final double liabilities;
  final double? change;

  factory _SnapshotViewItem.fromRecord(NetWorthSnapshotRecord record) {
    return _SnapshotViewItem(
      originalSnapshot: record,
      timestamp: record.timestamp,
      title: DateFormat('dd MMM yyyy').format(record.timestamp),
      subtitle: DateFormat('hh:mm a').format(record.timestamp),
      netWorth: record.netWorth,
      assets: record.assets,
      liabilities: record.liabilities,
    );
  }

  factory _SnapshotViewItem.fromAggregate(
    NetWorthSnapshotRecord record, {
    required bool monthly,
  }) {
    return _SnapshotViewItem(
      originalSnapshot: null,
      timestamp: record.timestamp,
      title: monthly
          ? DateFormat('MMMM yyyy').format(record.timestamp)
          : '${record.timestamp.year} Report',
      subtitle: monthly ? 'Monthly Closing Balance' : 'Yearly Closing Balance',
      netWorth: record.netWorth,
      assets: record.assets,
      liabilities: record.liabilities,
    );
  }

  _SnapshotViewItem copyWith({double? change}) {
    return _SnapshotViewItem(
      originalSnapshot: originalSnapshot,
      timestamp: timestamp,
      title: title,
      subtitle: subtitle,
      netWorth: netWorth,
      assets: assets,
      liabilities: liabilities,
      change: change ?? this.change,
    );
  }
}
