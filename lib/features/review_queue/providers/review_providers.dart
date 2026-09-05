import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/category_resolver.dart';
import '../../../data/repositories/account_repo.dart';
import '../../../data/repositories/review_repo.dart';
import '../../../models/review_item.dart';
import '../../../models/transaction.dart';
import '../../../services/smart_category_classifier.dart';
import '../../merchant_rules/providers/merchant_rule_providers.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../accounts/providers/account_providers.dart';

/// Matches the account (by account-number last4 / bank name) for an
/// auto-detected transaction so approving it also updates that balance.
Future<String?> _matchAccountIdForParsed(ParsedTransaction parsed) async {
  try {
    final accounts = await AccountRepo().getAll();
    if (parsed.last4 != null) {
      final byLast4 = accounts.where((a) => a.last4 == parsed.last4).firstOrNull;
      if (byLast4 != null) return byLast4.id;
    }
    if (parsed.bankName != null) {
      final kw = parsed.bankName!.toLowerCase();
      final byBank = accounts
          .where(
            (a) =>
                a.bank.toLowerCase().contains(kw) ||
                a.name.toLowerCase().contains(kw),
          )
          .toList();
      if (byBank.length == 1) return byBank.first.id;
    }
  } catch (_) {}
  return null;
}

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
    final fallbackNote = parsed.rawText.length > 100
        ? parsed.rawText.substring(0, 100)
        : parsed.rawText;

    // Auto-resolve the category from merchant memory when the user didn't
    // pick one — repeat merchants keep the same category.
    var effectiveCategoryId = categoryId;
    String? effectiveCategoryName;
    if (effectiveCategoryId == null) {
      final resolution = await resolveCategoryForText(
        rawText: parsed.rawText,
        merchant: parsed.merchant,
        type: parsed.isCredit ? 'income' : 'expense',
      );
      effectiveCategoryId = resolution.id;
      effectiveCategoryName = resolution.name;
    }

    // Auto-link the matched account so approving also updates its balance.
    var effectiveAccountId = accountId;
    effectiveAccountId ??= await _matchAccountIdForParsed(parsed);

    final transaction = Transaction(
      amount: parsed.amount,
      userId: 'offline_user',
      type: parsed.isCredit ? 'income' : 'expense',
      categoryId: effectiveCategoryId,
      accountId: effectiveAccountId,
      date: parsed.date,
      notes: parsed.merchant ?? fallbackNote,
      source: 'review',
      externalRef: parsed.refId ??
          '${parsed.source ?? 'review'}|${parsed.date.millisecondsSinceEpoch}|'
          '${parsed.amount.toStringAsFixed(2)}|${parsed.last4 ?? ''}',
    );

    // 1. Insert transaction (with balance impact)
    await ref.read(addTransactionProvider)(transaction);

    // 2. Learn from this approval → merchant rules
    //    This turns every manual approval into a future auto-categorization.
    final merchantText = parsed.merchant ?? fallbackNote;
    final learnCategoryId = effectiveCategoryId ?? transaction.categoryId;
    if (learnCategoryId != null && merchantText.isNotEmpty) {
      await ref.read(learnMerchantRuleProvider)(
        text: merchantText,
        categoryId: learnCategoryId,
        accountId: effectiveAccountId ?? transaction.accountId,
      );
    }

    // 3. Learn merchant memory so the same merchant keeps the same category.
    if (parsed.merchant != null && effectiveCategoryName != null) {
      try {
        await SmartCategoryClassifier.instance.learn(
          rawText: parsed.rawText,
          merchant: parsed.merchant,
          category: effectiveCategoryName,
        );
      } catch (_) {}
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
