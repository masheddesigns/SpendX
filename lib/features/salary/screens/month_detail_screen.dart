import '../../../services/haptic_service.dart';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../utils/app_format.dart';
import '../../../models/bank_account.dart';
import '../../../models/transaction.dart';
import '../../../features/accounts/providers/account_providers.dart';
import '../../../features/categories/providers/category_providers.dart';
import '../../../features/transactions/providers/transaction_providers.dart';
import '../../salary_ledger/salary_ledger_models.dart';
import '../../salary_ledger/salary_ledger_notifier.dart';

/// Detail screen for a single salary month — shows full breakdown + payment list.
class MonthDetailScreen extends ConsumerWidget {
  final String monthId;

  const MonthDetailScreen({super.key, required this.monthId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final months = ref.watch(
      salaryLedgerProvider.select((s) => s.valueOrNull?.months ?? []),
    );
    final monthView = months.where((m) => m.month.id == monthId).firstOrNull;

    if (monthView == null) {
      return Scaffold(
        
        appBar: AppBar(
            title: Text('Month Detail'),
            backgroundColor: Colors.transparent),
        body: const Center(
            child: Text('Month not found',
                style: TextStyle(color: Colors.grey))),
      );
    }

    final m = monthView;
    final monthDate = DateTime.tryParse('${m.month.month}-01');
    final monthName = monthDate != null
        ? DateFormat('MMMM yyyy').format(monthDate)
        : m.month.month;
    final progress = m.month.expectedAmount > 0
        ? (m.salaryPaid / m.month.expectedAmount).clamp(0.0, 1.0)
        : 0.0;

    // First payment date for "Paid on" label
    final salaryPayments =
        m.payments.where((p) => p.type != PaymentType.bonus).toList();
    salaryPayments.sort((a, b) => a.paidDate.compareTo(b.paidDate));
    final firstPaidDate = salaryPayments.isNotEmpty
        ? salaryPayments.first.paidDate
        : null;

    return Scaffold(
      
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(monthName, style: const TextStyle(fontSize: 17)),
            Text('for ${monthDate != null ? DateFormat('MMMM').format(monthDate) : m.month.month} work',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.normal)),
          ],
        ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.greenAccent),
            tooltip: 'Add Payment',
            onPressed: () => _showAddPayment(context, ref, m),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit_expected') {
                _showEditExpectedDialog(context, ref, m);
              } else if (v == 'toggle_hold') {
                final notifier = ref.read(salaryLedgerProvider.notifier);
                if (m.month.isOnHold) {
                  await notifier.removeMonthHold(monthId);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Hold released')),
                    );
                  }
                } else {
                  await notifier.putMonthOnHold(monthId);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Month put on hold')),
                    );
                  }
                }
              } else if (v == 'delete') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Delete Month?'),
                    content: const Text(
                        'This will delete this month and all its payments.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text('Delete',
                              style: TextStyle(color: Colors.red))),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  final notifier = ref.read(salaryLedgerProvider.notifier);
                  HapticService.instance.critical();
                  Navigator.pop(context); // close detail screen first
                  Future.microtask(() => notifier.deleteMonth(monthId));
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'edit_expected',
                  child: Text('Edit Expected Amount')),
              PopupMenuItem(
                  value: 'toggle_hold',
                  child: Text(m.month.isOnHold
                      ? 'Release Hold'
                      : 'Put On Hold')),
              const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete Month',
                      style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Status Banner ──────────────────────────────
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _statusBg(m.status),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15)),
            ),
            child: Column(
              children: [
                Text(m.status.label,
                    style: TextStyle(
                        color: _statusColor(m.status),
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(AppFormat.currency(m.totalPaid),
                    style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface)),
                const SizedBox(height: 4),
                Text(
                    'of ${AppFormat.currency(m.month.expectedAmount)} expected',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                    valueColor:
                        AlwaysStoppedAnimation(_statusColor(m.status)),
                    minHeight: 8,
                  ),
                ),
                if (firstPaidDate != null || m.delayDays > 0) ...[
                  const SizedBox(height: 12),
                  if (firstPaidDate != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          m.delayDays > 0
                              ? Icons.warning_amber_rounded
                              : Icons.check_circle_outline_rounded,
                          color: m.delayDays > 0
                              ? Colors.orangeAccent
                              : Colors.greenAccent,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          m.delayDays > 0
                              ? 'Paid on ${DateFormat('dd MMM').format(firstPaidDate)} (${m.delayDays}d late)'
                              : 'Paid on ${DateFormat('dd MMM').format(firstPaidDate)} (on time)',
                          style: TextStyle(
                            color: m.delayDays > 0
                                ? Colors.orangeAccent
                                : Colors.greenAccent,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    )
                  else if (m.delayDays > 0)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Colors.redAccent, size: 16),
                        const SizedBox(width: 6),
                        Text('${m.delayDays} days overdue',
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 13)),
                      ],
                    ),
                ],
              ],
            ),
          ),
          // ── On Hold Banner ──────────────────────────────
          if (m.month.isOnHold) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.pause_circle_filled, color: Colors.amber, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('This month is on hold',
                        style: TextStyle(color: Colors.amber.shade200, fontSize: 13)),
                  ),
                  TextButton(
                    onPressed: () async {
                      await ref.read(salaryLedgerProvider.notifier).removeMonthHold(monthId);
                    },
                    child: const Text('Release', style: TextStyle(color: Colors.amber)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),

          // ── KPI Row ────────────────────────────────────
          Row(
            children: [
              Expanded(
                  child: _kpi(context,
                      'Salary', AppFormat.currency(m.salaryPaid), Colors.greenAccent)),
              const SizedBox(width: 8),
              Expanded(
                  child: _kpi(context,
                      'Bonus', AppFormat.currency(m.bonusTotal), Colors.purpleAccent)),
              const SizedBox(width: 8),
              Expanded(
                  child: _kpi(context,
                      'Remaining', AppFormat.currency(m.remaining), Colors.orangeAccent)),
            ],
          ),
          const SizedBox(height: 16),

          // ── Due Date Info ──────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.event_rounded,
                    color: Colors.blueAccent, size: 20),
                const SizedBox(width: 10),
                Text(
                    'Due: ${DateFormat('dd MMM yyyy').format(m.month.dueDate)}',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Payments List ──────────────────────────────
          Text('Payments (${m.payments.length})',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 16)),
          const SizedBox(height: 12),

          if (m.payments.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text('No payments recorded',
                    style: TextStyle(color: Colors.grey.shade500)),
              ),
            )
          else
            ...m.payments.map((p) => _PaymentTile(
                  payment: p,
                  onDelete: () async {
                    await ref
                        .read(salaryLedgerProvider.notifier)
                        .deletePayment(p.id);
                  },
                )),

          const SizedBox(height: 48),
        ],
      ),
    );
  }

  Widget _kpi(BuildContext context, String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 15, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Color _statusBg(SalaryStatus s) => switch (s) {
        SalaryStatus.paid => Colors.green.shade900.withValues(alpha: 0.25),
        SalaryStatus.partial => Colors.orange.shade900.withValues(alpha: 0.25),
        SalaryStatus.pending => const Color(0xFF1C1C1E),
        SalaryStatus.onHold => Colors.amber.shade900.withValues(alpha: 0.2),
        SalaryStatus.overdue => Colors.red.shade900.withValues(alpha: 0.25),
      };

  Color _statusColor(SalaryStatus s) => switch (s) {
        SalaryStatus.paid => Colors.greenAccent,
        SalaryStatus.partial => Colors.orangeAccent,
        SalaryStatus.pending => Colors.grey.shade500,
        SalaryStatus.onHold => Colors.amber,
        SalaryStatus.overdue => Colors.red,
      };
}

