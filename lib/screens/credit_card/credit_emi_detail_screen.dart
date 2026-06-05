import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../models/credit_emi.dart';
import '../../models/emi_installment.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_format.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../shared/widgets/error_state_widget.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../shared/widgets/undo_snackbar_listener.dart';

class CreditEmiDetailScreen extends ConsumerStatefulWidget {
  final CreditEMI emi;

  const CreditEmiDetailScreen({super.key, required this.emi});

  @override
  ConsumerState<CreditEmiDetailScreen> createState() =>
      _CreditEmiDetailScreenState();
}

class _CreditEmiDetailScreenState extends ConsumerState<CreditEmiDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final installmentsAsync = ref.watch(emiInstallmentsProvider(widget.emi.id));

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is EMIInstallment,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('EMI Details'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: installmentsAsync.when(
          loading: () => const SkeletonLoader.transactions(),
          error: (error, _) => ErrorStateWidget(error: error, onRetry: () => ref.invalidate(emiInstallmentsProvider(widget.emi.id))),
          data: (installments) => Column(
            children: [
              _buildSummaryCard(),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: installments.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    return _buildInstallmentTile(
                      installments[index],
                      index + 1,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    final totalAmount = widget.emi.principalAmount + widget.emi.interestAmount;
    final progress = widget.emi.tenureMonths > 0
        ? widget.emi.paidMonths / widget.emi.tenureMonths
        : 0.0;

    return Container(
      margin: const EdgeInsets.all(AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Total EMI Value',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  Text(
                    AppFormat.currency(totalAmount),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${widget.emi.interestRate}% p.a.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMetric(
                'Principal',
                AppFormat.currency(widget.emi.principalAmount),
              ),
              _buildMetric(
                'Interest',
                AppFormat.currency(widget.emi.interestAmount),
              ),
              _buildMetric(
                'Fees',
                AppFormat.currency(widget.emi.processingFee),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${widget.emi.paidMonths} of ${widget.emi.tenureMonths} Paid',
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildInstallmentTile(EMIInstallment inst, int index) {
    final isPaid = inst.status == 'paid';
    final now = DateTime.now();
    final isOverdue = !isPaid && inst.dueDate.isBefore(now);
    final isDueSoon =
        !isPaid && !isOverdue && inst.dueDate.difference(now).inDays <= 5;
    final cs = Theme.of(context).colorScheme;

    Color statusColor;
    String statusLabel;
    IconData statusIcon;
    if (isPaid) {
      statusColor = cs.primary;
      statusLabel = 'Paid';
      statusIcon = Icons.check_circle_rounded;
    } else if (isOverdue) {
      statusColor = cs.error;
      statusLabel = 'Overdue';
      statusIcon = Icons.warning_rounded;
    } else if (isDueSoon) {
      statusColor = Colors.orange;
      statusLabel = 'Due soon';
      statusIcon = Icons.schedule_rounded;
    } else {
      statusColor = cs.onSurfaceVariant;
      statusLabel = 'Pending';
      statusIcon = Icons.radio_button_unchecked;
    }

    return InkWell(
      onTap: () => _showInstallmentActions(inst, index),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPaid
                ? cs.primary.withValues(alpha: 0.3)
                : isOverdue
                ? cs.error.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(statusIcon, color: statusColor, size: 22),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Installment #$index  •  ${AppFormat.currency(inst.amount)}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      decoration: isPaid ? TextDecoration.lineThrough : null,
                      color: isPaid ? cs.onSurfaceVariant : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Due: ${DateFormat('MMM dd, yyyy').format(inst.dueDate)}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  if (inst.principal > 0 || inst.interest > 0) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _miniChip(
                          'P: ${AppFormat.currency(inst.principal)}',
                          Colors.blue,
                        ),
                        const SizedBox(width: 6),
                        _miniChip(
                          'I: ${AppFormat.currency(inst.interest)}',
                          Colors.orange,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _showInstallmentActions(EMIInstallment inst, int index) {
    final cs = Theme.of(context).colorScheme;
    final isPaid = inst.status == 'paid';

    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 20),
          Text(
            'Installment #$index',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(
              isPaid ? Icons.undo : Icons.check_circle_outline,
              color: cs.primary,
            ),
            title: Text(isPaid ? 'Mark as Pending' : 'Mark as Paid'),
            onTap: () async {
              Navigator.pop(ctx);
              await _togglePaymentStatus(inst);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit Installment'),
            onTap: () {
              Navigator.pop(ctx);
              _editInstallment(inst);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: cs.error),
            title: Text(
              'Delete Installment',
              style: TextStyle(color: cs.error),
            ),
            onTap: () async {
              Navigator.pop(ctx);
              await _confirmDeleteInstallment(inst);
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _togglePaymentStatus(EMIInstallment inst) async {
    await ref
        .read(emiInstallmentsProvider(widget.emi.id).notifier)
        .togglePaymentStatus(installment: inst, emi: widget.emi);

    _invalidateAll();
  }

  Future<void> _editInstallment(EMIInstallment inst) async {
    double tempAmount = inst.amount;
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Amount'),
        content: TextField(
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: inst.amount.toString()),
          onChanged: (v) => tempAmount = double.tryParse(v) ?? inst.amount,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, tempAmount),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null) {
      await ref
          .read(emiInstallmentsProvider(widget.emi.id).notifier)
          .replace(inst.copyWith(amount: result));
      _invalidateAll();
    }
  }

  Future<void> _confirmDeleteInstallment(EMIInstallment inst) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Installment?'),
        content: const Text(
          'This will remove this installment record. It will not affect the ledger.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ref
          .read(emiInstallmentsProvider(widget.emi.id).notifier)
          .remove(inst);
      _invalidateAll();
    }
  }

  void _invalidateAll() {
    ref.invalidate(creditActiveEmisProvider(widget.emi.cardId));
    ref.invalidate(creditOutstandingProvider(widget.emi.cardId));
    ref.invalidate(liabilitiesSummaryProvider);
  }
}
