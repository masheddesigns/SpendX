import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../models/lending.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../utils/app_format.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../shared/widgets/loading_state_widget.dart';
import '../../theme/app_theme.dart';

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 768;
            final Widget content;

            if (lendingState.isLoadingActive && lendingState.isLoadingSettled) {
              content = const LoadingStateWidget(
                message: 'Loading lending reports...',
              );
            } else if (allLendings.isEmpty) {
              content = RefreshIndicator(
                onRefresh: () => ref.read(lendingProvider.notifier).refresh(),
                child: const SingleChildScrollView(
                  physics: AlwaysScrollableScrollPhysics(),
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: EmptyStateWidget(
                      icon: Icons.bar_chart_rounded,
                      title: 'No Lending Activity',
                      description:
                          'Reports will appear after you record money lent or borrowed.',
                    ),
                  ),
                ),
              );
            } else {
              content = RefreshIndicator(
                onRefresh: () => ref.read(lendingProvider.notifier).refresh(),
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSummaryCards(allLendings),
                      const SizedBox(height: 24),
                      _buildSectionTitle('Top People I Lent To'),
                      _buildPersonList(sortedLent, AppColors.success),
                      const SizedBox(height: 24),
                      _buildSectionTitle('Top People I Borrowed From'),
                      _buildPersonList(sortedBorrowed, AppColors.warning),
                      const SizedBox(height: 24),
                      _buildSectionTitle('Monthly Activity'),
                      _buildMonthlyActivity(monthlyTrend),
                      const SizedBox(height: 80),
                    ],
                  ),
                ),
              );
            }

            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isTablet ? 768 : double.infinity,
                ),
                child: content,
              ),
            );
          },
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
            AppColors.success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _summaryCard(
            'Total Borrowed',
            AppFormat.currency(totalBorrowed),
            AppColors.warning,
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
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            val,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: context.textPrimary,
        ),
      ),
    );
  }

  Widget _buildPersonList(Map<String, double> map, Color color) {
    if (map.isEmpty) {
      return Text(
        'No data available',
        style: TextStyle(color: context.textMuted),
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
              Expanded(
                child: Text(
                  e.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                AppFormat.currency(e.value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
      return Text(
        'No activity yet',
        style: TextStyle(color: context.textMuted),
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
          title: Text(
            key,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.textPrimary),
          ),
          trailing: Text(
            '${isPositive ? '+' : ''}${AppFormat.currency(val)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isPositive ? AppColors.success : AppColors.danger,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }).toList(),
    );
  }
}
