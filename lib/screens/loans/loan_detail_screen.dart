import '../../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../data/providers.dart';
import '../../models/loan.dart';
import '../../models/loan_installment.dart';
import '../../models/bank_account.dart';
import '../../domain/loans/loan_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_dialog.dart';
import 'add_loan_screen.dart';
import '../../shared/widgets/status_chip.dart';
import '../../utils/text_formatter.dart';
import '../../utils/app_format.dart';
import '../../shared/widgets/app_account_picker.dart';
import '../../shared/widgets/app_page_route.dart';

enum LoanDetailAction { deleted }

class LoanDetailScreen extends ConsumerStatefulWidget {
  final Loan loan;
  const LoanDetailScreen({super.key, required this.loan});

  @override
  ConsumerState<LoanDetailScreen> createState() => _LoanDetailScreenState();
}

class _LoanDetailScreenState extends ConsumerState<LoanDetailScreen> {
  String? _selectedAccountId;
  final LoanService _loanService = LoanService();

  Future<void> _payInstallment(
    LoanInstallment inst,
    List<BankAccount> accounts,
  ) async {
    final option = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => AppCard(
        padding: const EdgeInsets.all(AppSpacing.l),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Choose Payment Method', style: AppTextStyles.titleLarge),
            const SizedBox(height: AppSpacing.s),
            Text(
              'EMI Amount: ${AppFormat.currency(inst.amount)}',
              style: AppTextStyles.bodyMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.l),

            _buildPaymentOption(
              icon: Icons.account_balance_wallet_rounded,
              title: 'Pay via Account',
              subtitle: 'Deduct from bank and sync with ledger',
              onTap: () => Navigator.pop(context, 'account'),
            ),
            const SizedBox(height: AppSpacing.m),
            _buildPaymentOption(
              icon: Icons.check_circle_outline_rounded,
              title: 'Mark as Paid',
              subtitle: 'Manually mark without affecting ledger',
              onTap: () => Navigator.pop(context, 'manual'),
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    if (option == 'account') {
      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => AppCard(
          padding: const EdgeInsets.all(AppSpacing.l),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Select Bank Account', style: AppTextStyles.titleMedium),
              const SizedBox(height: AppSpacing.m),
              StatefulBuilder(
                builder: (ctx, setDs) => AppAccountPicker(
                  availableAccounts: accounts,
                  selectedAccountId: _selectedAccountId,
                  onAccountSelected: (id) =>
                      setDs(() => _selectedAccountId = id),
                  activeColor: Colors.green,
                ),
              ),
              const SizedBox(height: AppSpacing.l),
              PrimaryButton(
                onPressed: () => Navigator.pop(context, true),
                label: 'Confirm Payment',
                color: Colors.green,
              ),
              const SizedBox(height: AppSpacing.m),
            ],
          ),
        ),
      );

      if (!mounted) {
        return;
      }

      if (confirmed == true) {
        await _loanService.recordInstallmentPayment(
          inst.id,
          accountId: _selectedAccountId,
        );
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Payment recorded')));
        ref.invalidate(loanInstallmentsProvider(widget.loan.id));
        ref.invalidate(loansProvider);
      }
    } else if (option == 'manual') {
      await _loanService.recordInstallmentPayment(inst.id, isManual: true);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Installment marked as paid')),
      );
      ref.invalidate(loanInstallmentsProvider(widget.loan.id));
      ref.invalidate(loansProvider);
    }
  }

  Widget _buildPaymentOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.m),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.titleSmall),
                Text(
                  subtitle,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.arrow_forward_ios_rounded,
            size: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Future<void> _deleteLoan() async {
    final confirm = await AppDialog.showConfirm(
      context: context,
      title: 'Delete Loan?',
      message:
          'This will remove the loan from your list. You can undo it immediately after deleting.',
      confirmLabel: 'Delete',
      isDestructive: true,
    );

    if (confirm == true && mounted) {
      HapticService.instance.critical();
      Navigator.pop(context, LoanDetailAction.deleted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loan = ref.watch(loanByIdProvider(widget.loan.id)) ?? widget.loan;
    final installmentsAsync = ref.watch(loanInstallmentsProvider(widget.loan.id));
    final allAccounts = ref.watch(accountsProvider).valueOrNull ?? const <BankAccount>[];
    final accounts = allAccounts.where((a) => a.isAsset).toList();
    if (_selectedAccountId == null && accounts.isNotEmpty) {
      _selectedAccountId = accounts.first.id;
    }
    final cs = Theme.of(context).colorScheme;
    final remaining = loan.principalAmount - loan.paidAmount;
    final progress = (loan.principalAmount > 0)
        ? (loan.paidAmount / loan.principalAmount).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      appBar: SpendXAppBar(
        title: TextFormatter.toSmartTitleCase(loan.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit Loan',
            onPressed: () async {
              final result = await Navigator.push(
                context,
                AppPageRoute(
                  builder: (_) => AddLoanScreen(loan: loan),
                ),
              );
              if (result == true && mounted) {
                ref.invalidate(loansProvider);
                ref.invalidate(loanInstallmentsProvider(widget.loan.id));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: _deleteLoan,
          ),
        ],
      ),
      body: installmentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('Failed to load loan details')),
        data: (installments) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Overview Card
                  AppCard(
                    padding: const EdgeInsets.all(AppSpacing.l),
                    color: cs.surfaceContainerHigh,
                    child: Column(
                      children: [
                        Text(
                          AppFormat.currency(remaining),
                          style: AppTextStyles.headingLarge.copyWith(
                            color: cs.primary,
                          ),
                        ),
                        Text(
                          'Remaining Balance',
                          style: AppTextStyles.bodySmall.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildInfoItem(
                              'Principal',
                              AppFormat.currency(loan.principalAmount),
                            ),
                            _buildInfoItem(
                              'Paid',
                              AppFormat.currency(loan.paidAmount),
                            ),
                            _buildInfoItem(
                              'EMI',
                              AppFormat.currency(loan.monthlyInstallment),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildInfoItem(
                              'Interest',
                              '${loan.interestRate}%',
                            ),
                            _buildInfoItem('Tenure', '${loan.tenureMonths}m'),
                            _buildInfoItem(
                              'Started On',
                              DateFormat(
                                'MMM dd, yyyy',
                              ).format(loan.startDate),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildInfoItem(
                              'Next Due',
                              loan.nextDueDate != null
                                  ? DateFormat('MMM dd, yyyy').format(loan.nextDueDate!)
                                  : 'N/A',
                            ),
                            _buildInfoItem(
                              'Loan Type',
                              loan.type.name.substring(0, 1).toUpperCase() +
                                  loan.type.name.substring(1),
                            ),
                            _buildInfoItem(
                              'Bank',
                              loan.bank.isNotEmpty ? loan.bank : 'N/A',
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        LinearProgressIndicator(
                          value: progress,
                          backgroundColor: cs.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(AppRadius.s),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${(progress * 100).toStringAsFixed(0)}% Repaid',
                              style: AppTextStyles.labelSmall,
                            ),
                            StatusChip(
                              label: TextFormatter.toSmartTitleCase(
                                loan.loanStatus,
                              ),
                              type: loan.loanStatus == 'active'
                                  ? StatusChipType.success
                                  : StatusChipType.info,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),
                  const Text(
                    'Upcoming & History',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),

                  if (installments.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('No installments generated yet.'),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: installments.length,
                      itemBuilder: (ctx, i) {
                        final inst = installments[i];
                        final isPaid = inst.status == 'paid';
                        return AppCard(
                          margin: const EdgeInsets.only(bottom: AppSpacing.m),
                          padding: const EdgeInsets.all(AppSpacing.m),
                          border: isPaid
                              ? BorderSide(
                                  color: Colors.green.withValues(alpha: 0.3),
                                )
                              : null,
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: isPaid
                                    ? Colors.green.withValues(alpha: 0.1)
                                    : cs.primary.withValues(alpha: 0.1),
                                child: Icon(
                                  isPaid ? Icons.check : Icons.schedule,
                                  color: isPaid ? Colors.green : cs.primary,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Month ${i + 1}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      DateFormat(
                                        'MMM dd, yyyy',
                                      ).format(inst.dueDate),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    AppFormat.currency(inst.amount),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (!isPaid)
                                  TextButton(
                                      onPressed: () => _payInstallment(inst, accounts),
                                      child: const Text('PAY'),
                                    )
                                  else
                                    const Text(
                                      'PAID',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.green,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
      ),
    );
  }

  Widget _buildInfoItem(String label, String value) {
    return Column(
      children: [
        Text(value, style: AppTextStyles.titleSmall),
        Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
