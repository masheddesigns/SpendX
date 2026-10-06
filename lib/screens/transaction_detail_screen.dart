import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../models/category.dart';
import '../models/credit_transaction.dart';
import '../utils/app_format.dart';
import '../widgets/spendx_app_bar.dart';
import '../widgets/custom_dialog.dart';
import '../widgets/custom_snackbar.dart';
import 'expense/add_expense_screen.dart';
import '../domain/credit/credit_card_service.dart';
import '../utils/text_formatter.dart';
import '../data/providers.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/glass/spendx_scaffold.dart';
import '../shared/widgets/glass/spendx_glass_surface.dart';
import '../shared/widgets/glass/spendx_glass_button.dart';
import '../shared/widgets/glass/spendx_glass_sheet.dart';
import '../theme/app_theme.dart';

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

  @override
  void initState() {
    super.initState();
    _tx = widget.transaction;
    _cat = widget.category;
    _loadCreditDetails();
  }

  Future<void> _loadCreditDetails() async {
    if (_tx.source == 'credit_purchase' && _tx.relatedEntityId != null) {
      final ctx = await ref.read(
        creditTransactionByIdProvider(_tx.relatedEntityId!).future,
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
      await ProviderScope.containerOf(
        context,
        listen: false,
      ).read(transactionsProvider.notifier).remove(_tx.id);
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
    final amountColor = isIncome ? AppTheme.semanticIncome : AppTheme.semanticExpense;

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
                            isIncome
                                ? Icons.arrow_downward_rounded
                                : Icons.arrow_upward_rounded,
                            color: amountColor,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '${isIncome ? '+' : '-'}${AppFormat.currency(_tx.amount)}',
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
                            _cat?.name ?? 'Uncategorized',
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
                        _buildDivider(isDark),
                        _buildDetailItem(
                          icon: Icons.category_rounded,
                          label: 'Category',
                          value: _cat?.name ?? 'None',
                          isDark: isDark,
                        ),
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
                ],
              ),
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