// ── Payment Tile ─────────────────────────────────────────────────────────

class _PaymentTile extends StatelessWidget {
  final SalaryLedgerEntry payment;
  final VoidCallback onDelete;

  const _PaymentTile({required this.payment, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final icon = switch (payment.type) {
      PaymentType.bonus => Icons.star_rounded,
      PaymentType.adjustment => Icons.tune_rounded,
      PaymentType.salary => Icons.payment_rounded,
    };
    final typeColor = switch (payment.type) {
      PaymentType.bonus => Colors.purpleAccent,
      PaymentType.adjustment => Colors.blueAccent,
      PaymentType.salary => Colors.greenAccent,
    };

    return Dismissible(
      key: Key(payment.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.red.shade800,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text('Delete Payment?'),
                content: Text(
                    'Remove ${AppFormat.currency(payment.amount)} ${payment.type.name} payment?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text('Delete',
                          style: TextStyle(color: Colors.red))),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => onDelete(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.surfaceContainerHighest),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: typeColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: typeColor, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(payment.type.name.toUpperCase(),
                      style: TextStyle(
                          color: typeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5)),
                  const SizedBox(height: 2),
                  Text(
                      DateFormat('dd MMM yyyy').format(payment.paidDate),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                  if (payment.note != null && payment.note!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(payment.note!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
                    ),
                ],
              ),
            ),
            Text(AppFormat.currency(payment.amount),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

// ── Add Payment Sheet (proper lifecycle — no controller leaks) ───────────

void _showAddPayment(
    BuildContext context, WidgetRef ref, SalaryMonthView month) {
  // Guard: don't open if a modal route is already on top
  if (ModalRoute.of(context)?.isCurrent != true) return;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddPaymentSheet(month: month),
  );
}

class _AddPaymentSheet extends ConsumerStatefulWidget {
  final SalaryMonthView month;
  const _AddPaymentSheet({required this.month});

  @override
  ConsumerState<_AddPaymentSheet> createState() => _AddPaymentSheetState();
}

class _AddPaymentSheetState extends ConsumerState<_AddPaymentSheet> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;
  PaymentType _type = PaymentType.salary;
  late DateTime _paidDate;
  String? _selectedAccountId;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController();
    _noteCtrl = TextEditingController();
    _paidDate = DateTime.now();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _setAmount(String val) {
    _amountCtrl.text = val;
    _amountCtrl.selection = TextSelection.collapsed(offset: val.length);
    setState(() {});
  }

  double get _parsed => double.tryParse(_amountCtrl.text) ?? 0;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _paidDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) setState(() => _paidDate = picked);
  }

