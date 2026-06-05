import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/accounts/providers/account_providers.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../features/merchant_rules/providers/merchant_rule_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../core/utils/category_classifier.dart';
import '../../core/utils/merchant_extractor.dart';
import '../../data/providers.dart' show cardsProvider;
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/transaction.dart';
import '../../models/category.dart';
import '../../services/settings_service.dart';
import '../../services/haptic_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/app_text_field.dart' as shared;
import '../../shared/widgets/app_amount_field.dart';
import '../../shared/widgets/app_category_picker.dart';
import '../../shared/widgets/app_date_selector.dart';
import '../../shared/widgets/app_section_header.dart';
import '../../shared/widgets/app_payment_method_picker.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_dialog.dart';
import '../../shared/widgets/custom_snackbar.dart';
import '../../utils/text_formatter.dart';
import '../../services/gemini_service.dart';
import '../../widgets/receipt_scan_overlay.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../bank/add_bank_account_screen.dart';
import '../../widgets/form/add_category_sheet.dart';
import '../../shared/widgets/app_page_route.dart';

class AddExpenseScreen extends ConsumerStatefulWidget {
  final String initialType; // 'expense' or 'income'
  final Transaction? existingTransaction;
  final String? initialCategoryId;
  final Map<String, String?>? prefillData; // Data from Gemini AI

  const AddExpenseScreen({
    super.key,
    this.initialType = 'expense',
    this.existingTransaction,
    this.initialCategoryId,
    this.prefillData,
  });

  @override
  ConsumerState<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends ConsumerState<AddExpenseScreen> {
  late String _selectedType;
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  String? _selectedCategoryId;

  List<Category> _availableCategories = [];
  List<PaymentMethodItem> _availablePaymentMethods = [];
  List<double> _recentAmounts = [];
  String? _selectedPaymentMethodId;
  bool _didExplicitCategorySelection = false;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(() => setState(() {}));
    _notesController.addListener(() {
      unawaited(_maybeAutoSelectCategoryFromNotes());
    });
    _selectedCategoryId = widget.initialCategoryId;
    if (widget.existingTransaction != null) {
      final txn = widget.existingTransaction!;
      _selectedType = txn.type;
      _amountController.text = txn.amount.toString();
      _notesController.text = txn.notes;
      _selectedDate = txn.date;
      _selectedCategoryId = txn.categoryId;
      _selectedPaymentMethodId = txn.accountId;
    } else {
      _selectedType = widget.initialType;
      _restoreSmartDefaults();
    }
    _loadInitialData();
  }

  void _restoreSmartDefaults() {
    final settings = SettingsService.instance;
    final normalizedType = _normalizedType;
    _recentAmounts = settings.getRecentExpenseAmounts(type: normalizedType);
    _selectedCategoryId ??= settings.getLastExpenseCategoryId(
      type: normalizedType,
    );
    _selectedPaymentMethodId ??= settings.getLastExpensePaymentSourceId(
      type: normalizedType,
    );
  }

