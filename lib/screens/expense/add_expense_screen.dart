import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/accounts/providers/account_providers.dart';
import '../../features/categories/providers/category_providers.dart';
import '../../features/merchant_rules/providers/merchant_rule_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart'
    hide financialTransactionServiceProvider;
import '../../core/utils/category_classifier.dart';
import '../../core/utils/merchant_extractor.dart';
import '../../data/providers.dart'
    show
        cardsProvider,
        financialTransactionServiceProvider,
        invalidateAllFinancialProviders;
import '../../data/core/tracked_database_task_queue.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/transaction.dart';
import '../../models/category.dart';
import '../../services/settings_service.dart';
import '../../services/smart_category_classifier.dart';
import '../../services/haptic_service.dart';
import '../../domain/credit/credit_card_service.dart';
import '../bank/account_list_screen.dart' show resolveAccountDisplayName;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_text_field.dart' as shared;
import '../../shared/widgets/app_amount_field.dart';
import '../../shared/widgets/app_category_picker.dart';
import '../../shared/widgets/app_date_selector.dart';
import '../../shared/widgets/app_payment_method_picker.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_dialog.dart';
import '../../shared/widgets/custom_snackbar.dart';
import '../../shared/widgets/app_form_error_summary.dart';
import '../../utils/text_formatter.dart';
import '../../services/gemini_service.dart';
import '../../widgets/receipt_scan_overlay.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../bank/add_bank_account_screen.dart';
import '../../shared/widgets/glass/spendx_scaffold.dart';
import '../../shared/widgets/glass/spendx_glass_surface.dart';
import '../../shared/widgets/glass/spendx_glass_button.dart';
import '../../shared/widgets/playful/spendx_playful.dart';
import '../../theme/app_theme.dart' as modern_theme;
import '../../widgets/form/add_category_sheet.dart';
import '../../shared/widgets/app_page_route.dart';

class AddExpenseScreen extends ConsumerStatefulWidget {
  final String initialType; // 'expense' or 'income'
  final Transaction? existingTransaction;
  final String? initialCategoryId;
  final String? initialPaymentSourceId;
  final Map<String, String?>? prefillData; // Data from Gemini AI

  const AddExpenseScreen({
    super.key,
    this.initialType = 'expense',
    this.existingTransaction,
    this.initialCategoryId,
    this.initialPaymentSourceId,
    this.prefillData,
  });

  @override
  ConsumerState<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends ConsumerState<AddExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  List<String> _formErrors = [];
  late String _selectedType;
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final FocusNode _amountFocusNode = FocusNode();
  final FocusNode _notesFocusNode = FocusNode();
  DateTime _selectedDate = DateTime.now();
  String? _selectedCategoryId;

