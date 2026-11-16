import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../models/category.dart';
import '../models/credit_transaction.dart';
import '../models/lending.dart';
import '../data/repositories/lending_repo.dart';
import '../utils/app_format.dart';
import '../widgets/spendx_app_bar.dart';
import '../widgets/custom_dialog.dart';
import '../widgets/custom_snackbar.dart';
import 'expense/add_expense_screen.dart';
import 'bank/account_list_screen.dart' show resolveAccountDisplayName;
import '../domain/credit/credit_card_service.dart';
import '../utils/text_formatter.dart';
import '../data/providers.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/glass/spendx_scaffold.dart';
import '../shared/widgets/glass/spendx_glass_surface.dart';
import '../shared/widgets/glass/spendx_glass_button.dart';
import '../shared/widgets/glass/spendx_glass_sheet.dart';
import '../theme/app_theme.dart';
import '../features/transactions/providers/transaction_providers.dart' show deleteTransactionProvider;

class UnifiedTransactionDetailScreen extends ConsumerStatefulWidget {
  final Transaction transaction;
  final Category? category;

  const UnifiedTransactionDetailScreen({
    super.key,
    required this.transaction,
    this.category,
  });

  @override
  ConsumerState<UnifiedTransactionDetailScreen> createState() =>
      _UnifiedTransactionDetailScreenState();
}

