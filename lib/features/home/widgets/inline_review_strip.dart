import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../review_queue/providers/review_providers.dart';
import '../../../models/review_item.dart';
import '../../../utils/app_format.dart';
import '../../../screens/review/review_queue_screen.dart';

/// Inline review cards shown on Home when <= 3 items need review.
/// Quick approve/reject without leaving the dashboard.
class InlineReviewStrip extends ConsumerWidget {
  const InlineReviewStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueAsync = ref.watch(reviewQueueProvider);

    return queueAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();

        // If > 3, show a "View all" link instead of inline cards
        if (items.length > 3) {
          return _ViewAllBanner(count: items.length);
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.rate_review_rounded,
                      size: 14, color: Colors.orange.shade400),
                  const SizedBox(width: 6),
                  Text('Needs Review',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade400)),
                ],
              ),
              const SizedBox(height: 6),
              ...items.map((item) => _MiniReviewCard(item: item)),
            ],
          ),
        );
      },
    );
  }
}

class _ViewAllBanner extends StatelessWidget {
  final int count;
  const _ViewAllBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GestureDetector(
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ReviewQueueScreen())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.rate_review_rounded,
                  size: 16, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$count transactions need review',
                  style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.orange),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniReviewCard extends ConsumerWidget {
  final ReviewItem item;
  const _MiniReviewCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final parsed = item.parsed;
    final isExpense = !parsed.isCredit;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          // Amount
          Text(
            '${isExpense ? "-" : "+"} ${AppFormat.currency(parsed.amount)}',
            style: TextStyle(
              color: isExpense ? cs.error : Colors.green,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 10),
          // Merchant or "Unknown"
          Expanded(
            child: Text(
              parsed.merchant ?? 'Unknown merchant',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Quick actions with undo
          IconButton(
            icon: Icon(Icons.close, size: 18, color: cs.error),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              ref.read(rejectReviewProvider)(item.id);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Transaction rejected'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            tooltip: 'Reject',
          ),
          IconButton(
            icon: Icon(Icons.check, size: 18, color: cs.primary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              ref.read(approveReviewProvider)(item);
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Transaction added'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            tooltip: 'Approve',
          ),
        ],
      ),
    );
  }
}
