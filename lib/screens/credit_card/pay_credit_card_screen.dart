import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/credit_card.dart';
import '../../utils/app_format.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/app_amount_field.dart';
import '../../shared/widgets/app_date_selector.dart';
import '../../shared/widgets/app_section_header.dart';
import '../../shared/widgets/app_account_picker.dart';
import '../../domain/credit/credit_card_service.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../features/salary/providers/salary_providers.dart';

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
  final TextEditingController _amountController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  String? _selectedAccountId;

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
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    if (amount <= 0) return;

    final service = CreditCardService();
    await service.processPayment(
      cardId: widget.card.id,
      paymentAmount: amount,
      date: _selectedDate,
      accountId: _selectedAccountId,
      note: 'Payment to ${widget.card.bank}',
    );

    // Invalidate providers for reactivity
    ref.invalidate(creditOutstandingProvider(widget.card.id));
    ref.invalidate(creditRecentTransactionsProvider(widget.card.id));
    ref.invalidate(liabilitiesSummaryProvider);

    if (mounted) {
      Navigator.pop(context, true);
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
                        const Text(
                          'Total Outstanding',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
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
              AppAmountField(
                controller: _amountController,
                amountColor: Colors.green,
              ),
              AppSpacing.sectionSpacer,

              const AppSectionHeader(title: 'Pay From Account'),
              accountsAsync.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (err, _) => Text(
                  'Error loading accounts: $err',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
                data: (accounts) {
                  final assetAccounts = accounts
                      .where((a) => a.isAsset)
                      .toList();
                  if (assetAccounts.isEmpty) {
                    return const Text(
                      'No accounts available. Add a bank account first.',
                      style: TextStyle(color: Colors.red, fontSize: 12),
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
                    activeColor: Colors.green,
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
      bottomNavigationBar: SafeArea(
        minimum: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: PrimaryButton(
          label: 'Confirm Payment',
          icon: Icons.account_balance_wallet_rounded,
          onPressed: _processPayment,
          tone: PrimaryButtonTone.primary,
          expand: true,
        ),
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
