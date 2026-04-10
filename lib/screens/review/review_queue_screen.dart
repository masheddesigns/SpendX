import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/review_queue/providers/review_providers.dart';
import '../../features/sms/models/parsed_sms.dart';
import '../../models/review_item.dart';
import '../../utils/app_format.dart';

class ReviewQueueScreen extends ConsumerWidget {
  const ReviewQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(reviewQueueProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Queue'),
        actions: [
          queueAsync.when(
            data: (items) => items.length > 1
                ? PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'approve_all') {
                        _confirmBulkApprove(context, ref, items.length);
                      } else if (value == 'reject_all') {
                        _confirmRejectAll(context, ref, items.length);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'approve_all', child: Text('Approve All')),
                      PopupMenuItem(value: 'reject_all', child: Text('Reject All')),
                    ],
                  )
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: queueAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: 64, color: cs.primary.withValues(alpha: 0.5)),
                  const SizedBox(height: 12),
                  Text('All clear!', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text('No transactions to review.',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                ],
              ),
            );
          }

          return Column(
            children: [
              // ── Summary bar ──────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: cs.surfaceContainerHigh,
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${items.length} transaction${items.length == 1 ? '' : 's'} need your review. '
                        'These were flagged because the system wasn\'t fully confident.',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _ReviewCard(item: items[index]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmBulkApprove(BuildContext context, WidgetRef ref, int count) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve All?'),
        content: Text('Auto-insert $count transactions with detected settings?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve All')),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(bulkApproveReviewProvider)();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count transactions approved')),
        );
      }
    }
  }

  Future<void> _confirmRejectAll(BuildContext context, WidgetRef ref, int count) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject All?'),
        content: Text('Discard $count pending transactions?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject All')),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(rejectAllReviewProvider)();
    }
  }
}

class _ReviewCard extends ConsumerWidget {
  final ReviewItem item;
  const _ReviewCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parsed = item.parsed;
    final cs = Theme.of(context).colorScheme;
    final isExpense = !parsed.isCredit;
    final amountColor = isExpense ? cs.error : Colors.green;

    final confidencePct = (item.confidence * 100).round();
    final (confLabel, confColor) = _confidenceInfo(item.confidence, cs);
    final reasonLabel = _reviewReason(item);
    final kindLabel = _kindLabel(parsed.kind);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Why this is here (trust signal) ──────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.help_outline, size: 13, color: Colors.amber),
                  const SizedBox(width: 4),
                  Text(reasonLabel,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.amber, fontWeight: FontWeight.w600)),
                ],
              ),
            ),

            // ── Amount + type badge + confidence ─────────
            Row(
              children: [
                Icon(isExpense ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                    color: amountColor, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${isExpense ? "-" : "+"} ${AppFormat.currency(parsed.amount)}',
                    style: TextStyle(
                        color: amountColor, fontWeight: FontWeight.w700, fontSize: 18),
                  ),
                ),
                // Kind badge
                if (kindLabel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(kindLabel,
                        style: TextStyle(fontSize: 9, color: cs.primary, fontWeight: FontWeight.w600)),
                  ),
                // Confidence badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: confColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$confidencePct% $confLabel',
                      style: TextStyle(color: confColor, fontSize: 10, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Parsed fields ────────────────────────────
            if (parsed.merchant != null && parsed.merchant!.isNotEmpty)
              _fieldRow(context, Icons.store, 'Merchant', parsed.merchant!),
            if (parsed.bankName != null)
              _fieldRow(context, Icons.account_balance, 'Bank', parsed.bankName!),
            if (parsed.vpa != null)
              _fieldRow(context, Icons.payment, 'UPI', parsed.vpa!),
            if (parsed.last4 != null)
              _fieldRow(context, Icons.credit_card, 'Account', '\u2022\u2022\u2022\u2022${parsed.last4}'),
            _fieldRow(context, Icons.calendar_today, 'Date', AppFormat.date(parsed.date)),

            const SizedBox(height: 8),

            // ── SMS body ─────────────────────────────────
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                parsed.body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, height: 1.4),
              ),
            ),

            const SizedBox(height: 12),

            // ── Actions ──────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => ref.read(rejectReviewProvider)(item.id),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Reject'),
                    style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () async {
                      await ref.read(approveReviewProvider)(item);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Got it. I\'ll remember this for next time.'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldRow(BuildContext context, IconData icon, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          SizedBox(
            width: 65,
            child: Text(label,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  (String, Color) _confidenceInfo(double conf, ColorScheme cs) {
    if (conf >= 0.70) return ('High', Colors.green);
    if (conf >= 0.50) return ('Medium', Colors.orange);
    return ('Low', cs.error);
  }

  String _reviewReason(ReviewItem item) {
    if (item.confidence < 0.50) return 'Very low confidence - needs verification';
    if (item.confidence < 0.70) return 'Medium confidence - please verify';
    if (item.parsed.merchant == null) return 'Merchant not detected';
    if (item.parsed.last4 == null) return 'Account not identified';
    return 'Flagged for review';
  }

  String? _kindLabel(SmsKind kind) {
    return switch (kind) {
      SmsKind.upiSend || SmsKind.upiReceive => 'UPI',
      SmsKind.creditCardSpend || SmsKind.creditCardPayment => 'Card',
      SmsKind.loanEmi => 'EMI',
      SmsKind.atm => 'ATM',
      SmsKind.transfer => 'Transfer',
      SmsKind.refund => 'Refund',
      SmsKind.bankDebit || SmsKind.bankCredit => 'Bank',
      SmsKind.unknown => null,
    };
  }
}