  Future<void> _submit() async {
    if (_parsed <= 0) return;
    final note = _noteCtrl.text.trim();
    final entry = SalaryLedgerEntry(
      monthId: widget.month.month.id,
      amount: _parsed,
      type: _type,
      paidDate: _paidDate,
      note: note.isNotEmpty ? note : null,
    );
    final notifier = ref.read(salaryLedgerProvider.notifier);
    final accountId = _selectedAccountId;

    // Auto-find "Salary" category for the transaction
    String? salaryCategoryId;
    try {
      final categories = ref.read(categoriesProvider).valueOrNull ?? [];
      final salaryCategory = categories.firstWhere(
        (c) => c.name.toLowerCase() == 'salary' && c.type == 'income',
      );
      salaryCategoryId = salaryCategory.id;
    } catch (_) {
      // No salary category found — leave null
    }

    // Also create a transaction + update account balance if account selected
    Transaction? salaryTxn;
    if (accountId != null) {
      salaryTxn = Transaction(
        userId: 'offline_user',
        type: 'income',
        amount: _parsed,
        date: _paidDate,
        notes: 'Salary: ${_type.name}${note.isNotEmpty ? " - $note" : ""}',
        source: 'salary',
        accountId: accountId,
        categoryId: salaryCategoryId,
        tags: const [],
      );
    }
    final addTxn = salaryTxn != null
        ? ref.read(addTransactionProvider)
        : null;

    // Pop FIRST
    Navigator.pop(context);
    Future.microtask(() async {
      HapticService.instance.success();
      await notifier.addPayment(entry);
      if (salaryTxn != null && addTxn != null) {
        await addTxn(salaryTxn);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.month;
    final remaining = m.remaining;
    final half = m.month.expectedAmount / 2;

    return SingleChildScrollView(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.outline,
                            borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 20),
                  Text('Add Payment',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onSurface)),
                  const SizedBox(height: 20),

                  // Payment type
                  SegmentedButton<PaymentType>(
                    segments: const [
                      ButtonSegment(
                          value: PaymentType.salary, label: Text('Salary')),
                      ButtonSegment(
                          value: PaymentType.bonus, label: Text('Bonus')),
                      ButtonSegment(
                          value: PaymentType.adjustment, label: Text('Other')),
                    ],
                    selected: {_type},
                    onSelectionChanged: (s) =>
                        setState(() => _type = s.first),
                  ),
                  const SizedBox(height: 16),

                  // Quick amount suggestions
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _quickChip('Full', m.month.expectedAmount,
                            () => _setAmount(m.month.expectedAmount.toStringAsFixed(0))),
                        if (remaining > 0)
                          _quickChip('Remaining', remaining,
                              () => _setAmount(remaining.toStringAsFixed(0))),
                        _quickChip('50%', half,
                            () => _setAmount(half.toStringAsFixed(0))),
                        _quickChip('+10k', 10000,
                            () => _setAmount('10000')),
                        _quickChip('+20k', 20000,
                            () => _setAmount('20000')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Amount field
                  TextField(
                    controller: _amountCtrl,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 24),
                    decoration: InputDecoration(
                      labelText: 'Amount',
                      labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      prefixText: '\u20b9 ',
                      prefixStyle:
                          TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 24),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Date picker
                  GestureDetector(
                    onTap: _pickDate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today_rounded,
                              color: Colors.blueAccent, size: 18),
                          const SizedBox(width: 10),
                          Text(
                              'Paid on: ${DateFormat('dd MMM yyyy').format(_paidDate)}',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurface, fontSize: 15)),
                          const Spacer(),
                          Icon(Icons.edit_rounded,
                              color: Theme.of(context).colorScheme.onSurfaceVariant, size: 16),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Account selector (credit salary to which account)
                  Consumer(
                    builder: (ctx, ref, _) {
                      final accountsAsync = ref.watch(accountsProvider);
                      final accounts =
                          accountsAsync.valueOrNull ?? <BankAccount>[];
                      if (accounts.isEmpty) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String?>(
                            value: _selectedAccountId,
                            isExpanded: true,
                            hint: Text('Credit to account (optional)',
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontSize: 14)),
                            dropdownColor: const Color(0xFF2A2A2A),
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface, fontSize: 14),
                            items: [
                              const DropdownMenuItem<String?>(
                                value: null,
                                child: Text('No account',
                                    style: TextStyle(
                                        color: Colors.grey)),
                              ),
                              ...accounts.map((a) => DropdownMenuItem(
                                    value: a.id,
                                    child: Text(a.name),
                                  )),
                            ],
                            onChanged: (v) =>
                                setState(() => _selectedAccountId = v),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 14),

                  // Notes (optional)
                  TextField(
                    controller: _noteCtrl,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Note (optional)',
                      hintStyle: TextStyle(color: Colors.grey.shade600),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Submit
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      onPressed: _parsed > 0 ? _submit : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text('Add Payment',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
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

  Widget _quickChip(String label, double value, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text('$label (\u20b9${value.toStringAsFixed(0)})',
            style: const TextStyle(color: Colors.blueAccent, fontSize: 12)),
        backgroundColor: Colors.blueAccent.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.blueAccent)),
        onPressed: onTap,
      ),
    );
  }
}

// ── Edit Expected Amount Dialog ──────────────────────────────────────────

void _showEditExpectedDialog(
    BuildContext context, WidgetRef ref, SalaryMonthView month) {
  // Guard against stacking
  if (ModalRoute.of(context)?.isCurrent != true) return;

  final controller = TextEditingController(
      text: month.month.expectedAmount.toStringAsFixed(0));

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      title: Text('Edit Expected Amount',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: 'Expected Salary',
          labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          prefixText: '\u20b9 ',
          prefixStyle: const TextStyle(color: Colors.white),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.blueAccent),
          onPressed: () {
            final amount = double.tryParse(controller.text);
            if (amount != null && amount > 0) {
              final notifier = ref.read(salaryLedgerProvider.notifier);
              final monthId = month.month.id;
              // Pop FIRST, then update state
              Navigator.pop(ctx);
              Future.microtask(
                  () => notifier.updateMonthExpectedAmount(monthId, amount));
            }
          },
          child: Text('Save'),
        ),
      ],
    ),
  ).whenComplete(() => controller.dispose());
}