  List<Category> _availableCategories = [];
  List<PaymentMethodItem> _availablePaymentMethods = [];
  List<double> _recentAmounts = [];
  String? _selectedPaymentMethodId;
  String? _destinationPaymentMethodId;
  bool _didExplicitCategorySelection = false;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(() => setState(() {}));
    _notesController.addListener(() {
      TrackedDatabaseTaskQueue.instance.runTracked(
        'add_expense_auto_select_category',
        () => _maybeAutoSelectCategoryFromNotes(),
      );
    });
    _selectedCategoryId = widget.initialCategoryId;
    _selectedPaymentMethodId = widget.initialPaymentSourceId;
    if (widget.existingTransaction != null) {
      final txn = widget.existingTransaction!;
      _selectedType = (txn.type == 'credit_card_purchase')
          ? 'expense'
          : txn.type;
      _amountController.text = txn.amount.toString();
      _notesController.text = txn.notes;
      _selectedDate = txn.date;
      _selectedCategoryId = txn.categoryId;
      _selectedPaymentMethodId = txn.accountId;
      _destinationPaymentMethodId = txn.relatedEntityId;
    } else {
      if (widget.initialType == 'transfer' || widget.initialType == 'moved') {
        _selectedType = 'transfer';
      } else if (widget.initialType == 'credit_card_purchase') {
        _selectedType = 'expense';
      } else {
        _selectedType = widget.initialType;
      }
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
            name: resolveAccountDisplayName(a.name),
            type: 'bank',
            icon: _getAccountIcon(a.accountType),
          ),
        ),
        ...cards.map(
          (c) => PaymentMethodItem(
            id: c.id,
            name: resolveAccountDisplayName(
              c.name.isNotEmpty ? c.name : '${c.bank} Card ••${c.last4}',
            ),
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

      if (_destinationPaymentMethodId == null &&
          _availablePaymentMethods.length >= 2) {
        _destinationPaymentMethodId = _availablePaymentMethods
            .where((m) => m.id != _selectedPaymentMethodId)
            .firstOrNull
            ?.id;
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
    _scrollController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    _amountFocusNode.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }

  Future<void> _maybeAutoSelectCategoryFromNotes() async {
    if (_didExplicitCategorySelection ||
        _selectedCategoryId != null ||
        _availableCategories.isEmpty) {
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

  bool get _isSpecialNonCategorizedType {
    if (widget.existingTransaction == null) return false;
    final t = widget.existingTransaction!.type;
    return t == 'credit_payment' ||
        t == 'credit_card_payment' ||
        t == 'transfer' ||
        t == 'loan_repayment' ||
        t == 'loan_disbursement' ||
        t == 'loan_payment';
  }

  String get _appBarTitle {
    if (widget.existingTransaction != null) {
      final t = widget.existingTransaction!.type;
      if (t == 'credit_payment' || t == 'credit_card_payment') {
        return 'Edit Card Payment';
      }
      if (t == 'loan_repayment' || t == 'loan_payment') {
        return 'Edit Loan Repayment';
      }
      if (t == 'loan_disbursement') return 'Edit Loan Disbursement';
      if (t == 'transfer') return 'Edit Transfer';
      return _selectedType == 'expense'
          ? 'Edit Expense'
          : (_selectedType == 'transfer' ? 'Edit Transfer' : 'Edit Income');
    }
    return _selectedType == 'expense'
        ? 'Add Expense'
        : (_selectedType == 'transfer' ? 'Move Funds' : 'Add Income');
  }

  String get _normalizedType => _selectedType.trim().toLowerCase();

  Future<void> _saveTransaction() async {
    final errors = <String>[];
    final double amount = double.tryParse(_amountController.text.trim()) ?? 0.0;
    if (_amountController.text.trim().isEmpty) {
      errors.add('Please enter an amount');
    } else if (amount <= 0) {
      errors.add('Amount must be greater than zero');
    }

    if (_selectedType != 'transfer' &&
        !_isSpecialNonCategorizedType &&
        _selectedCategoryId == null) {
      errors.add('Please select a category');
    }

    if (_selectedType == 'transfer') {
      if (_selectedPaymentMethodId == null ||
          _destinationPaymentMethodId == null) {
        errors.add('Please select both source and destination accounts');
      } else if (_selectedPaymentMethodId == _destinationPaymentMethodId) {
        errors.add('Source and destination cannot be the same account');
      }
    }

    setState(() => _formErrors = errors);

    if (!(_formKey.currentState?.validate() ?? false) || errors.isNotEmpty) {
      SoundEffectsService.instance.alert();
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: AppMotion.normal,
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }

    if (_selectedType == 'transfer') {
      final destMethod = _availablePaymentMethods
          .where((m) => m.id == _destinationPaymentMethodId)
          .firstOrNull;
      final isDestCreditCard = destMethod?.type == 'credit_card';

      if (isDestCreditCard) {
        await CreditCardService().processPayment(
          cardId: _destinationPaymentMethodId!,
          paymentAmount: amount,
          date: _selectedDate,
          accountId: _selectedPaymentMethodId,
          note: _notesController.text.trim().isNotEmpty
              ? _notesController.text.trim()
              : 'Payment to ${destMethod?.name ?? "Credit Card"}',
        );
      } else {
        final tx = Transaction(
          id: widget.existingTransaction?.id,
          type: 'transfer',
          amount: amount,
          accountId: _selectedPaymentMethodId!,
          relatedEntityId: _destinationPaymentMethodId!,
          date: _selectedDate,
          notes: _notesController.text.trim().isNotEmpty
              ? _notesController.text.trim()
              : 'Internal Transfer',
          userId: 'offline_user',
          source: 'manual',
        );
        if (widget.existingTransaction != null) {
          await ref.read(updateTransactionProvider)(
            oldTransaction: widget.existingTransaction!,
            newTransaction: tx,
          );
        } else {
          await ref
              .read(financialTransactionServiceProvider)
              .createTransfer(tx);
        }
      }

      invalidateAllFinancialProviders(ref);
      SoundEffectsService.instance.coin();
      if (mounted) {
        Navigator.pop(context, true);
        CustomSnackBar.show(
          context,
          message: 'Transfer recorded successfully ✓',
        );
      }
      return;
    }

    // Account is optional — transaction can exist without a linked account

    final selectedMethod = _availablePaymentMethods
        .where((m) => m.id == _selectedPaymentMethodId)
        .firstOrNull;
    final isCreditCard = selectedMethod?.type == 'credit_card';
    String effectiveType;
    if (widget.existingTransaction != null &&
        (widget.existingTransaction!.type == 'credit_payment' ||
            widget.existingTransaction!.type == 'credit_card_payment' ||
            widget.existingTransaction!.type == 'transfer' ||
            widget.existingTransaction!.type == 'loan_repayment' ||
            widget.existingTransaction!.type == 'loan_disbursement' ||
            widget.existingTransaction!.type == 'loan_payment')) {
      effectiveType = widget.existingTransaction!.type;
    } else {
      effectiveType = (isCreditCard && _selectedType == 'expense')
          ? 'credit_card_purchase'
          : _selectedType;
    }

    final newTransaction = Transaction(
      id: widget.existingTransaction?.id,
      userId: widget.existingTransaction?.userId ?? 'offline_user',
      type: effectiveType,
      categoryId: _selectedCategoryId,
      accountId: _selectedPaymentMethodId,
      amount: amount,
      date: _selectedDate,
      notes: TextFormatter.normalizeName(_notesController.text),
      tags: widget.existingTransaction?.tags ?? const [],
      source: isCreditCard
          ? 'credit_card_purchase'
          : (widget.existingTransaction?.source ?? 'manual'),
      relatedEntityId: widget.existingTransaction?.relatedEntityId,
      location: widget.existingTransaction?.location,
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

    if (_selectedCategoryId != null &&
        _notesController.text.trim().isNotEmpty) {
      TrackedDatabaseTaskQueue.instance.runTracked(
        'add_expense_learn_merchant_rule',
        () => ref.read(learnMerchantRuleProvider)(
          text: _notesController.text,
          categoryId: _selectedCategoryId!,
          accountId: _selectedPaymentMethodId,
        ),
      );
      final cat = _availableCategories
          .where((c) => c.id == _selectedCategoryId)
          .firstOrNull;
      if (cat != null) {
        unawaited(
          SmartCategoryClassifier.instance.learn(
            rawText: _notesController.text,
            merchant: _notesController.text,
            category: cat.name,
          ),
        );
      }
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

    SoundEffectsService.instance.coin();
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
      final result = await GeminiService.instance.scanReceipt(
        File(picked.path),
      );
      if (mounted) Navigator.pop(context); // dismiss overlay

      if (result.containsKey('error')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result['error'] ?? 'Scan failed')),
          );
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
            const SnackBar(content: Text('Receipt scanned successfully')),
          );
        }
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // dismiss overlay on error
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Scan failed: $e')));
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: context.onSurfaceOverlay(
            lightOpacity: 0.09,
            darkOpacity: 0.16,
          ),
          width: 0.75,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 260 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.6;
          return Row(
            children: [
              _buildTypeOption(
                label: 'Spent',
                type: 'expense',
                color: modern_theme.AppTheme.semanticExpense,
                icon: Icons.arrow_upward_rounded,
                isDark: isDark,
                compact: compact,
              ),
              const SizedBox(width: 4),
              _buildTypeOption(
                label: 'Received',
                type: 'income',
                color: modern_theme.AppTheme.semanticIncome,
                icon: Icons.arrow_downward_rounded,
                isDark: isDark,
                compact: compact,
              ),
              const SizedBox(width: 4),
              _buildTypeOption(
                label: 'Moved',
                type: 'transfer',
                color: modern_theme.AppTheme.primaryBlue,
                icon: Icons.swap_horiz_rounded,
                isDark: isDark,
                compact: compact,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTypeOption({
    required String label,
    required String type,
    required Color color,
    required IconData icon,
    required bool isDark,
    required bool compact,
  }) {
    final isSelected = _selectedType == type;
    final semanticLabel = switch (type) {
      'expense' => 'Money spent',
      'income' => 'Money received',
      _ => 'Transfer money',
    };
    return Expanded(
      child: Semantics(
        button: true,
        selected: isSelected,
        label: semanticLabel,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedType = type;
              _selectedCategoryId = null;
            });
            _loadInitialData();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? color.withValues(alpha: isDark ? 0.30 : 0.20)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: isSelected
                    ? Border.all(
                        color: color.withValues(alpha: 0.6),
                        width: 1.0,
                      )
                    : null,
              ),
              alignment: Alignment.center,
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 14,
                          color: isSelected
                              ? color
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isSelected
                                ? color
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          icon,
                          size: 14,
                          color: isSelected
                              ? color
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: isSelected
                                  ? color
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMovementPresets(bool isDark) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _movementPresetChip(Icons.local_atm_rounded, 'ATM Withdrawal', () {
          final cash = _availablePaymentMethods
              .where(
                (m) =>
                    m.id == 'acc_cash_default' ||
                    m.name.toLowerCase().contains('cash'),
              )
              .firstOrNull;
          final bank = _availablePaymentMethods
              .where((m) => m.type == 'bank' && m.id != 'acc_cash_default')
              .firstOrNull;
          if (bank != null && cash != null) {
            setState(() {
              _selectedPaymentMethodId = bank.id;
              _destinationPaymentMethodId = cash.id;
              if (_notesController.text.isEmpty) {
                _notesController.text = 'ATM Cash Withdrawal';
              }
            });
          }
        }, isDark),
        _movementPresetChip(Icons.credit_card_rounded, 'Card Bill', () {
          final card = _availablePaymentMethods
              .where((m) => m.type == 'credit_card')
              .firstOrNull;
          final bank = _availablePaymentMethods
              .where((m) => m.type == 'bank' && m.id != 'acc_cash_default')
              .firstOrNull;
          if (bank != null && card != null) {
            setState(() {
              _selectedPaymentMethodId = bank.id;
              _destinationPaymentMethodId = card.id;
              if (_notesController.text.isEmpty) {
                _notesController.text = 'Credit Card Bill Payment';
              }
            });
          }
        }, isDark),
        _movementPresetChip(Icons.account_balance_rounded, 'Bank Transfer', () {
          final banks = _availablePaymentMethods
              .where((m) => m.type == 'bank' && m.id != 'acc_cash_default')
              .toList();
          if (banks.length >= 2) {
            setState(() {
              _selectedPaymentMethodId = banks[0].id;
              _destinationPaymentMethodId = banks[1].id;
              if (_notesController.text.isEmpty) {
                _notesController.text = 'Inter-Bank Transfer';
              }
            });
          }
        }, isDark),
        _movementPresetChip(Icons.payments_rounded, 'Cash Deposit', () {
          final cash = _availablePaymentMethods
              .where(
                (m) =>
                    m.id == 'acc_cash_default' ||
                    m.name.toLowerCase().contains('cash'),
              )
              .firstOrNull;
          final bank = _availablePaymentMethods
              .where((m) => m.type == 'bank' && m.id != 'acc_cash_default')
              .firstOrNull;
          if (bank != null && cash != null) {
            setState(() {
              _selectedPaymentMethodId = cash.id;
              _destinationPaymentMethodId = bank.id;
              if (_notesController.text.isEmpty) {
                _notesController.text = 'Cash Deposit to Bank';
              }
            });
          }
        }, isDark),
      ],
    );
  }

  Widget _movementPresetChip(
    IconData icon,
    String label,
    VoidCallback onTap,
    bool isDark,
  ) {
    return Semantics(
      button: true,
      label: 'Preset $label',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: context.onSurfaceOverlay(
                  lightOpacity: 0.063,
                  darkOpacity: 0.094,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: context.onSurfaceOverlay(
                    lightOpacity: 0.09,
                    darkOpacity: 0.16,
                  ),
                  width: 0.75,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransferSection(bool isDark, Color headerColor) {
    final fromMethod = _availablePaymentMethods
        .where((m) => m.id == _selectedPaymentMethodId)
        .firstOrNull;
    final toMethod = _availablePaymentMethods
        .where((m) => m.id == _destinationPaymentMethodId)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Quick Movement Presets',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 8),
        _buildMovementPresets(isDark),
        const SizedBox(height: 16),

        // Visual Route Diagram Banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: modern_theme.AppTheme.primaryBlue.withValues(
              alpha: isDark ? 0.12 : 0.08,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: modern_theme.AppTheme.primaryBlue.withValues(
                alpha: isDark ? 0.28 : 0.20,
              ),
              width: 0.75,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Theme.of(context).colorScheme.surfaceContainerHigh
                            : context.surfaceColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        fromMethod?.name ?? 'Select Source',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: modern_theme.AppTheme.primaryBlue,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Theme.of(context).colorScheme.surfaceContainerHigh
                            : context.surfaceColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        toMethod?.name ?? 'Select Destination',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '0 Net Worth Impact • Internal Funds Movement',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),
        Text(
          'From Account (Paying)',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        AppPaymentMethodPicker(
          availableMethods: _availablePaymentMethods
              .where((m) => m.type != 'credit_card')
              .toList(),
          selectedMethodId: _selectedPaymentMethodId,
          activeColor: headerColor,
          onMethodSelected: (id) =>
              setState(() => _selectedPaymentMethodId = id),
        ),

        const SizedBox(height: 16),
        Text(
          'To Account / Instrument (Receiving)',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        AppPaymentMethodPicker(
          availableMethods: _availablePaymentMethods,
          selectedMethodId: _destinationPaymentMethodId,
          activeColor: headerColor,
          onMethodSelected: (id) =>
              setState(() => _destinationPaymentMethodId = id),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerColor = _isSpecialNonCategorizedType
        ? modern_theme.AppTheme.primaryBlue
        : (_selectedType == 'expense'
              ? modern_theme.AppTheme.semanticExpense
              : modern_theme.AppTheme.semanticIncome);

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: _appBarTitle,
        actions: [
          if (widget.existingTransaction == null)
            IconButton(
              icon: Icon(
                Icons.document_scanner_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              tooltip: 'Scan Receipt',
              onPressed: _scanReceipt,
            ),
          if (widget.existingTransaction != null)
            IconButton(
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: modern_theme.AppTheme.semanticExpense,
                size: 20,
              ),
              tooltip: 'Delete Transaction',
              onPressed: _deleteTransaction,
            ),
        ],
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppFormErrorSummary(
                errors: _formErrors,
                onDismiss: () => setState(() => _formErrors = []),
              ),
              // ── Section 1: Type & Amount Card ────────────
              SpendXGlassSurface(
                level: SpendXGlassLevel.elevated,
                borderRadius: BorderRadius.circular(AppRadius.l),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_isSpecialNonCategorizedType) ...[
                      _buildTypeToggle(),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      'Amount',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    AppAmountField(
                      controller: _amountController,
                      focusNode: _amountFocusNode,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _notesFocusNode.requestFocus(),
                      amountColor: headerColor,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter an amount';
                        }
                        final amount = double.tryParse(value.trim());
                        if (amount == null || !amount.isFinite || amount <= 0) {
                          return 'Enter an amount greater than zero';
                        }
                        return null;
                      },
                    ),
                    if (_recentAmounts.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _recentAmounts.map((amount) {
                          final formattedAmount = '${settings.currencySymbol}${_formatQuickAmount(amount)}';
                          return Semantics(
                            button: true,
                            label: 'Quick amount $formattedAmount',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _applyQuickAmount(amount),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.surface
                                          .withValues(alpha: isDark ? 0.12 : 0.25),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: context.onSurfaceOverlay(
                                          lightOpacity: 0.09,
                                          darkOpacity: 0.16,
                                        ),
                                        width: 0.75,
                                      ),
                                    ),
                                    child: Text(
                                      formattedAmount,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Section 2: Category & Payment Source ────
              SpendXGlassSurface(
                level: SpendXGlassLevel.base,
                borderRadius: BorderRadius.circular(AppRadius.l),
                padding: const EdgeInsets.all(16),
                child: _selectedType == 'transfer'
                    ? _buildTransferSection(isDark, headerColor)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!_isSpecialNonCategorizedType) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Category',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                                ),
                                Semantics(
                                  button: true,
                                  label: 'Add new category',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
                                      final newCat =
                                          await showModalBottomSheet<Category>(
                                            context: context,
                                            isScrollControlled: true,
                                            backgroundColor: Colors.transparent,
                                            builder: (_) => AddCategorySheet(
                                              initialType: _selectedType,
                                            ),
                                          );
                                      if (newCat != null) {
                                        await _loadInitialData();
                                        setState(() {
                                          _selectedCategoryId = newCat.id;
                                          _didExplicitCategorySelection = true;
                                        });
                                      }
                                    },
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      child: Center(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 4,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.add_circle_outline_rounded,
                                                size: 16,
                                                color: modern_theme
                                                    .AppTheme
                                                    .primaryBlue,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                'Add New',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: modern_theme
                                                      .AppTheme
                                                      .primaryBlue,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            FormField<String>(
                              initialValue: _selectedCategoryId,
                              validator: (val) {
                                if (!_isSpecialNonCategorizedType &&
                                    _selectedType != 'transfer') {
                                  if (_selectedCategoryId == null ||
                                      _selectedCategoryId!.isEmpty) {
                                    return 'Please select a category';
                                  }
                                }
                                return null;
                              },
                              builder: (fieldState) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AppCategoryPicker(
                                      availableCategories: _availableCategories,
                                      selectedCategoryId: _selectedCategoryId,
                                      activeColor: headerColor,
                                      onCategorySelected: (id) {
                                        setState(() {
                                          _selectedCategoryId = id;
                                          _didExplicitCategorySelection = true;
                                        });
                                        fieldState.didChange(id);
                                      },
                                    ),
                                    if (fieldState.hasError)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 6,
                                          left: 4,
                                        ),
                                        child: Text(
                                          fieldState.errorText!,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 16),
                              height: 0.5,
                              color: context.borderColor,
                            ),
                          ],

                          Text(
                            _isSpecialNonCategorizedType
                                ? 'Paid From Account'
                                : 'Payment Source',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_availablePaymentMethods.isNotEmpty)
                            AppPaymentMethodPicker(
                              availableMethods: _availablePaymentMethods,
                              selectedMethodId: _selectedPaymentMethodId,
                              activeColor: headerColor,
                              onMethodSelected: (id) {
                                setState(() {
                                  _selectedPaymentMethodId = id;
                                });
                              },
                            )
                          else
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: context.onSurfaceOverlay(
                                  lightOpacity: 0.2,
                                  darkOpacity: 0.078,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'No accounts found.',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  SpendXGlassButton(
                                    variant: SpendXGlassButtonVariant.tonal,
                                    onPressed: () async {
                                      final result = await Navigator.push(
                                        context,
                                        AppPageRoute(
                                          builder: (_) =>
                                              const AddBankAccountScreen(),
                                        ),
                                      );
                                      if (result == true) {
                                        await _loadInitialData();
                                      }
                                    },
                                    child: const Text('Add Account'),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),

              const SizedBox(height: 16),

              // ── Section 3: Date & Notes ───────────────────
              SpendXGlassSurface(
                level: SpendXGlassLevel.base,
                borderRadius: BorderRadius.circular(AppRadius.l),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Transaction Date',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    AppDateSelector(
                      selectedDate: _selectedDate,
                      onDateSelected: (date) =>
                          setState(() => _selectedDate = date),
                    ),
                    const SizedBox(height: 16),
                    shared.AppTextField(
                      controller: _notesController,
                      focusNode: _notesFocusNode,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _notesFocusNode.unfocus(),
                      label: _selectedType == 'transfer'
                          ? 'Transfer Note'
                          : 'Merchant / Payee Notes',
                      prefix: Icon(
                        _selectedType == 'transfer'
                            ? Icons.swap_horiz_rounded
                            : Icons.notes_rounded,
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return _selectedType == 'transfer'
                              ? 'Please enter a transfer note'
                              : 'Please enter a description or payee';
                        }
                        if (val.trim().length > 500) {
                          return 'Note must be 500 characters or less';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              SpendXPlayfulButton(
                variant: _selectedType == 'income'
                    ? PlayfulButtonVariant.income
                    : (_selectedType == 'transfer'
                        ? PlayfulButtonVariant.primary
                        : PlayfulButtonVariant.expense),
                height: 50,
                onPressed: _saveTransaction,
                child: Text(
                  widget.existingTransaction != null
                      ? 'Update Activity'
                      : (_selectedType == 'transfer'
                            ? 'Move Funds'
                            : 'Save Activity'),
                ),
              ),
            ],
          ),
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
