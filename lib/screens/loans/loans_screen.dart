import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart' as app_data;
import '../../features/liabilities/providers/liabilities_providers.dart'
    show liabilitiesSummaryProvider;
import '../../models/loan.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_dialog.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../shared/widgets/error_state_widget.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/undo_snackbar_listener.dart';
import '../../utils/app_format.dart';
import '../../utils/text_formatter.dart';
import 'add_loan_screen.dart';
import 'loan_detail_screen.dart';
import '../../shared/widgets/app_page_route.dart';

class LoansScreen extends ConsumerStatefulWidget {
  const LoansScreen({super.key});

  @override
  ConsumerState<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends ConsumerState<LoansScreen> {
  @override
  Widget build(BuildContext context) {
    final loansAsync = ref.watch(app_data.loansProvider);

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is Loan,
      onUndone: (_) => ref.invalidate(liabilitiesSummaryProvider),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Loans')),
      body: SafeArea(
        child: loansAsync.when(
          loading: () => const SkeletonLoader.transactions(),
          error: (err, _) => ErrorStateWidget(
            error: err,
            onRetry: () => ref.invalidate(app_data.loansProvider),
          ),
          data: (loans) {
            if (loans.isEmpty) {
              return _buildEmptyState(context);
            }

            // Use simple ListView — no fragile AnimatedList state
            return ListView.builder(
              padding: EdgeInsets.only(
                left: AppSpacing.listHorizontalPadding,
                right: AppSpacing.listHorizontalPadding,
                top: AppSpacing.listHorizontalPadding,
                bottom: 80, // space for FAB
              ),
              itemCount: loans.length,
              itemBuilder: (context, index) {
                final loan = loans[index];
                return _buildLoanTile(context, loan);
              },
            );
          },
        ),
      ),
      // Only show FAB when loans exist (empty state has its own button)
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: (loansAsync.valueOrNull?.isNotEmpty ?? false)
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
              child: PrimaryButton(
                onPressed: () => _addLoan(),
                label: 'Add Loan',
              ),
            )
          : null,
    );
  }

  Future<void> _addLoan() async {
    final result = await Navigator.push(
      context,
      AppPageRoute(builder: (_) => const AddLoanScreen()),
    );
    if (result == true && mounted) {
      await ref.read(app_data.loansProvider.notifier).refresh();
      ref.invalidate(liabilitiesSummaryProvider);
    }
  }

  Widget _buildLoanTile(BuildContext context, Loan loan) {
    return Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.cardGap),
      child: InkWell(
        onTap: () async {
          final result = await Navigator.push(
            context,
            AppPageRoute(builder: (_) => LoanDetailScreen(loan: loan)),
          );
          if (!mounted) return;
          if (result == LoanDetailAction.deleted) {
            await _deleteLoan(loan, skipConfirm: true);
            return;
          }
          if (result == true) {
            await ref.read(app_data.loansProvider.notifier).refresh();
            ref.invalidate(liabilitiesSummaryProvider);
          }
        },
        onLongPress: () => _showLoanOptions(context, loan),
        borderRadius: BorderRadius.circular(24),
        child: _buildLoanCard(context, loan),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return EmptyStateWidget(
      icon: Icons.account_balance_rounded,
      title: 'No active loans',
      description: 'Track your car, home, or personal loans here.',
      ctaLabel: 'Add Loan',
      onCtaTap: _addLoan,
    );
  }

  Widget _buildLoanCard(BuildContext context, Loan loan) {
    final remaining = loan.principalAmount - loan.paidAmount;
    final progress =
        (loan.principalAmount > 0
                ? loan.paidAmount / loan.principalAmount
                : 0.0)
            .clamp(0.0, 1.0);

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppSpacing.cardPadding,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loan.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      loan.bank,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: loan.loanStatus == 'active'
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color:
                          (loan.loanStatus == 'active'
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outline)
                              .withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    TextFormatter.toSmartTitleCase(loan.loanStatus),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: loan.loanStatus == 'active'
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Padding(
            padding: AppSpacing.cardPadding,
            child: Row(
              children: [
                Expanded(
                  child: _buildMetric(
                    context,
                    'Principal',
                    AppFormat.currency(loan.principalAmount),
                  ),
                ),
                Expanded(
                  child: _buildMetric(
                    context,
                    'Remaining',
                    AppFormat.currency(remaining),
                    valueColor: Theme.of(context).colorScheme.error,
                  ),
                ),
                Expanded(
                  child: _buildMetric(
                    context,
                    'EMI',
                    AppFormat.currency(loan.monthlyInstallment),
                    valueColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Repayment Progress',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '${(progress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Started: ${loan.startDate.day}/${loan.startDate.month}/${loan.startDate.year}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (loan.nextDueDate != null)
                      Text(
                        'Next Due: ${loan.nextDueDate!.day}/${loan.nextDueDate!.month}/${loan.nextDueDate!.year}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: valueColor ?? Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  void _showLoanOptions(BuildContext context, Loan loan) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          Text(
            loan.name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(
              Icons.edit_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('Edit Loan Details'),
            onTap: () async {
              Navigator.pop(context);
              final result = await Navigator.push(
                context,
                AppPageRoute(builder: (_) => AddLoanScreen(loan: loan)),
              );
              if (result == true) {
                await ref.read(app_data.loansProvider.notifier).refresh();
                ref.invalidate(liabilitiesSummaryProvider);
              }
            },
          ),
          ListTile(
            leading: Icon(
              Icons.delete_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const Text('Delete Loan'),
            onTap: () {
              Navigator.pop(context);
              _deleteLoan(loan);
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _deleteLoan(Loan loan, {bool skipConfirm = false}) async {
    final confirm = skipConfirm
        ? true
        : await AppDialog.showConfirm(
            context: context,
            title: 'Delete Loan?',
            message:
                'Are you sure you want to delete "${loan.name}"? You can undo this immediately.',
            confirmLabel: 'Delete',
            isDestructive: true,
          );

    if (confirm == true) {
      await ref.read(app_data.loansProvider.notifier).remove(loan);
      ref.invalidate(liabilitiesSummaryProvider);
    }
  }
}
