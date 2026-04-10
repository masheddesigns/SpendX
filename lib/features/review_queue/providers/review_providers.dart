import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/review_repo.dart';
import '../../../models/review_item.dart';
import '../../../models/transaction.dart';
import '../../merchant_rules/providers/merchant_rule_providers.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../accounts/providers/account_providers.dart';

final reviewRepoProvider = Provider<ReviewRepo>((ref) => ReviewRepo());

/// Pending review items.
final reviewQueueProvider = FutureProvider<List<ReviewItem>>((ref) async {
  final items = await ref.watch(reviewRepoProvider).getPending();
  debugPrint('📋 Review queue: ${items.length} pending');
  return items;
});

/// Count of pending reviews (for badges).
final reviewQueueCountProvider = FutureProvider<int>((ref) async {
  return ref.watch(reviewRepoProvider).getPendingCount();
});

/// Approve a review item: insert as transaction, learn from it, remove from queue.
///
/// When the user approves (optionally overriding category/account), the system:
///   1. Inserts the transaction
///   2. Learns a merchant rule (merchant → category + account)
///   3. Marks the review item as approved
///
/// This is the primary learning signal — every approval teaches the system.
final approveReviewProvider = Provider((ref) {
  return (
    ReviewItem item, {
    String? categoryId,
    String? accountId,
  }) async {
    final parsed = item.parsed;
    final transaction = Transaction(
      amount: parsed.amount,
      userId: 'offline_user',
      type: parsed.isCredit ? 'income' : 'expense',
      categoryId: categoryId,
      accountId: accountId,
      date: parsed.date,
      notes: parsed.merchant ?? parsed.body,
      source: 'sms_review',
      externalRef: parsed.refId ??
          '${parsed.sender}|${parsed.date.millisecondsSinceEpoch}|'
          '${parsed.amount.toStringAsFixed(2)}|${parsed.last4 ?? ''}',
    );

    // 1. Insert transaction (with balance impact)
    await ref.read(addTransactionProvider)(transaction);

    // 2. Learn from this approval → merchant rules
    //    This turns every manual approval into a future auto-categorization.
    final merchantText = parsed.merchant ?? parsed.body;
    final learnCategoryId = categoryId ?? transaction.categoryId;
    if (learnCategoryId != null && merchantText.isNotEmpty) {
      await ref.read(learnMerchantRuleProvider)(
        text: merchantText,
        categoryId: learnCategoryId,
        accountId: accountId ?? transaction.accountId,
      );
    }

    // 3. Mark as approved
    await ref.read(reviewRepoProvider).approve(item.id);
    ref.invalidate(reviewQueueProvider);
    ref.invalidate(reviewQueueCountProvider);
  };
});

/// Reject (delete) a review item.
final rejectReviewProvider = Provider((ref) {
  return (String id) async {
    await ref.read(reviewRepoProvider).reject(id);
    ref.invalidate(reviewQueueProvider);
    ref.invalidate(reviewQueueCountProvider);
  };
});

/// Bulk approve all pending items with auto-detected categories/accounts.
final bulkApproveReviewProvider = Provider((ref) {
  return () async {
    final items = await ref.read(reviewRepoProvider).getPending();
    for (final item in items) {
      await ref.read(approveReviewProvider)(item);
    }
    ref.invalidate(reviewQueueProvider);
    ref.invalidate(reviewQueueCountProvider);
    ref.invalidate(transactionsProvider);
    ref.invalidate(accountsProvider);
  };
});

/// Reject all pending items.
final rejectAllReviewProvider = Provider((ref) {
  return () async {
    await ref.read(reviewRepoProvider).rejectAll();
    ref.invalidate(reviewQueueProvider);
    ref.invalidate(reviewQueueCountProvider);
  };
});
