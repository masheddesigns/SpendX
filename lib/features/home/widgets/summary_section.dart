import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/home_providers.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../../models/transaction.dart';
import '../../../screens/home/transactions_screen.dart';
import '../../../screens/reports_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../utils/app_format.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/theme/app_theme.dart';

class SummarySection extends ConsumerWidget {
  const SummarySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(homeSummaryProvider);
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.standard, AppSpacing.section, AppSpacing.standard, 0),
      child: Column(
        children: [
          _MainBalanceCard(
            balance: summary.balance,
            currentMonthExpense: summary.currentMonthExpense,
            previousMonthExpense: summary.previousMonthExpense,
            onTap: () => _openReports(context),
          ),
          const SizedBox(height: AppSpacing.standard),
          Row(
            children: [
              Expanded(
                child: _MiniSummaryCard(
                  title: 'Income',
                  amount: summary.income,
                  icon: Icons.add_rounded,
                  color: AppTheme.successColor,
                  onTap: () => _openTypeList(ref, context, 'income'),
                ),
              ),
              const SizedBox(width: AppSpacing.standard),
              Expanded(
                child: _MiniSummaryCard(
                  title: 'Expense',
                  amount: summary.expense,
                  icon: Icons.remove_rounded,
                  color: AppTheme.errorColor,
                  onTap: () => _openTypeList(ref, context, 'expense'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openReports(BuildContext context) {
    Navigator.of(
      context,
    ).push(AppPageRoute(builder: (_) => const ReportsScreen()));
  }

  void _openTypeList(WidgetRef ref, BuildContext context, String type) {
    final txns =
        ref.read(transactionsProvider).valueOrNull ?? const <Transaction>[];
    final now = DateTime.now();
    final ids = txns
        .where(
          (t) =>
              t.type == type &&
              t.date.year == now.year &&
              t.date.month == now.month,
        )
        .map((t) => t.id)
        .toList();
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => TransactionListScreen(
          filterIds: ids,
          title: type == 'income' ? 'Income' : 'Expense',
        ),
      ),
    );
  }

}

class _MainBalanceCard extends StatelessWidget {
  final double balance;
  final double currentMonthExpense;
  final double previousMonthExpense;
  final VoidCallback onTap;

  const _MainBalanceCard({
    required this.balance,
    required this.currentMonthExpense,
    required this.previousMonthExpense,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final hasPreviousData = previousMonthExpense > 0;
    
    double getPercentChange(double current, double previous) {
      if (previous <= 0) return 0.0;
      return ((current - previous) / previous) * 100;
    }

    final delta = getPercentChange(currentMonthExpense, previousMonthExpense);
    
    final isPositive = delta <= 0;
    final changeLabel = hasPreviousData 
        ? '${isPositive ? '' : '+'}${delta.toStringAsFixed(1)}%' 
        : '—';
    final changeColor = isPositive ? AppTheme.successColor : AppTheme.errorColor;
    final changeIcon = isPositive ? Icons.trending_down_rounded : Icons.trending_up_rounded;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.section),
      backgroundColor: cs.surfaceContainerHigh,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total Balance',
            style: AppTextStyles.subheading.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: balance),
            duration: const Duration(milliseconds: 1000),
            curve: Curves.easeOutExpo,
            builder: (context, value, child) {
              return Text(
                AppFormat.currency(value),
                style: AppTextStyles.heading.copyWith(
                  fontSize: 32,
                  letterSpacing: -1,
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: changeColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.s),
                ),
                child: Row(
                  children: [
                    Icon(changeIcon, size: 14, color: changeColor),
                    const SizedBox(width: 4),
                    Text(
                      changeLabel,
                      style: AppTextStyles.caption.copyWith(color: changeColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'vs last month',
                style: AppTextStyles.caption.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniSummaryCard extends StatelessWidget {
  final String title;
  final double amount;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _MiniSummaryCard({
    required this.title,
    required this.amount,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.standard),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                title,
                style: AppTextStyles.caption.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: amount),
            duration: const Duration(milliseconds: 1200),
            curve: Curves.easeOutBack,
            builder: (context, value, child) {
              return Text(
                AppFormat.currency(value),
                style: AppTextStyles.subheading.copyWith(fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            },
          ),
        ],
      ),
    );
  }
}