  Future<void> _loadInitialData() async {
    final List<Category> categories = await ref.read(categoriesProvider.future);
    final List<BankAccount> accounts = await ref.read(accountsProvider.future);
    List<CreditCard> cards = [];
    try {
      cards = await ref.read(cardsProvider.future);
    } catch (_) {
      // Cards may not exist yet — non-fatal
    }
    final settings = SettingsService.instance;
    final normalizedType = _normalizedType;
    final storedCategoryId = settings.getLastExpenseCategoryId(
      type: normalizedType,
    );
    final storedPaymentId = settings.getLastExpensePaymentSourceId(
      type: normalizedType,
    );

    if (!mounted) return;

    setState(() {
      _recentAmounts = settings.getRecentExpenseAmounts(type: normalizedType);
      _availableCategories = categories
          .where((c) => c.type == _selectedType)
          .toList();

      _availablePaymentMethods = [
        ...accounts.map(
          (a) => PaymentMethodItem(
            id: a.id,
            name: a.name,
            type: 'bank',
            icon: _getAccountIcon(a.accountType),
          ),
        ),
        ...cards.map(
          (c) => PaymentMethodItem(
            id: c.id,
            name: '${c.name} ••${c.last4}',
            type: 'credit_card',
            icon: _getCardIcon(c.cardType),
          ),
        ),
      ];

      final hasSelectedPayment = _availablePaymentMethods.any(
        (method) => method.id == _selectedPaymentMethodId,
      );
      if (!hasSelectedPayment) {
        _selectedPaymentMethodId = null;
      }

      if (_selectedPaymentMethodId == null &&
          _availablePaymentMethods.isNotEmpty) {
        final storedPayment = _availablePaymentMethods.where(
          (method) => method.id == storedPaymentId,
        );
        if (storedPayment.isNotEmpty) {
          _selectedPaymentMethodId = storedPayment.first.id;
        } else {
          _selectedPaymentMethodId = _availablePaymentMethods.first.id;
        }
      }

      final hasSelectedCategory = _availableCategories.any(
        (category) => category.id == _selectedCategoryId,
      );
      if (!hasSelectedCategory) {
        _selectedCategoryId = null;
      }

      if (_selectedCategoryId == null && _availableCategories.isNotEmpty) {
        final storedCategory = _availableCategories.where(
          (category) => category.id == storedCategoryId,
        );
        _selectedCategoryId = storedCategory.isNotEmpty
            ? storedCategory.first.id
            : _availableCategories.first.id;
      }
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _maybeAutoSelectCategoryFromNotes() async {
    if (_selectedCategoryId != null || _availableCategories.isEmpty) {
      return;
    }

    final note = _notesController.text;
    final keyword = MerchantExtractor.extract(note);
    if (keyword.length >= 3) {
      final rule = await ref
          .read(merchantRuleRepoProvider)
          .getByKeyword(keyword);
      if (rule != null) {
        final learned = _availableCategories.where(
          (c) => c.id == rule.categoryId,
        );
        if (learned.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _selectedCategoryId = learned.first.id;
          });
          return;
        }
      }
    }

    final detected = CategoryClassifier.detect(text: note, type: _selectedType);

    if (detected == null) {
      return;
    }

    final match = _availableCategories.where((c) => c.name == detected);
    if (match.isEmpty) {
      return;
    }

    final categoryId = match.first.id;
    if (categoryId == _selectedCategoryId) {
      return;
    }

    setState(() {
      _selectedCategoryId = categoryId;
    });
  }

  bool get _isValid {
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    return amount > 0; // Account is optional
  }

  String get _normalizedType => _selectedType.trim().toLowerCase();

  Future<void> _saveTransaction() async {
    if (_amountController.text.isEmpty) {
      CustomSnackBar.show(
        context,
        message: 'Please enter an amount',
        isError: true,
      );
      return;
    }

    final double amount = double.tryParse(_amountController.text) ?? 0.0;

    if (amount <= 0) {
      CustomSnackBar.show(
        context,
        message: 'Amount must be greater than zero',
        isError: true,
      );
      return;
    }

    // Account is optional — transaction can exist without a linked account

    final newTransaction = Transaction(
      id: widget.existingTransaction?.id,
      userId: widget.existingTransaction?.userId ?? 'offline_user',
      type: _selectedType,
      categoryId: _selectedCategoryId,
      accountId: _selectedPaymentMethodId,
      amount: amount,
      date: _selectedDate,
      notes: TextFormatter.normalizeName(_notesController.text),
      tags: const [],
      source: 'manual',
      relatedEntityId: null,
      location: null,
      createdAt: widget.existingTransaction?.createdAt,
    );

    if (widget.existingTransaction != null) {
      await ref.read(updateTransactionProvider)(
        oldTransaction: widget.existingTransaction!,
        newTransaction: newTransaction,
      );
    } else {
      await ref.read(addTransactionProvider)(newTransaction);
    }

    if (_didExplicitCategorySelection &&
        _selectedCategoryId != null &&
        _notesController.text.trim().isNotEmpty) {
      unawaited(
        ref.read(learnMerchantRuleProvider)(
          text: _notesController.text,
          categoryId: _selectedCategoryId!,
        ),
      );
    }

    unawaited(
      SettingsService.instance.saveExpenseDefaults(
        type: _normalizedType,
        categoryId: _selectedCategoryId,
        amount: amount,
        paymentSourceId: _selectedPaymentMethodId,
        paymentSourceType: _selectedPaymentTypeForStorage,
      ),
    );

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _scanReceipt() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Pick from Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null || !mounted) return;

    // Show scanning overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ReceiptScanOverlay(),
    );

