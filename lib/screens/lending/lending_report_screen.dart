import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/lending.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../utils/app_format.dart';
import 'package:intl/intl.dart';

class LendingReportScreen extends ConsumerStatefulWidget {
  const LendingReportScreen({super.key});

  @override
  ConsumerState<LendingReportScreen> createState() =>
      _LendingReportScreenState();
}

class _LendingReportScreenState extends ConsumerState<LendingReportScreen> {
  @override
  Widget build(BuildContext context) {
    final lendingState = ref.watch(lendingProvider);
    final allLendings = [
      ...lendingState.activeItems,
      ...lendingState.settledItems,
    ];
    final personLentMap = <String, double>{};
    final personBorrowedMap = <String, double>{};
    final monthlyTrend = <String, double>{};

    for (final lending in allLendings) {
      final dateKey = DateFormat('MMM yyyy').format(lending.date);
      if (lending.type == 'lent') {
        personLentMap[lending.personName] =
            (personLentMap[lending.personName] ?? 0) + lending.originalAmount;
        monthlyTrend[dateKey] =
            (monthlyTrend[dateKey] ?? 0) + lending.originalAmount;
      } else {
        personBorrowedMap[lending.personName] =
            (personBorrowedMap[lending.personName] ?? 0) +
            lending.originalAmount;
        monthlyTrend[dateKey] =
            (monthlyTrend[dateKey] ?? 0) - lending.originalAmount;
      }
    }

    final sortedLent = Map.fromEntries(
      personLentMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)),
    );
    final sortedBorrowed = Map.fromEntries(
      personBorrowedMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lending Reports'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: lendingState.isLoadingActive && lendingState.isLoadingSettled
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSummaryCards(allLendings),
                    const SizedBox(height: 24),
                    _buildSectionTitle('Top People I Lent To'),
                    _buildPersonList(sortedLent, Colors.green),
                    const SizedBox(height: 24),
                    _buildSectionTitle('Top People I Borrowed From'),
                    _buildPersonList(sortedBorrowed, Colors.orange),
                    const SizedBox(height: 24),
                    _buildSectionTitle('Monthly Activity'),
                    _buildMonthlyActivity(monthlyTrend),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildSummaryCards(List<Lending> allLendings) {
    double totalLent = allLendings
        .where((l) => l.type == 'lent')
        .fold(0, (sum, item) => sum + item.originalAmount);
    double totalBorrowed = allLendings
        .where((l) => l.type == 'borrowed')
        .fold(0, (sum, item) => sum + item.originalAmount);

    return Row(
      children: [
        Expanded(
          child: _summaryCard(
            'Total Lent',
            AppFormat.currency(totalLent),
            Colors.green,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _summaryCard(
            'Total Borrowed',
            AppFormat.currency(totalBorrowed),
            Colors.orange,
          ),
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
          Text(
            val,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildPersonList(Map<String, double> map, Color color) {
    if (map.isEmpty) {
      return const Text(
        'No data available',
        style: TextStyle(color: Colors.grey),
      );
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
              Text(
                e.key,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                AppFormat.currency(e.value),
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMonthlyActivity(Map<String, double> monthlyTrend) {
    if (monthlyTrend.isEmpty) {
      return const Text(
        'No activity yet',
        style: TextStyle(color: Colors.grey),
      );
    }
    final sortedKeys = monthlyTrend.keys.toList()
      ..sort((a, b) {
        final dateA = DateFormat('MMM yyyy').parse(a);
        final dateB = DateFormat('MMM yyyy').parse(b);
        return dateB.compareTo(dateA);
      });

    return Column(
      children: sortedKeys.map((key) {
        final val = monthlyTrend[key]!;
        final isPositive = val >= 0;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(key, style: const TextStyle(color: Colors.white)),
          trailing: Text(
            '${isPositive ? '+' : ''}${AppFormat.currency(val)}',
            style: TextStyle(
              color: isPositive ? Colors.green : Colors.red,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }).toList(),
    );
  }
}
