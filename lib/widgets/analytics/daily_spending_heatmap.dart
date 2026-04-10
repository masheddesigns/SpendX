import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../utils/app_format.dart';

class DailySpendingHeatmap extends StatefulWidget {
  final Map<DateTime, double> dailySpending;
  final int year;

  const DailySpendingHeatmap({
    super.key,
    required this.dailySpending,
    required this.year,
  });

  @override
  State<DailySpendingHeatmap> createState() => _DailySpendingHeatmapState();
}

class _DailySpendingHeatmapState extends State<DailySpendingHeatmap> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentMonth();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrentMonth() {
    if (!_scrollController.hasClients) return;

    final now = DateTime.now();
    if (now.year != widget.year) return;

    // Estimate week number (1-53)
    final firstDayYear = DateTime(widget.year, 1, 1);
    final daysSinceFirstDay = now.difference(firstDayYear).inDays;
    final weekIndex = (daysSinceFirstDay + firstDayYear.weekday - 1) ~/ 7;

    // Total possible width: 53 weeks * (12px width + 2px margin) = 742px
    // Approx position: weekIndex * 14.0
    // Since it's horizontal and we want to see the current week,
    // we might need to adjust based on viewport width.
    // However, if reverse: true is used, the logic changes.
    // Let's check the current implementation's scroll direction.
    
    // The previous implementation used reverse: true.
    // If reverse: true, the scroll starts from the right (latest weeks).
    // So if it's the current year, it should already be showing newest data at the right.
    // But the user says they have to scroll TO the current month.
    // This implies either reverse: false OR they want it centered/aligned differently.
    
    // If reverse: false, we scroll to $(weekIndex * 14.0)$
    
    _scrollController.animateTo(
      weekIndex * 14.0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
    );
  }

  Color _getIntensityColor(double amount, BuildContext context) {
    if (amount == 0) return Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);
    if (amount <= 500) return const Color(0xFF166534).withValues(alpha: 0.4); // Light greenish
    if (amount <= 2000) return const Color(0xFF22C55E).withValues(alpha: 0.7); // Medium green
    return const Color(0xFF22C55E); // High intensity (success color)
  }

  @override
  Widget build(BuildContext context) {
    final bool isEmpty = widget.dailySpending.values.every((v) => v == 0);

    if (isEmpty) {
      return _buildEmptyState(context);
    }

    // Generate data for the year
    final DateTime firstDayOfYear = DateTime(widget.year, 1, 1);
    final int firstDayOffset = firstDayOfYear.weekday % 7; // 0 = Sunday, 1 = Monday...
    final int totalDays = DateTime(widget.year, 12, 31).difference(firstDayOfYear).inDays + 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(context),
        const SizedBox(height: 16),
        SizedBox(
          height: 110,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            reverse: false, // Changed to false to allow programmed scroll to current month
            child: Row(
              children: List.generate(53, (weekIndex) {
                return Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Column(
                    children: List.generate(7, (dayIndex) {
                      final dayInYear = (weekIndex * 7) + dayIndex - firstDayOffset;
                      
                      if (dayInYear < 0 || dayInYear >= totalDays) {
                        return const SizedBox(width: 12, height: 12, child: Padding(padding: EdgeInsets.all(2)));
                      }

                      final date = firstDayOfYear.add(Duration(days: dayInYear));
                      final normalizedDate = DateTime(date.year, date.month, date.day);
                      final amount = widget.dailySpending[normalizedDate] ?? 0.0;
                      
                      return GestureDetector(
                        onTap: () {
                          final formattedDate = DateFormat('MMMM d').format(normalizedDate);
                          final formattedAmount = AppFormat.currency(amount);
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('$formattedDate: $formattedAmount spent'),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                              width: 200,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          );
                        },
                        child: Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.all(1),
                          decoration: BoxDecoration(
                            color: _getIntensityColor(amount, context),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      );
                    }),
                  ),
                );
              }),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildLegend(context),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Spending Activity',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  decoration: TextDecoration.none,
                ),
              ),
              Text(
                '${widget.year}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Your daily spending pattern',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_balance_wallet_outlined, size: 48, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          const Text(
            'No spending data yet',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, decoration: TextDecoration.none),
          ),
          const SizedBox(height: 8),
          Text(
            'Start adding transactions to see your pattern.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, decoration: TextDecoration.none),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () {
              // Trigger a global event or navigate to home's first tab
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Transaction'),
            style: ElevatedButton.styleFrom(
              elevation: 0,
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text('Less', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10, decoration: TextDecoration.none)),
        const SizedBox(width: 4),
        _legendBox(context, 0),
        _legendBox(context, 250),
        _legendBox(context, 1000),
        _legendBox(context, 3000),
        const SizedBox(width: 4),
        Text('More', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10, decoration: TextDecoration.none)),
      ],
    );
  }

  Widget _legendBox(BuildContext context, double amount) {
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: _getIntensityColor(amount, context),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

