import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../models/category.dart';
import '../../models/credit_card.dart';
import '../../models/credit_transaction.dart';
import '../../models/ledger_transaction.dart';
import '../../data/providers.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_section_header.dart';
import '../../shared/widgets/app_amount_field.dart';
import '../../shared/widgets/app_date_selector.dart';
import '../../shared/widgets/app_category_picker.dart';
import '../../widgets/form/add_category_sheet.dart'; // This needs to be moved/refactored too, but for now fixed imports
import '../../features/liabilities/providers/liabilities_providers.dart';

class AddCreditTransactionScreen extends ConsumerStatefulWidget {
  final CreditCard card;

  const AddCreditTransactionScreen({super.key, required this.card});

  @override
  ConsumerState<AddCreditTransactionScreen> createState() =>
      _AddCreditTransactionScreenState();
}

class _AddCreditTransactionScreenState
    extends ConsumerState<AddCreditTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _merchantController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  List<Category> _availableCategories = [];
  String? _selectedCategoryId;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(() => setState(() {}));
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final categories = await ref.read(categoriesProvider.future);
    if (!mounted) return;
    setState(() {
      _availableCategories = categories
          .where((category) => category.type == 'expense')
          .toList();
      if (_availableCategories.isNotEmpty) {
        _selectedCategoryId = _availableCategories.first.id;
      }
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _merchantController.dispose();
    super.dispose();
  }

  Future<void> _saveTransaction() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    if (amount <= 0) return;

    final noteText = _merchantController.text.trim().isNotEmpty
        ? _merchantController.text.trim()
        : 'Manual Purchase';

    final txn = CreditTransaction(
      id: const Uuid().v4(),
      cardId: widget.card.id,
      amount: amount,
      date: _selectedDate,
      category: noteText,
      categoryId: _selectedCategoryId,
      note: noteText,
      type: 'purchase',
      status: 'active',
    );

    await ref
        .read(creditPurchaseMutationProvider.notifier)
        .addPurchase(
          transaction: txn,
          ledgerTransaction: LedgerTransaction(
            type: LedgerType.credit_purchase,
            amount: amount,
            date: _selectedDate,
            creditCardId: widget.card.id,
            categoryId: _selectedCategoryId,
            note: noteText,
            referenceId: txn.id,
          ),
          cardId: widget.card.id,
        );

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SpendXAppBar(title: 'Credit Purchase'),
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSectionHeader(
                  title: 'Amount',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppAmountField(
                  controller: _amountController,
                  amountColor: Theme.of(context).colorScheme.primary,
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Please enter an amount';
                    }
                    final amount = double.tryParse(val.trim());
                    if (amount == null || !amount.isFinite || amount <= 0) {
                      return 'Enter an amount greater than zero';
                    }
                    return null;
                  },
                ),
                AppSpacing.sectionSpacer,

                const AppSectionHeader(
                  title: 'Date',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppDateSelector(
                  selectedDate: _selectedDate,
                  onDateSelected: (date) => setState(() => _selectedDate = date),
                ),
                AppSpacing.sectionSpacer,

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const AppSectionHeader(
                      title: 'Category',
                      padding: EdgeInsets.only(bottom: AppSpacing.s),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final newCat = await showModalBottomSheet<Category>(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) =>
                              const AddCategorySheet(initialType: 'expense'),
                        );
                        if (newCat != null) {
                          await _loadCategories();
                          setState(() => _selectedCategoryId = newCat.id);
                        }
                      },
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        size: 18,
                      ),
                      label: const Text('Add New'),
                    ),
                  ],
                ),
                AppCategoryPicker(
                  availableCategories: _availableCategories,
                  selectedCategoryId: _selectedCategoryId,
                  activeColor: Theme.of(context).colorScheme.primary,
                  onCategorySelected: (id) =>
                      setState(() => _selectedCategoryId = id),
                ),
                AppSpacing.sectionSpacer,

                const AppSectionHeader(
                  title: 'Merchant',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppTextField(
                  controller: _merchantController,
                  labelText: 'e.g. Amazon, Starbucks',
                  prefixIcon: Icons.storefront_rounded,
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Please enter a merchant or description';
                    }
                    if (val.trim().length > 100) {
                      return 'Merchant must be 100 characters or less';
                    }
                    return null;
                  },
                ),
              ],
            ),
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
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.m),
                  ),
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                ),
                child: Text('Cancel', style: AppTextStyles.titleSmall),
              ),
            ),
            const SizedBox(width: AppSpacing.m),
            Expanded(
              flex: 2,
              child: PrimaryButton(
                label: 'Save Purchase',
                onPressed: _saveTransaction,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