class _UnifiedTransactionDetailScreenState
    extends ConsumerState<UnifiedTransactionDetailScreen> {
  late Transaction _tx;
  Category? _cat;
  bool _isLoading = false;
  CreditTransaction? _creditTxn;
  final _creditService = CreditCardService();
  final _lendingRepo = LendingRepo();
  Lending? _matchingOpenLoan;
  bool _dismissedLoanPrompt = false;

  @override
  void initState() {
    super.initState();
    _tx = widget.transaction;
    _cat = widget.category;
    _loadCreditDetails();
    _checkLendingMatch();
  }

  Future<void> _checkLendingMatch() async {
    try {
      final openLoans = await _lendingRepo.getAll(settledFilter: false);
      if (openLoans.isEmpty) return;

      final note = _tx.notes.toLowerCase();
      for (final loan in openLoans) {
        final pName = loan.personName.trim().toLowerCase();
        if (pName.isNotEmpty && (note.contains(pName) || pName.split(' ').any((part) => part.length >= 3 && note.contains(part)))) {
          if (mounted) {
            setState(() {
              _matchingOpenLoan = loan;
            });
          }
          break;
        }
      }
    } catch (_) {}
  }

  String _extractPeerName(String text) {
    var clean = text
        .replaceAll(RegExp(r'^(?:paid to|sent to|transfer to|to|from|received from)\s+', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+(?:via\s+upi|on\s+upi|upi|ref|ref\s*no|rrn|vpa).*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'@[a-zA-Z0-9.-]+'), '')
        .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
        .replaceAll(RegExp(r'[0-9]{4,}'), '')
        .trim();
    if (clean.length > 25) clean = clean.substring(0, 25).trim();
    return clean.isNotEmpty ? TextFormatter.toSmartTitleCase(clean) : 'Contact';
  }

  bool _hasLoanKeywords(String text) {
    return RegExp(
      r'\b(?:loan|udhar|udhaari|borrow|borrowed|debt|repay|repayment|return|lent|lending)\b',
      caseSensitive: false,
    ).hasMatch(text);
  }

  Future<void> _markLoanSettled() async {
    if (_matchingOpenLoan == null) return;
    final loan = _matchingOpenLoan!;
    final newPaid = loan.paidAmount + _tx.amount.abs();
    final isFullySettled = newPaid >= loan.originalAmount;
    final updated = loan.copyWith(
      paidAmount: newPaid,
      isSettled: isFullySettled,
      updatedAt: DateTime.now(),
    );
    await _lendingRepo.update(updated);
    if (mounted) {
      setState(() => _matchingOpenLoan = null);
      CustomSnackBar.show(
        context,
        message: isFullySettled
            ? 'Loan with ${loan.personName} marked as fully repaid! ✓'
            : 'Recorded repayment of ${AppFormat.currency(_tx.amount.abs())} from ${loan.personName} ✓',
      );
    }
  }

  Future<void> _createLendingRecord(String type, String defaultPersonName) async {
    final nameCtrl = TextEditingController(text: defaultPersonName);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final verb = type == 'lent' ? 'Lent to' : 'Borrowed from';

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SpendXGlassSheet(
        title: '$verb Contact',
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            left: 16,
            right: 16,
            top: 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Amount: ${AppFormat.currency(_tx.amount.abs())}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Person Name',
                  hintText: 'Enter contact name',
                  filled: true,
                  fillColor: isDark ? const Color(0x1AFFFFFF) : const Color(0x0A000000),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 18),
              SpendXGlassButton(
                variant: SpendXGlassButtonVariant.primary,
                onPressed: () {
                  if (nameCtrl.text.trim().isNotEmpty) {
                    Navigator.pop(ctx, true);
                  }
                },
                child: Text('Track as $verb ${nameCtrl.text.trim()}'),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true && nameCtrl.text.trim().isNotEmpty) {
      final person = nameCtrl.text.trim();
      final newLending = Lending(
        personName: person,
        type: type,
        originalAmount: _tx.amount.abs(),
        paidAmount: 0.0,
        date: _tx.date,
        notes: _tx.notes.isNotEmpty ? _tx.notes : '$verb $person',
      );
      await _lendingRepo.insert(newLending);

      final updatedTx = _tx.copyWith(
        notes: _tx.notes.isNotEmpty ? '${_tx.notes} ($verb $person)' : '$verb $person',
      );
      await ref.read(transactionsProvider.notifier).replace(updatedTx);
      if (mounted) {
        setState(() {
          _tx = updatedTx;
        });
        CustomSnackBar.show(
          context,
          message: 'Saved under Lending & Borrowing with $person ✓',
        );
      }
    }
  }

  Future<void> _loadCreditDetails() async {
    final isCardTxn = _tx.type == 'credit_card_purchase' ||
        _tx.source == 'credit_card_purchase' ||
        _tx.source == 'credit_purchase';
    if (isCardTxn) {
      final targetId = _tx.relatedEntityId ?? _tx.id;
      final ctx = await ref.read(
        creditTransactionByIdProvider(targetId).future,
      );
      if (mounted) setState(() => _creditTxn = ctx);
    }
  }

  Future<void> _deleteTransaction() async {
    final confirm = await CustomDialog.show(
      context,
      type: DialogType.warning,
      title: 'Delete Transaction?',
      message: 'This will permanently remove this record from your ledger.',
      primaryButtonText: 'Delete',
      secondaryButtonText: 'Cancel',
    );

    if (confirm == true) {
      if (!mounted) return;
      setState(() => _isLoading = true);
      try {
        await ref.read(deleteTransactionProvider)(_tx.id);
      } catch (e) {
        debugPrint('[UnifiedTransactionDetailScreen] Delete error: $e');
      }
      if (mounted) {
        Navigator.pop(context, true);
        CustomSnackBar.show(context, message: 'Transaction deleted');
      }
    }
  }

  Future<void> _editTransaction() async {
    final result = await Navigator.push(
      context,
      AppPageRoute(
        builder: (_) =>
            AddExpenseScreen(initialType: _tx.type, existingTransaction: _tx),
      ),
    );

    if (result == true && mounted) {
      Navigator.pop(context, true);
    }
  }

  void _showEMIConversionSheet() {
    if (_creditTxn == null) return;

    int selectedTenure = 6;
    double interestRate = 12.0;
    double processingFee = 199.0;
    bool includeGst = true;
    bool useDefault = true;

    SpendXGlassSheet.show(
      context: context,
      title: 'EMI Configuration',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          final effectiveFee = includeGst
              ? processingFee * 1.18
              : processingFee;
          final totalInterest =
              (_tx.amount * (interestRate / 100) * (selectedTenure / 12));
          final monthlyEmi = (_tx.amount + totalInterest) / selectedTenure;

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Converting ${AppFormat.currency(_tx.amount)}',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 16),

              Row(
                children: [
                  Text(
                    'Use Defaults',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                    ),
                  ),
                  const Spacer(),
                  Switch.adaptive(
                    value: useDefault,
                    onChanged: (v) => setDs(() => useDefault = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Text(
                'Tenure (Months)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                ),
              ),
              const SizedBox(height: 6),
              SpendXGlassSurface(
                borderRadius: BorderRadius.circular(AppRadius.m),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: selectedTenure,
                    isExpanded: true,
                    dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
                    items: [3, 6, 9, 12, 18, 24, 36]
                        .map(
                          (t) => DropdownMenuItem(
                            value: t,
                            child: Text(
                              '$t Months',
                              style: TextStyle(
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setDs(() => selectedTenure = v!),
                  ),
                ),
              ),

              if (!useDefault) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Interest (% p.a.)',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: '12.0',
                              filled: true,
                              fillColor: isDark ? const Color(0x1AFFFFFF) : const Color(0x66FFFFFF),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onChanged: (v) => setDs(
                              () => interestRate = double.tryParse(v) ?? 0.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Fee (\u20b9)',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: '199',
                              filled: true,
                              fillColor: isDark ? const Color(0x1AFFFFFF) : const Color(0x66FFFFFF),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onChanged: (v) => setDs(
                              () => processingFee = double.tryParse(v) ?? 0.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'Apply 18% GST on Fee',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                      ),
                    ),
                    const Spacer(),
                    Checkbox(
                      value: includeGst,
                      onChanged: (v) => setDs(() => includeGst = v!),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 16),
              SpendXGlassSurface(
                level: SpendXGlassLevel.elevated,
                borderRadius: BorderRadius.circular(AppRadius.m),
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Monthly EMI',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          AppFormat.currency(monthlyEmi),
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            letterSpacing: -0.4,
                            color: AppTheme.primaryBlue,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'Total Interest',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          AppFormat.currency(totalInterest),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Processing Fee: ${AppFormat.currency(effectiveFee)} (One-time)',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                ),
              ),
              const SizedBox(height: 20),
              SpendXGlassButton(
                variant: SpendXGlassButtonVariant.primary,
                onPressed: () async {
                  Navigator.pop(ctx);
                  setState(() => _isLoading = true);
                  await _creditService.convertPurchaseToEMI(
                    purchase: _creditTxn!,
                    tenureMonths: selectedTenure,
                    interestRate: interestRate,
                    processingFee: effectiveFee,
                  );
                  if (mounted) {
                    Navigator.pop(context, true);
                    CustomSnackBar.show(
                      context,
                      message: 'Converted to EMI successfully',
                    );
                  }
                },
                child: const Text('Confirm Conversion'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isIncome = _tx.type == 'income';
    final isCcPayment = _tx.type == 'credit_payment' || _tx.source == 'credit_card_payment';
    final isTransfer = _tx.isTransferType || isCcPayment;

    final Color amountColor;
    final String sign;
    final IconData heroIcon;

    if (isCcPayment) {
      amountColor = AppTheme.primaryBlue;
      sign = '→';
      heroIcon = Icons.credit_card_rounded;
    } else if (isTransfer) {
      amountColor = AppTheme.primaryBlue;
      sign = '→';
      heroIcon = Icons.swap_horiz_rounded;
    } else if (isIncome) {
      amountColor = AppTheme.semanticIncome;
      sign = '+';
      heroIcon = Icons.arrow_downward_rounded;
    } else {
      amountColor = AppTheme.semanticExpense;
      sign = '-';
      heroIcon = Icons.arrow_upward_rounded;
    }

    final accounts = ref.watch(accountsProvider).valueOrNull ?? [];
    final cards = ref.watch(cardsProvider).valueOrNull ?? [];
    final accountMap = {
      for (final a in accounts) a.id: resolveAccountDisplayName(a.name),
      for (final c in cards) c.id: resolveAccountDisplayName(c.name.isNotEmpty ? c.name : '${c.bank} Card'),
    };
    final fromName = accountMap[_tx.accountId] ?? (_tx.accountId != null ? 'Account' : null);
    final toName = accountMap[_tx.relatedEntityId] ?? (_tx.relatedEntityId != null ? 'Card / Account' : null);

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: 'Transaction Details',
        actions: [
          IconButton(
            icon: Icon(
              Icons.edit_outlined,
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
            onPressed: _editTransaction,
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: AppTheme.semanticExpense,
            ),
            onPressed: _deleteTransaction,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Hero Amount Card ──────────────────────────
                  SpendXGlassSurface(
                    level: SpendXGlassLevel.elevated,
                    borderRadius: BorderRadius.circular(AppRadius.l),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: amountColor.withValues(alpha: isDark ? 0.18 : 0.12),
                            border: Border.all(
                              color: amountColor.withValues(alpha: isDark ? 0.40 : 0.25),
                              width: 0.75,
                            ),
                          ),
                          child: Icon(
                            heroIcon,
                            color: amountColor,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '$sign ${AppFormat.currency(_tx.amount.abs())}',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            letterSpacing: -0.8,
                            color: amountColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0x1AFFFFFF) : const Color(0x33000000),
                            borderRadius: BorderRadius.circular(AppRadius.full),
                          ),
                          child: Text(
                            isCcPayment
                                ? 'Credit Card Payment'
                                : (isTransfer ? 'Transfer' : (_cat?.name ?? 'Uncategorized')),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Grouped Detail Surface ────────────────────
                  SpendXGlassSurface(
                    level: SpendXGlassLevel.base,
                    borderRadius: BorderRadius.circular(AppRadius.l),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _buildDetailItem(
                          icon: Icons.calendar_today_rounded,
                          label: 'Date',
                          value: DateFormat('EEEE, MMM dd, yyyy').format(_tx.date),
                          isDark: isDark,
                        ),
                        _buildDivider(isDark),
                        _buildDetailItem(
                          icon: Icons.access_time_rounded,
                          label: 'Time',
                          value: DateFormat('hh:mm a').format(_tx.date),
                          isDark: isDark,
                        ),
                        if (isTransfer && (fromName != null || toName != null)) ...[
                          _buildDivider(isDark),
                          _buildDetailItem(
                            icon: Icons.swap_horiz_rounded,
                            label: 'Flow',
                            value: '${fromName ?? "Default"} → ${toName ?? "Destination"}',
                            isDark: isDark,
                          ),
                        ] else if (fromName != null) ...[
                          _buildDivider(isDark),
                          _buildDetailItem(
                            icon: Icons.account_balance_rounded,
                            label: 'Account',
                            value: fromName,
                            isDark: isDark,
                          ),
                        ],
                        if (!isTransfer) ...[
                          _buildDivider(isDark),
                          _buildDetailItem(
                            icon: Icons.category_rounded,
                            label: 'Category',
                            value: _cat?.name ?? 'None',
                            isDark: isDark,
                          ),
                        ],
                        if (_tx.externalRef != null && _tx.externalRef!.isNotEmpty) ...[
                          _buildDivider(isDark),
                          _buildDetailItem(
                            icon: Icons.tag_rounded,
                            label: 'Reference / ID',
                            value: _tx.externalRef!,
                            isDark: isDark,
                          ),
                        ],
                        _buildDivider(isDark),
                        _buildDetailItem(
                          icon: Icons.notes_rounded,
                          label: 'Notes',
                          value: _tx.notes.isEmpty ? 'No notes added' : _tx.notes,
                          isDark: isDark,
                        ),
                        _buildDivider(isDark),
                        _buildDetailItem(
                          icon: Icons.source_rounded,
                          label: 'Source',
                          value: TextFormatter.toSmartTitleCase(_tx.source),
                          isDark: isDark,
                        ),
                      ],
                    ),
                  ),

                  if (_tx.source == 'credit_purchase' &&
                      _creditTxn != null &&
                      _creditTxn!.status == 'active') ...[
                    const SizedBox(height: 16),
                    SpendXGlassSurface(
                      level: SpendXGlassLevel.base,
                      borderRadius: BorderRadius.circular(AppRadius.m),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Credit Options',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                          const SizedBox(height: 10),
                          SpendXGlassButton(
                            variant: SpendXGlassButtonVariant.tonal,
                            onPressed: _showEMIConversionSheet,
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.repeat_rounded, size: 18),
                                SizedBox(width: 8),
                                Text('Convert to EMI'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (_creditTxn != null &&
                      _creditTxn!.status == 'converted') ...[
                    const SizedBox(height: 16),
                    SpendXGlassSurface(
                      level: SpendXGlassLevel.base,
                      borderRadius: BorderRadius.circular(AppRadius.m),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_rounded,
                            color: AppTheme.semanticIncome,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Converted to EMI',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (_matchingOpenLoan != null && isIncome) ...[
                    _buildSettlementBanner(context, isDark),
                  ],

                  if (!_tx.isTransferType &&
                      _creditTxn == null &&
                      _tx.source != 'credit_purchase' &&
                      _tx.source != 'credit_card_payment') ...[
                    const SizedBox(height: 16),
                    _buildPeerLendingSection(context, isDark),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildSettlementBanner(BuildContext context, bool isDark) {
    final loan = _matchingOpenLoan!;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0x1F10B981) : const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(AppRadius.l),
        border: Border.all(
          color: isDark ? const Color(0x4034D399) : const Color(0xFFA7F3D0),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark ? const Color(0x3010B981) : const Color(0xFFD1FAE5),
                ),
                child: const Icon(
                  Icons.handshake_rounded,
                  size: 18,
                  color: Color(0xFF059669),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Matching Loan from ${loan.personName}',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: isDark ? const Color(0xFFA7F3D0) : const Color(0xFF065F46),
                      ),
                    ),
                    Text(
                      'Outstanding loan: ${AppFormat.currency(loan.remainingAmount)} remaining',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SpendXGlassButton(
                  variant: SpendXGlassButtonVariant.tonal,
                  onPressed: _markLoanSettled,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_outline_rounded, size: 16),
                      SizedBox(width: 6),
                      Text('Mark Loan Repaid', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _matchingOpenLoan = null),
                child: Text(
                  'Dismiss',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPeerLendingSection(BuildContext context, bool isDark) {
    final peerName = _extractPeerName(_tx.notes);
    final hasKeywords = _hasLoanKeywords(_tx.notes);

    return SpendXGlassSurface(
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(AppRadius.m),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.handshake_outlined,
                size: 16,
                color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
              ),
              const SizedBox(width: 8),
              Text(
                'Lending & Borrowing',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                ),
              ),
            ],
          ),
          if (hasKeywords && !_dismissedLoanPrompt) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0x1F6366F1) : const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Payment note mentions a loan keyword. Track under Friends & Family?',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isDark ? const Color(0xFFE0E7FF) : const Color(0xFF3730A3),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => _dismissedLoanPrompt = true),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF6366F1),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SpendXGlassButton(
                  variant: SpendXGlassButtonVariant.tonal,
                  onPressed: () => _createLendingRecord('lent', peerName),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.arrow_upward_rounded, size: 14, color: Color(0xFFE11D48)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '🤝 Lent to $peerName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SpendXGlassButton(
                  variant: SpendXGlassButtonVariant.tonal,
                  onPressed: () => _createLendingRecord('borrowed', peerName),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.arrow_downward_rounded, size: 14, color: Color(0xFF16A34A)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '🤝 Borrowed from $peerName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDivider(bool isDark) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      height: 0.5,
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06),
    );
  }

  Widget _buildDetailItem({
    required IconData icon,
    required String label,
    required String value,
    required bool isDark,
  }) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isDark ? const Color(0x1AFFFFFF) : const Color(0x33000000),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 18,
            color: AppTheme.primaryBlue,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
