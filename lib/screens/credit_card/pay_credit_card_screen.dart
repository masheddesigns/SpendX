import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/credit_card.dart';
import '../../utils/app_format.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_amount_field.dart';
import '../../shared/widgets/app_date_selector.dart';
import '../../shared/widgets/app_section_header.dart';
import '../../shared/widgets/app_account_picker.dart';
import '../../shared/widgets/loading_state_widget.dart';
import '../../domain/credit/credit_card_service.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../features/salary/providers/salary_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart'
    show paginatedTransactionsProvider;
import '../../data/providers.dart' as app_data;
import '../../services/data_change_bus.dart';
import '../../widgets/form/spendx_sticky_bottom_bar.dart';

class PayCreditCardScreen extends ConsumerStatefulWidget {
  final CreditCard card;
  final double outstanding;

  const PayCreditCardScreen({
    super.key,
    required this.card,
    required this.outstanding,
  });

  @override
  ConsumerState<PayCreditCardScreen> createState() =>
      _PayCreditCardScreenState();
}

class _PayCreditCardScreenState extends ConsumerState<PayCreditCardScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _amountController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  String? _selectedAccountId;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    if (widget.outstanding > 0) {
      _amountController.text = widget.outstanding.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _processPayment() async {
    if (!(_formKey.currentState?.validate() ?? false) || _isProcessing) return;
    final amount = double.parse(_amountController.text.trim());

    final accounts = ref.read(bankAccountsProvider).valueOrNull ?? [];
    final fallbackAccount = accounts.where((a) => a.isAsset).firstOrNull?.id;
    final payingAccountId = _selectedAccountId ?? fallbackAccount;
    if (payingAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add a bank account before making a payment.'),
        ),
      );
      return;
    }

    setState(() => _isProcessing = true);
    try {
      final service = CreditCardService();
      await service.processPayment(
        cardId: widget.card.id,
        paymentAmount: amount,
        date: _selectedDate,
        accountId: payingAccountId,
        note: 'Payment to ${widget.card.bank}',
      );

      // Invalidate providers for reactivity.
      ref.invalidate(creditOutstandingProvider(widget.card.id));
      ref.invalidate(creditRecentTransactionsProvider(widget.card.id));
      ref.invalidate(liabilitiesSummaryProvider);
      ref.invalidate(app_data.cardsProvider);
      ref.invalidate(app_data.accountsProvider);
      ref.invalidate(bankAccountsProvider);
      ref.invalidate(app_data.transactionsProvider);
      ref.invalidate(paginatedTransactionsProvider);
      ref.invalidate(app_data.remindersProvider);
      ref.invalidate(app_data.safeToSpendProvider);
      DataChangeBus.instance.notify();

      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Payment could not be saved. Please try again.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accountsAsync = ref.watch(bankAccountsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Pay ${widget.card.bank}'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      cs.primaryContainer.withValues(alpha: 0.4),
                      cs.surfaceContainerHigh,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.1)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Total Outstanding',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          AppFormat.currency(widget.outstanding),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _shortcutChip('Pay Full', widget.outstanding),
                        const SizedBox(width: 8),
                        _shortcutChip(
                          'Pay Partial',
                          widget.outstanding * 0.1,
                        ), // 10% example
                      ],
                    ),
                  ],
                ),
              ),
              AppSpacing.sectionSpacer,

              const AppSectionHeader(
                title: 'Payment Amount',
                padding: EdgeInsets.only(bottom: AppSpacing.sm),
              ),
              Form(
                key: _formKey,
                child: AppAmountField(
                  controller: _amountController,
                  amountColor: cs.secondary,
                  validator: (value) {
                    final amount = double.tryParse((value ?? '').trim());
                    if (amount == null || !amount.isFinite || amount <= 0) {
                      return 'Enter an amount greater than zero';
                    }
                    return null;
                  },
                ),
              ),
              AppSpacing.sectionSpacer,

              const AppSectionHeader(title: 'Pay From Account'),
              accountsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: LoadingStateWidget(message: 'Loading accounts...'),
                ),
                error: (_, _) => _AccountLoadError(
                  onRetry: () => ref.invalidate(bankAccountsProvider),
                ),
                data: (accounts) {
                  final assetAccounts = accounts
                      .where((a) => a.isAsset)
                      .toList();
                  if (assetAccounts.isEmpty) {
                    return Text(
                      'No accounts available. Add a bank account first.',
                      style: TextStyle(color: cs.error, fontSize: 12),
                    );
                  }

                  // Initialize selected account ID if not set
                  if (_selectedAccountId == null && assetAccounts.isNotEmpty) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        setState(
                          () => _selectedAccountId = assetAccounts.first.id,
                        );
                      }
                    });
                  }

                  return AppAccountPicker(
                    availableAccounts: assetAccounts,
                    selectedAccountId: _selectedAccountId,
                    onAccountSelected: (id) =>
                        setState(() => _selectedAccountId = id),
                    activeColor: cs.secondary,
                  );
                },
              ),
              AppSpacing.sectionSpacer,

              const AppSectionHeader(title: 'Payment Date'),
              AppDateSelector(
                selectedDate: _selectedDate,
                onDateSelected: (date) => setState(() => _selectedDate = date),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SpendXStickyBottomBar.singleAction(
        primaryLabel: 'Confirm Payment',
        primaryIcon: Icons.account_balance_wallet_rounded,
        isPrimaryLoading: _isProcessing,
        onPrimaryPressed: _isProcessing ? null : _processPayment,
      ),
    );
  }

  Widget _shortcutChip(String label, double amount) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: () {
        setState(() {
          _amountController.text = amount.toStringAsFixed(0);
        });
      },
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }
}

class _AccountLoadError extends StatelessWidget {
  const _AccountLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Could not load accounts.',
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ],
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: onRetry, child: const Text('Retry')),
          ),
        ],
      ),
    );
  }
}
