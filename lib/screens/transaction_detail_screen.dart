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
      MaterialPageRoute(
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDs) {
          final effectiveFee = includeGst
              ? processingFee * 1.18
              : processingFee;
          final totalInterest =
              (_tx.amount * (interestRate / 100) * (selectedTenure / 12));
          final monthlyEmi = (_tx.amount + totalInterest) / selectedTenure;

          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              left: 24,
              right: 24,
              top: 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'EMI Configuration',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  'Converting ${AppFormat.currency(_tx.amount)}',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),

                Row(
                  children: [
                    const Text(
                      'Use Defaults',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const Spacer(),
                    Switch.adaptive(
                      value: useDefault,
                      onChanged: (v) => setDs(() => useDefault = v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                const Text(
                  'Tenure (Months)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                DropdownButton<int>(
                  value: selectedTenure,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: [3, 6, 9, 12, 18, 24, 36]
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text('$t Months'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setDs(() => selectedTenure = v!),
                ),
                const Divider(),

                if (!useDefault) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Interest (% p.a.)',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            TextField(
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                hintText: '12.0',
                                border: InputBorder.none,
                              ),
                              onChanged: (v) => setDs(
                                () => interestRate = double.tryParse(v) ?? 0.0,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Fee (₹)',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            TextField(
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                hintText: '199',
                                border: InputBorder.none,
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
                  Row(
                    children: [
                      const Text(
                        'Apply 18% GST on Fee',
                        style: TextStyle(fontSize: 13),
                      ),
                      const Spacer(),
                      Checkbox(
                        value: includeGst,
                        onChanged: (v) => setDs(() => includeGst = v!),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Monthly EMI',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            AppFormat.currency(monthlyEmi),
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text(
                            'Total Interest',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            AppFormat.currency(totalInterest),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Processing Fee: ${AppFormat.currency(effectiveFee)} (One-time)',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
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
                    child: const Text(
                      'Confirm Conversion',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isIncome = _tx.type == 'income';
    final amountColor = isIncome ? Colors.green : cs.error;

    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Transaction Detail',
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: _editTransaction,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            color: cs.error,
            onPressed: _deleteTransaction,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 32,
                          backgroundColor: amountColor.withValues(alpha: 0.1),
                          child: Icon(
                            isIncome
                                ? Icons.arrow_downward
                                : Icons.arrow_upward,
                            color: amountColor,
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppFormat.currency(_tx.amount),
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: amountColor,
                          ),
                        ),
                        Text(
                          _cat?.name ?? 'Uncategorized',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  _buildDetailRow(
                    Icons.calendar_today_outlined,
                    'Date',
                    DateFormat('EEEE, MMM dd, yyyy').format(_tx.date),
                  ),
                  _buildDetailRow(
                    Icons.access_time,
                    'Time',
                    DateFormat('hh:mm a').format(_tx.date),
                  ),
                  _buildDetailRow(
                    Icons.category_outlined,
                    'Category',
                    _cat?.name ?? 'None',
                  ),
                  _buildDetailRow(
                    Icons.notes,
                    'Notes',
                    _tx.notes.isEmpty ? 'No notes added' : _tx.notes,
                  ),
                  _buildDetailRow(
                    Icons.source_outlined,
                    'Source',
                    TextFormatter.toSmartTitleCase(_tx.source),
                  ),

                  if (_tx.source == 'credit_purchase' &&
                      _creditTxn != null &&
                      _creditTxn!.status == 'active') ...[
                    const Divider(height: 48),
                    const Text(
                      'Credit Options',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showEMIConversionSheet,
                        icon: const Icon(Icons.repeat),
                        label: const Text('Convert to EMI'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],

                  if (_creditTxn != null &&
                      _creditTxn!.status == 'converted') ...[
                    const Divider(height: 48),
                    Row(
                      children: [
                        Icon(Icons.check_circle, color: cs.primary, size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'Converted to EMI',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: cs.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