    try {
      final result = await GeminiService.instance.scanReceipt(File(picked.path));
      if (mounted) Navigator.pop(context); // dismiss overlay

      if (result.containsKey('error')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(result['error'] ?? 'Scan failed')));
        }
        return;
      }

      // Pre-fill fields from scan result
      if (mounted) {
        setState(() {
          if (result['amount'] != null) {
            _amountController.text = result['amount']!;
          }
          if (result['merchant'] != null) {
            _notesController.text = result['merchant']!;
          }
        });
        if (result['amount'] != null || result['merchant'] != null) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Receipt scanned successfully')));
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // dismiss overlay on error
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Scan failed: $e')));
      }
    }
  }

  void _deleteTransaction() async {
    final confirm = await AppDialog.showConfirm(
      context: context,
      title: 'Delete Transaction?',
      message:
          'This will remove the transaction. You can undo this immediately from the dashboard.',
      confirmLabel: 'Delete',
      isDestructive: true,
    );

    if (confirm == true && widget.existingTransaction != null) {
      await ref.read(deleteTransactionProvider)(widget.existingTransaction!.id);
      if (mounted) {
        Navigator.pop(context, true);
      }
    }
  }

  Widget _buildTypeToggle() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xs),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedType = 'expense';
                  _selectedCategoryId = null;
                  _selectedPaymentMethodId = null;
                });
                _loadInitialData();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
                decoration: BoxDecoration(
                  color: _selectedType == 'expense'
                      ? Theme.of(context).colorScheme.error
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Expense',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: _selectedType == 'expense'
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedType = 'income';
                  _selectedCategoryId = null;
                  _selectedPaymentMethodId = null;
                });
                _loadInitialData();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
                decoration: BoxDecoration(
                  color: _selectedType == 'income'
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Income',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: _selectedType == 'income'
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    Color headerColor;
    if (_selectedType == 'expense') {
      headerColor = Theme.of(context).colorScheme.error;
    } else {
      headerColor = Theme.of(context).colorScheme.primary;
    }

    return Scaffold(
      appBar: SpendXAppBar(
        title: widget.existingTransaction != null
            ? 'Edit ${_selectedType == 'expense' ? 'Expense' : 'Income'}'
            : 'Add ${_selectedType == 'expense' ? 'Expense' : 'Income'}',
        actions: [
          if (widget.existingTransaction == null)
            IconButton(
              icon: const Icon(Icons.document_scanner_rounded, size: 20),
              tooltip: 'Scan Receipt',
              onPressed: _scanReceipt,
            ),
          if (widget.existingTransaction != null)
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
                size: 20,
              ),
              tooltip: 'Delete Transaction',
              onPressed: _deleteTransaction,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.m,
            AppSpacing.m,
            AppSpacing.m,
            132,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTypeToggle(),
              const SizedBox(height: AppSpacing.l),

              // Amount Input
              const AppSectionHeader(
                title: 'Amount',
                padding: EdgeInsets.only(bottom: AppSpacing.sm),
              ),
              AppAmountField(
                controller: _amountController,
                amountColor: headerColor,
              ),
              if (_recentAmounts.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s),
                Wrap(
                  spacing: AppSpacing.s,
                  runSpacing: AppSpacing.s,
                  children: _recentAmounts.map((amount) {
                    return ActionChip(
                      label: Text(
                        '${settings.currencySymbol}${_formatQuickAmount(amount)}',
                      ),
                      onPressed: () => _applyQuickAmount(amount),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh,
                      side: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.outline.withValues(alpha: 0.16),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    );
                  }).toList(),
                ),
              ],

              Divider(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1), height: 32),

              // Category Selector
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const AppSectionHeader(title: 'Category'),
                  TextButton.icon(
                    onPressed: () async {
                      final newCat = await showModalBottomSheet<Category>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) =>
                            AddCategorySheet(initialType: _selectedType),
                      );
                      if (newCat != null) {
                        await _loadInitialData();
                        setState(() {
                          _selectedCategoryId = newCat.id;
                          _didExplicitCategorySelection = true;
                        });
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
                activeColor: headerColor,
                onCategorySelected: (id) => setState(() {
                  _selectedCategoryId = id;
                  _didExplicitCategorySelection = true;
                }),
              ),

              AppSpacing.sectionSpacer,

              // Payment Method Selector
              if (_availablePaymentMethods.isNotEmpty) ...[
                const AppSectionHeader(title: 'Payment Method'),
                AppPaymentMethodPicker(
                  availableMethods: _availablePaymentMethods,
                  selectedMethodId: _selectedPaymentMethodId,
                  activeColor: headerColor,
                  onMethodSelected: (id) {
                    setState(() {
                      _selectedPaymentMethodId = id;
                    });
                  },
                ),
                AppSpacing.sectionSpacer,
              ] else ...[
                const AppSectionHeader(title: 'Payment Method'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.m),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Add an account before saving transactions.',
                        ),
                        const SizedBox(height: AppSpacing.s),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final result = await Navigator.push(
                              context,
                              AppPageRoute(
                                builder: (_) => const AddBankAccountScreen(),
                              ),
                            );
                            if (result == true) {
                              await _loadInitialData();
                            }
                          },
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Add Account'),
                        ),
                      ],
                    ),
                  ),
                ),
                AppSpacing.sectionSpacer,
              ],

              AppSpacing.sectionSpacer,

              // Date Picker
              const AppSectionHeader(title: 'Date'),
              AppDateSelector(
                selectedDate: _selectedDate,
                onDateSelected: (date) => setState(() => _selectedDate = date),
              ),

              AppSpacing.itemSpacer,

              shared.AppTextField(
                controller: _notesController,
                label: 'Notes (Optional)',
                prefix: const Icon(Icons.notes_rounded),
              ),

              const SizedBox(height: AppSpacing.m),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: EdgeInsets.fromLTRB(
          AppSpacing.m,
          AppSpacing.s,
          AppSpacing.m,
          AppSpacing.m + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: PrimaryButton(
          label: 'Save Transaction',
          onPressed: _isValid ? _saveTransaction : null,
          backgroundColor: headerColor,
          fullWidth: true,
        ),
      ),
    );
  }

  IconData _getCardIcon(String cardType) {
    switch (cardType) {
      case 'visa':
        return Icons.credit_card_rounded;
      case 'mastercard':
        return Icons.credit_card_rounded;
      case 'rupay':
        return Icons.credit_card_rounded;
      case 'amex':
        return Icons.credit_card_rounded;
      default:
        return Icons.credit_card_rounded;
    }
  }

  IconData _getAccountIcon(String type) {
    switch (type) {
      case 'savings':
        return Icons.account_balance_rounded;
      case 'current':
        return Icons.account_balance_wallet_rounded;
      case 'fd':
        return Icons.lock_clock_rounded;
      case 'cash':
        return Icons.payments_rounded;
      case 'wallet':
        return Icons.account_balance_wallet_rounded;
      case 'ppf':
        return Icons.savings_rounded;
      case 'stock':
        return Icons.trending_up_rounded;
      case 'mutual_fund':
        return Icons.pie_chart_rounded;
      default:
        return Icons.account_balance_rounded;
    }
  }

  String? get _selectedPaymentTypeForStorage {
    if (_selectedPaymentMethodId == null) {
      return null;
    }
    return 'bank';
  }

  void _applyQuickAmount(double amount) {
    HapticService.instance.selection();
    final formatted = _formatEditableAmount(amount);
    _amountController.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  String _formatQuickAmount(double amount) {
    if (amount == amount.roundToDouble()) {
      return amount.toStringAsFixed(0);
    }
    return amount.toStringAsFixed(2);
  }

  String _formatEditableAmount(double amount) {
    if (amount == amount.roundToDouble()) {
      return amount.toStringAsFixed(0);
    }
    return amount
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
}
