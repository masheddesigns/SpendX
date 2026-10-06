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
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_dialog.dart';
import 'add_loan_screen.dart';
import '../../shared/widgets/status_chip.dart';
import '../../utils/text_formatter.dart';
import '../../utils/app_format.dart';
import '../../shared/widgets/app_account_picker.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/glass/spendx_scaffold.dart';
import '../../shared/widgets/glass/spendx_glass_surface.dart';
import '../../shared/widgets/glass/spendx_glass_sheet.dart';
import '../../shared/widgets/glass/spendx_glass_button.dart';
import '../../widgets/custom_snackbar.dart';

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
    final option = await SpendXGlassSheet.show<String>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Choose Payment Method',
              style: AppTextStyles.heading.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'EMI Amount: ${AppFormat.currency(inst.amount)}',
              style: AppTextStyles.body.copyWith(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.secondaryText
                    : const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 20),
            _buildPaymentOption(
              icon: Icons.account_balance_wallet_rounded,
              title: 'Pay via Account',
              subtitle: 'Deduct from bank and sync with ledger',
              onTap: () => Navigator.pop(sheetContext, 'account'),
            ),
            const SizedBox(height: 12),
            _buildPaymentOption(
              icon: Icons.check_circle_outline_rounded,
              title: 'Mark as Paid',
              subtitle: 'Manually mark without affecting ledger',
              onTap: () => Navigator.pop(sheetContext, 'manual'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    if (option == 'account') {
      final confirmed = await SpendXGlassSheet.show<bool>(
        context: context,
        builder: (sheetContext) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Select Bank Account',
                style: AppTextStyles.heading.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              StatefulBuilder(
                builder: (ctx, setDs) => AppAccountPicker(
                  availableAccounts: accounts,
                  selectedAccountId: _selectedAccountId,
                  onAccountSelected: (id) =>
                      setDs(() => _selectedAccountId = id),
                  activeColor: AppColors.success,
                ),
              ),
              const SizedBox(height: 20),
              SpendXGlassButton(
                variant: SpendXGlassButtonVariant.primary,
                onPressed: () => Navigator.pop(sheetContext, true),
                child: const Text('Confirm Payment'),
              ),
              const SizedBox(height: 12),
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
        CustomSnackBar.show(
          context,
          message: 'Payment recorded successfully',
        );
        ref.invalidate(loanInstallmentsProvider(widget.loan.id));
        ref.invalidate(loansProvider);
      }
    } else if (option == 'manual') {
      await _loanService.recordInstallmentPayment(inst.id, isManual: true);
      if (!mounted) {
        return;
      }
      CustomSnackBar.show(
        context,
        message: 'Installment marked as paid',
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: SpendXGlassSurface(
        level: SpendXGlassLevel.interactive,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: isDark ? 0.20 : 0.12),
              ),
              child: Icon(icon, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppColors.primaryText : const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppColors.secondaryText : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: isDark ? AppColors.mutedText : const Color(0xFF94A3B8),
            ),
          ],
        ),
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

    return SpendXScaffold(
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
            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
            onPressed: _deleteLoan,
          ),
        ],
      ),
      body: installmentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('Failed to load loan details')),
        data: (installments) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Overview Card
                  SpendXGlassSurface(
                    level: SpendXGlassLevel.elevated,
                    borderRadius: BorderRadius.circular(20),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text(
                          AppFormat.currency(remaining),
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            letterSpacing: -0.6,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
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

                  const SizedBox(height: 28),
                  Text(
                    'Upcoming & History',
                    style: AppTextStyles.heading.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 14),

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
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: SpendXGlassSurface(
                            level: SpendXGlassLevel.base,
                            borderRadius: BorderRadius.circular(16),
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: isPaid
                                      ? AppColors.success.withValues(alpha: 0.15)
                                      : cs.primary.withValues(alpha: 0.12),
                                  child: Icon(
                                    isPaid ? Icons.check_rounded : Icons.schedule_rounded,
                                    color: isPaid ? AppColors.success : cs.primary,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Month ${i + 1}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        DateFormat(
                                          'MMM dd, yyyy',
                                        ).format(inst.dueDate),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).brightness == Brightness.dark
                                              ? AppColors.secondaryText
                                              : const Color(0xFF64748B),
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
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14.5,
                                        fontFeatures: [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    if (!isPaid)
                                      GestureDetector(
                                        onTap: () => _payInstallment(inst, accounts),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: AppColors.primary.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            'PAY',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ),
                                      )
                                    else
                                      const Text(
                                        'PAID',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.success,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
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
