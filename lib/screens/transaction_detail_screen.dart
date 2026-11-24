import 'dart:convert';
import 'package:flutter/material.dart';
import '../shared/widgets/loading_state_widget.dart';
import 'package:flutter/services.dart';
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
import '../shared/widgets/glass/spendx_transaction_tile.dart'
    show cleanTransactionDisplayTitle;
import '../theme/app_theme.dart';
import '../features/transactions/providers/transaction_providers.dart'
    show deleteTransactionProvider;

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
        if (pName.isNotEmpty &&
            (note.contains(pName) ||
                pName
                    .split(' ')
                    .any((part) => part.length >= 3 && note.contains(part)))) {
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
    if (text.isEmpty) return 'Contact';
    final cleaned = cleanTransactionDisplayTitle(
      text,
      categoryName: _cat?.name,
      isCcPayment:
          _tx.type == 'credit_payment' || _tx.source == 'credit_card_payment',
      isTransfer: _tx.type == 'transfer' || _tx.source == 'transfer',
    );
    if (cleaned.isNotEmpty &&
        !cleaned.startsWith('{') &&
        !cleaned.contains('debited for')) {
      return cleaned;
    }
    var clean = text
        .replaceAll(
          RegExp(r'^[{\["\s]*(?:body["\s:]+)?', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'["}\]]+$'), '')
        .replaceAll(
          RegExp(
            r'^(?:paid to|sent to|transfer to|to|from|received from)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'\s+(?:via\s+upi|on\s+upi|upi|ref|ref\s*no|rrn|vpa).*$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'@[a-zA-Z0-9.-]+'), '')
        .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
        .replaceAll(RegExp(r'[0-9]{4,}'), '')
        .trim();
    if (clean.length > 25) clean = clean.substring(0, 25).trim();
    return clean.isNotEmpty ? TextFormatter.toSmartTitleCase(clean) : 'Contact';
  }

  String _formatNotesForDisplay(String rawNotes) {
    final trimmed = rawNotes.trim();
    if (trimmed.isEmpty) return 'No notes added';
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final m = decoded['merchant']?.toString().trim();
          final b = decoded['body']?.toString().trim();
          if (m != null && m.isNotEmpty) return m;
          if (b != null && b.isNotEmpty) return cleanTransactionDisplayTitle(b);
        }
      } catch (_) {}
      return 'No notes added';
    }
    return cleanTransactionDisplayTitle(trimmed);
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

  Future<void> _createLendingRecord(
    String type,
    String defaultPersonName,
  ) async {
    final nameCtrl = TextEditingController(text: defaultPersonName);
    final verb = type == 'lent' ? 'Lent to' : 'Borrowed from';

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SpendXGlassSheet(
        title: '$verb Contact',
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
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
                  color: context.textPrimary,
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
                  fillColor: context.onSurfaceOverlay(
                    lightOpacity: 0.04,
                    darkOpacity: 0.10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
        notes: _tx.notes.isNotEmpty
            ? '${_tx.notes} ($verb $person)'
            : '$verb $person',
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
    final isCardTxn =
        _tx.type == 'credit_card_purchase' ||
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
                style: TextStyle(fontSize: 13, color: context.textSecondary),
              ),
              const SizedBox(height: 16),

              Row(
                children: [
                  Text(
                    'Use Defaults',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
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
                  color: context.textMuted,
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
                    dropdownColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHigh,
                    items: [3, 6, 9, 12, 18, 24, 36]
                        .map(
                          (t) => DropdownMenuItem(
                            value: t,
                            child: Text(
                              '$t Months',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
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
                              color: context.textMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: '12.0',
                              filled: true,
                              fillColor: Theme.of(context).colorScheme.surface
                                  .withValues(alpha: isDark ? 0.10 : 0.40),
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
                              color: context.textMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: '199',
                              filled: true,
                              fillColor: Theme.of(context).colorScheme.surface
                                  .withValues(alpha: isDark ? 0.10 : 0.40),
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
                        color: context.textPrimary,
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
                            color: context.textSecondary,
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
                            color: context.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          AppFormat.currency(totalInterest),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: context.textPrimary,
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
                style: TextStyle(fontSize: 11, color: context.textMuted),
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
    final isCcPayment =
        _tx.type == 'credit_payment' || _tx.source == 'credit_card_payment';
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
      for (final c in cards)
        c.id: resolveAccountDisplayName(
          c.name.isNotEmpty ? c.name : '${c.bank} Card',
        ),
    };
    final fromName =
        accountMap[_tx.accountId] ?? (_tx.accountId != null ? 'Account' : null);
    final toName =
        accountMap[_tx.relatedEntityId] ??
        (_tx.relatedEntityId != null ? 'Card / Account' : null);

    // Route determination
    final String sourceLabel;
    final String sourceName;
    final IconData sourceIcon;
    final String destLabel;
    final String destName;
    final IconData destIcon;
    final Color destColor;

    if (isCcPayment) {
      sourceLabel = 'Paying Account';
      sourceName = fromName ?? 'Bank Account';
      sourceIcon = Icons.account_balance_rounded;
      destLabel = 'Credit Card';
      destName = toName ?? 'Card Liability';
      destIcon = Icons.credit_card_rounded;
      destColor = AppTheme.primaryBlue;
    } else if (isTransfer) {
      sourceLabel = 'Source';
      sourceName = fromName ?? 'Bank Account';
      sourceIcon = Icons.account_balance_rounded;
      destLabel = 'Destination';
      destName = toName ?? 'Account';
      destIcon = Icons.account_balance_wallet_rounded;
      destColor = AppTheme.primaryBlue;
    } else if (isIncome) {
      sourceLabel = 'Received From';
      sourceName = _tx.notes.isNotEmpty
          ? _extractPeerName(_tx.notes)
          : 'Income Source';
      sourceIcon = Icons.arrow_downward_rounded;
      destLabel = 'Credited Into';
      destName = fromName ?? 'Primary Account';
      destIcon = Icons.account_balance_rounded;
      destColor = AppTheme.semanticIncome;
    } else {
      sourceLabel = 'Paid Via';
      sourceName = fromName ?? 'Account / Card';
      sourceIcon = _tx.source.contains('credit')
          ? Icons.credit_card_rounded
          : Icons.account_balance_rounded;
      destLabel = 'Merchant / Payee';
      destName = _tx.notes.isNotEmpty
          ? _extractPeerName(_tx.notes)
          : (_cat?.name ?? 'Merchant');
      destIcon = Icons.storefront_rounded;
      destColor = AppTheme.semanticExpense;
    }

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: 'Transaction Details',
        actions: [
          IconButton(
            icon: Icon(Icons.edit_outlined, color: context.textPrimary),
            tooltip: 'Edit',
            onPressed: _editTransaction,
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: AppTheme.semanticExpense,
            ),
            tooltip: 'Delete',
            onPressed: _deleteTransaction,
          ),
        ],
      ),
      body: _isLoading
          ? const LoadingStateWidget(message: 'Loading transaction…')
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 1. Hero Amount Card (Full Width) ────────────
                  SpendXGlassSurface(
                    width: double.infinity,
                    level: SpendXGlassLevel.elevated,
                    borderRadius: BorderRadius.circular(AppRadius.l),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 24,
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: amountColor.withValues(
                              alpha: isDark ? 0.18 : 0.12,
                            ),
                            border: Border.all(
                              color: amountColor.withValues(
                                alpha: isDark ? 0.40 : 0.25,
                              ),
                              width: 0.75,
                            ),
                          ),
                          child: Icon(heroIcon, color: amountColor, size: 28),
                        ),
                        const SizedBox(height: 12),
                        () {
                          final forex = AppFormat.extractForexDetails(
                            _tx.notes,
                            _tx.rawPayload,
                          );
                          final amtStr = forex != null
                              ? '$sign ${forex.formattedForeignAmount}'
                              : '$sign ${AppFormat.currency(_tx.amount.abs())}';
                          return Column(
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  amtStr,
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                    letterSpacing: -0.8,
                                    color: amountColor,
                                  ),
                                ),
                              ),
                              if (forex != null) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: isDark ? 0.20 : 0.12),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Theme.of(context).colorScheme.primary
                                          .withValues(alpha: isDark ? 0.35 : 0.25),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    '≈ ${AppFormat.currency(forex.estimatedInr)} • (${forex.rateDisplay})',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          );
                        }(),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: context.onSurfaceOverlay(
                              lightOpacity: 0.20,
                              darkOpacity: 0.10,
                            ),
                            borderRadius: BorderRadius.circular(AppRadius.full),
                            border: Border.all(
                              color: context.onSurfaceOverlay(
                                lightOpacity: 0.09,
                                darkOpacity: 0.16,
                              ),
                              width: 0.75,
                            ),
                          ),
                          child: Text(
                            isCcPayment
                                ? 'Credit Card Payment'
                                : (isTransfer
                                      ? 'Transfer'
                                      : (_cat?.name ?? 'Uncategorized')),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: context.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Net Worth Impact Badge
                        _buildImpactBadge(
                          isDark,
                          isIncome,
                          isTransfer,
                          isCcPayment,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  () {
                    final forexDetails = AppFormat.extractForexDetails(
                      _tx.notes,
                      _tx.rawPayload,
                    );
                    return Column(
                      children: [
                        // ── 2. Visual Transaction Route Diagram ──────────
                        SpendXGlassSurface(
                          width: double.infinity,
                          level: SpendXGlassLevel.base,
                          borderRadius: BorderRadius.circular(AppRadius.l),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.alt_route_rounded,
                                    size: 15,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isCcPayment
                                        ? 'BILL SETTLEMENT ROUTE'
                                        : (isTransfer
                                              ? 'INTERNAL MOVEMENT ROUTE'
                                              : 'FUNDS FLOW ROUTE'),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.6,
                                      color: context.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  // Source Box
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: context.onSurfaceOverlay(
                                          lightOpacity: 0.04,
                                          darkOpacity: 0.09,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: context.onSurfaceOverlay(
                                            lightOpacity: 0.08,
                                            darkOpacity: 0.14,
                                          ),
                                          width: 0.75,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Icon(
                                            sourceIcon,
                                            size: 20,
                                            color: AppTheme.primaryBlue,
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            sourceLabel,
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: context.textMuted,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            sourceName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: context.textPrimary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  // Direction Arrow & Flow Badge
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Column(
                                      children: [
                                        Icon(
                                          Icons.arrow_forward_rounded,
                                          size: 20,
                                          color: amountColor,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          forexDetails != null
                                              ? forexDetails
                                                    .formattedForeignAmount
                                              : AppFormat.currency(
                                                  _tx.amount.abs(),
                                                ),
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                            color: amountColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Destination Box
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: context.onSurfaceOverlay(
                                          lightOpacity: 0.04,
                                          darkOpacity: 0.09,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: context.onSurfaceOverlay(
                                            lightOpacity: 0.08,
                                            darkOpacity: 0.14,
                                          ),
                                          width: 0.75,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Icon(
                                            destIcon,
                                            size: 20,
                                            color: destColor,
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            destLabel,
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: context.textMuted,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            destName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: context.textPrimary,
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
                        ),

                        // Dedicated Forex Currency & Conversion Rate Card
                        if (forexDetails != null) ...[
                          const SizedBox(height: 14),
                          _buildForexCard(isDark, forexDetails),
                        ],
                      ],
                    );
                  }(),

                  // ── 3. Copyable External Reference Card (UTR / RRN) ─
                  if (_tx.externalRef != null &&
                      _tx.externalRef!.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    SpendXGlassSurface(
                      width: double.infinity,
                      level: SpendXGlassLevel.base,
                      borderRadius: BorderRadius.circular(AppRadius.m),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryBlue.withValues(
                                alpha: isDark ? 0.20 : 0.12,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.tag_rounded,
                              size: 18,
                              color: AppTheme.primaryBlue,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'EXTERNAL REF / UTR / RRN',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                    color: context.textMuted,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                SelectableText(
                                  _tx.externalRef!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                    color: context.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.copy_rounded,
                              size: 18,
                              color: AppTheme.primaryBlue,
                            ),
                            tooltip: 'Copy Reference',
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _tx.externalRef!),
                              );
                              CustomSnackBar.show(
                                context,
                                message: 'Reference copied to clipboard ✓',
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 14),

                  // ── 4. Double-Entry Accounting Ledger Breakdown ──
                  _buildLedgerBreakdown(
                    isDark,
                    fromName,
                    toName,
                    isIncome,
                    isTransfer,
                    isCcPayment,
                  ),

                  const SizedBox(height: 14),

                  // ── 5. Grouped Details Surface ───────────────────
                  SpendXGlassSurface(
                    width: double.infinity,
                    level: SpendXGlassLevel.base,
                    borderRadius: BorderRadius.circular(AppRadius.l),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _buildDetailItem(
                          icon: Icons.calendar_today_rounded,
                          label: 'Date',
                          value: DateFormat(
                            'EEEE, MMM dd, yyyy',
                          ).format(_tx.date),
                          isDark: isDark,
                        ),
                        _buildDivider(isDark),
                        _buildDetailItem(
                          icon: Icons.access_time_rounded,
                          label: 'Time',
                          value: DateFormat('hh:mm a').format(_tx.date),
                          isDark: isDark,
                        ),
                        if (isTransfer &&
                            (fromName != null || toName != null)) ...[
                          _buildDivider(isDark),
                          _buildDetailItem(
                            icon: Icons.swap_horiz_rounded,
                            label: 'Flow',
                            value:
                                '${fromName ?? "Default"} → ${toName ?? "Destination"}',
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
                        _buildDivider(isDark),
                        _buildDetailItem(
                          icon: Icons.notes_rounded,
                          label: 'Notes',
                          value: _formatNotesForDisplay(_tx.notes),
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
                      width: double.infinity,
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
                              color: context.textMuted,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
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
                              color: context.textPrimary,
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

  Widget _buildImpactBadge(
    bool isDark,
    bool isIncome,
    bool isTransfer,
    bool isCcPayment,
  ) {
    final String impactText;
    final IconData impactIcon;
    final Color impactColor;
    final Color impactBg;
    final Color impactBorder;

    final forex = AppFormat.extractForexDetails(_tx.notes, _tx.rawPayload);

    if (forex != null) {
      final signStr = isIncome ? '+' : '-';
      impactText =
          'Net Worth Impact: $signStr${forex.formattedForeignAmount} (≈ ${AppFormat.currency(forex.estimatedInr)})';
      impactIcon = isIncome
          ? Icons.trending_up_rounded
          : Icons.trending_down_rounded;
      impactColor = isIncome
          ? AppTheme.semanticIncome
          : AppTheme.semanticExpense;
      impactBg = impactColor.withValues(alpha: isDark ? 0.16 : 0.08);
      impactBorder = impactColor.withValues(alpha: isDark ? 0.32 : 0.20);
    } else if (isCcPayment || isTransfer) {
      impactText =
          'Net Worth Impact: ${AppFormat.currency(0)} (Neutral • Internal Movement)';
      impactIcon = Icons.swap_horiz_rounded;
      impactColor = Theme.of(context).colorScheme.primary;
      impactBg = impactColor.withValues(alpha: isDark ? 0.16 : 0.08);
      impactBorder = impactColor.withValues(alpha: isDark ? 0.32 : 0.20);
    } else if (isIncome) {
      impactText = 'Net Worth Impact: +${AppFormat.currency(_tx.amount.abs())}';
      impactIcon = Icons.trending_up_rounded;
      impactColor = AppTheme.semanticIncome;
      impactBg = impactColor.withValues(alpha: isDark ? 0.16 : 0.08);
      impactBorder = impactColor.withValues(alpha: isDark ? 0.32 : 0.20);
    } else {
      impactText = 'Net Worth Impact: -${AppFormat.currency(_tx.amount.abs())}';
      impactIcon = Icons.trending_down_rounded;
      impactColor = AppTheme.semanticExpense;
      impactBg = impactColor.withValues(alpha: isDark ? 0.16 : 0.08);
      impactBorder = impactColor.withValues(alpha: isDark ? 0.32 : 0.20);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: impactBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: impactBorder, width: 0.75),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(impactIcon, size: 14, color: impactColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              impactText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: impactColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerBreakdown(
    bool isDark,
    String? fromName,
    String? toName,
    bool isIncome,
    bool isTransfer,
    bool isCcPayment,
  ) {
    final forex = AppFormat.extractForexDetails(_tx.notes, _tx.rawPayload);
    final String debitAccount;
    final String debitType;
    final String creditAccount;
    final String creditType;

    if (isCcPayment) {
      debitAccount = toName ?? 'Credit Card';
      debitType = 'Liability Decreased (-)';
      creditAccount = fromName ?? 'Bank Account';
      creditType = 'Asset Decreased (-)';
    } else if (isTransfer) {
      debitAccount = toName ?? 'Destination Account';
      debitType = 'Asset Increased (+)';
      creditAccount = fromName ?? 'Source Account';
      creditType = 'Asset Decreased (-)';
    } else if (isIncome) {
      debitAccount = fromName ?? 'Bank Account';
      debitType = 'Asset Increased (+)';
      creditAccount = _cat?.name ?? 'Income Category';
      creditType = 'Revenue (+)';
    } else {
      debitAccount = _cat?.name ?? 'Expense Category';
      debitType = 'Expense Incurred (+)';
      creditAccount =
          fromName ??
          (_tx.source.contains('credit') ? 'Credit Card' : 'Bank Account');
      creditType = _tx.source.contains('credit')
          ? 'Liability Increased (+)'
          : 'Asset Decreased (-)';
    }

    return SpendXGlassSurface(
      width: double.infinity,
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(AppRadius.l),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.balance_rounded,
                size: 15,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'DOUBLE-ENTRY ACCOUNTING',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: context.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Balanced ✓',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.semanticIncome,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Debit Leg
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: context.onSurfaceOverlay(
                lightOpacity: 0.03,
                darkOpacity: 0.08,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'DR',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        debitAccount,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        debitType,
                        style: TextStyle(
                          fontSize: 10,
                          color: context.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  forex != null
                      ? forex.formattedForeignAmount
                      : AppFormat.currency(_tx.amount.abs()),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Credit Leg
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: context.onSurfaceOverlay(
                lightOpacity: 0.03,
                darkOpacity: 0.08,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.tertiary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'CR',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        creditAccount,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        creditType,
                        style: TextStyle(
                          fontSize: 10,
                          color: context.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  forex != null
                      ? forex.formattedForeignAmount
                      : AppFormat.currency(_tx.amount.abs()),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          if (forex != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 13,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Base ledger equivalent: ≈ ${AppFormat.currency(forex.estimatedInr)} (${forex.rateDisplay})',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildForexCard(bool isDark, ForexDetails forex) {
    return SpendXGlassSurface(
      width: double.infinity,
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(AppRadius.l),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: isDark ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.currency_exchange_rounded,
                  size: 19,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FOREX & CONVERSION RATE',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: context.textMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${forex.currencyName} (${forex.currencyCode})',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: isDark ? 0.20 : 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: isDark ? 0.40 : 0.25),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  forex.rateDisplay,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.onSurfaceOverlay(
                lightOpacity: 0.02,
                darkOpacity: 0.08,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: context.borderColor,
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ORIGINAL SPEND',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: context.textMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        forex.formattedForeignAmount,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: context.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'ESTIMATED INR',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: context.textMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppFormat.currency(forex.estimatedInr),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '• Conversion calculated using standard indicative exchange rates.\n• Final billing on your card statement will reflect the bank settlement rate and may include a 1.5% - 3.5% forex markup.',
            style: TextStyle(
              fontSize: 11,
              height: 1.45,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettlementBanner(BuildContext context, bool isDark) {
    final loan = _matchingOpenLoan!;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.l),
        border: Border.all(
          color: Theme.of(context).colorScheme.secondary,
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
                  color: Theme.of(context).colorScheme.secondaryContainer,
                ),
                child: Icon(
                  Icons.handshake_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.secondary,
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
                        color: isDark
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                      ),
                    ),
                    Text(
                      'Outstanding loan: ${AppFormat.currency(loan.remainingAmount)} remaining',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSecondaryContainer,
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
                      Text(
                        'Mark Loan Repaid',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _matchingOpenLoan = null),
                child: Text(
                  'Dismiss',
                  style: TextStyle(fontSize: 12, color: context.textMuted),
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
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Lending & Borrowing',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: context.textMuted,
                ),
              ),
            ],
          ),
          if (hasKeywords && !_dismissedLoanPrompt) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Payment note mentions a loan keyword. Track under Friends & Family?',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Dismiss loan suggestion',
                    child: Tooltip(
                      message: 'Dismiss suggestion',
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        child: InkWell(
                          onTap: () =>
                              setState(() => _dismissedLoanPrompt = true),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(
                              Icons.close,
                              size: 16,
                              color: isDark
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
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
                      Icon(
                        Icons.arrow_upward_rounded,
                        size: 14,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '🤝 Lent to $peerName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
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
                      Icon(
                        Icons.arrow_downward_rounded,
                        size: 14,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '🤝 Borrowed from $peerName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
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
      color: context.borderColor,
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
            color: context.onSurfaceOverlay(
              lightOpacity: 0.20,
              darkOpacity: 0.10,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: AppTheme.primaryBlue),
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
                  color: context.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
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
