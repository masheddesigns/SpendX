import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/category_resolver.dart';
import '../../../core/utils/merchant_extractor.dart';
import '../../../data/repositories/account_repo.dart';
import '../../../data/repositories/credit_repo.dart';
import '../../../data/repositories/review_repo.dart';
import '../../../data/repositories/transaction_repo.dart';
import '../../../models/bank_account.dart';
import '../../../shared/widgets/glass/spendx_transaction_tile.dart' show cleanTransactionDisplayTitle;
import '../../../models/transaction.dart';
import '../../../models/review_item.dart';
import '../../../services/financial_transaction_service.dart';
import '../../../services/smart_category_classifier.dart';
import '../../merchant_rules/data/merchant_rule_repo.dart';
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

    // Auto-match or auto-create digital wallet account on approval
    final text = '${parsed.rawText} ${parsed.merchant ?? ''}'.toLowerCase();
    if (text.contains('apay') || text.contains('amazon pay')) {
      final apay = accounts.where((a) => a.accountType == 'wallet' && (a.name.toLowerCase().contains('amazon') || a.name.toLowerCase().contains('apay'))).firstOrNull;
      if (apay != null) return apay.id;
      final newWallet = BankAccount(name: 'Amazon Pay Wallet', bank: 'Amazon Pay', accountType: 'wallet', balance: 0);
      return await AccountRepo().insertAccount(newWallet);
    }
    if (text.contains('paytm wallet') || text.contains('paytm balance')) {
      final paytm = accounts.where((a) => a.accountType == 'wallet' && a.name.toLowerCase().contains('paytm')).firstOrNull;
      if (paytm != null) return paytm.id;
      final newWallet = BankAccount(name: 'Paytm Wallet', bank: 'Paytm', accountType: 'wallet', balance: 0);
      return await AccountRepo().insertAccount(newWallet);
    }
    if (text.contains('mobikwik')) {
      final mobikwik = accounts.where((a) => a.accountType == 'wallet' && a.name.toLowerCase().contains('mobikwik')).firstOrNull;
      if (mobikwik != null) return mobikwik.id;
      final newWallet = BankAccount(name: 'Mobikwik Wallet', bank: 'Mobikwik', accountType: 'wallet', balance: 0);
      return await AccountRepo().insertAccount(newWallet);
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

/// Shared approve implementation used by the Review Queue UI *and* by
/// notification action buttons (Expense/Income). Keeps one code path for:
///   1. Insert transaction (with balance impact)
///   2. Learn merchant rule (merchant → category + account)
///   3. Learn merchant memory (same merchant → same category)
///   4. Mark the review item as approved
///
/// [typeOverride] forces 'expense'/'income' regardless of the parser's
/// direction signal (used by notification Expense/Income buttons).
Future<void> approveReviewItem({
  required ReviewItem item,
  String? categoryId,
  String? accountId,
  String? typeOverride,
  FinancialTransactionService? financialService,
  ReviewRepo? reviewRepo,
  TransactionRepo? transactionRepo,
}) async {
  final txRepo = transactionRepo ?? TransactionRepo();
  final rRepo = reviewRepo ?? ReviewRepo();
  final fSvc = financialService ?? FinancialTransactionService();
  final parsed = item.parsed;

  // ── Clean fallback note ───────────────────────────────────────────────────
  // Guard against raw JSON leaking in as the transaction note.
  // "{"body":"Your Apay..."}}" must never appear as a user-visible note.
  String cleanNote(String raw) {
    final trimmed = raw.trim();
    // Detect raw JSON (starts with '{' or '[') — never use as note.
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return '';
    // Truncate to a sane display length.
    return trimmed.length > 80 ? '${trimmed.substring(0, 80)}…' : trimmed;
  }

  final fallbackNote = cleanNote(parsed.rawText);

  // Balance-attribution candidates are informational: they exist because an
  // SMS balance statement could not be matched to an instrument. Approving
  // must not create a transaction (that would corrupt the ledger), so mark the
  // candidate resolved and stop.
  if (parsed.source == 'sms_balance' || parsed.method == 'balance') {
    await rRepo.approve(item.id);
    return;
  }

  // Detect if this candidate represents a credit card repayment acknowledgment:
  final isCcPayment = parsed.source == 'credit_card_payment' ||
      parsed.merchantSource == 'card_payment_receipt' ||
      RegExp(
        r'\b(?:payment\s+(?:of\s+.*?)?(?:has\s+been\s+)?(?:received|credited|settled)\s+(?:on|towards|for)\s+(?:your\s+)?.*?(?:credit\s*card|card))\b',
        caseSensitive: false,
      ).hasMatch(parsed.rawText) ||
      RegExp(r'\b(?:received\s+towards\s+your\s+credit\s*card)\b', caseSensitive: false).hasMatch(parsed.rawText);

  final type = typeOverride ??
      (isCcPayment
          ? 'credit_payment'
          : (parsed.isCredit ? 'income' : 'expense'));

  // Target credit card resolution for credit card repayments:
  String? relatedEntityId;
  if (isCcPayment) {
    try {
      final cards = await CreditRepo().getAll();
      if (parsed.last4 != null && parsed.last4!.isNotEmpty) {
        final cardMatch = cards.where((c) => c.last4 == parsed.last4).firstOrNull;
        relatedEntityId = cardMatch?.id;
      }
      if (relatedEntityId == null && parsed.bankName != null) {
        final cardMatch = cards.where((c) =>
            c.bank.toLowerCase().contains(parsed.bankName!.toLowerCase()) ||
            c.name.toLowerCase().contains(parsed.bankName!.toLowerCase())).firstOrNull;
        relatedEntityId = cardMatch?.id;
      }
      if (relatedEntityId == null && cards.isNotEmpty) {
        for (final c in cards) {
          if (parsed.rawText.toLowerCase().contains(c.bank.toLowerCase()) ||
              parsed.rawText.toLowerCase().contains(c.name.toLowerCase())) {
            relatedEntityId = c.id;
            break;
          }
        }
      }
    } catch (_) {}
  }

  // Idempotency: if this item's transaction already exists (e.g. a prior
  // approve inserted it but the item never got marked), just mark approved.
  final externalRef = parsed.refId ??
      'review|${item.id}|${parsed.amount.toStringAsFixed(2)}';
  try {
    if (await txRepo.existsByExternalRef(externalRef)) {
      await rRepo.approve(item.id);
      return;
    }
  } catch (_) {}

  // Auto-resolve the category from merchant memory when the user didn't
  // pick one — repeat merchants keep the same category.
  var effectiveCategoryId = categoryId;
  String? effectiveCategoryName;
  if (!isCcPayment && effectiveCategoryId == null) {
    final resolution = await resolveCategoryForText(
      rawText: parsed.rawText,
      merchant: parsed.merchant,
      type: type,
    );
    effectiveCategoryId = resolution.id;
    effectiveCategoryName = resolution.name;
  }

  // Auto-link the matched account so approving also updates its balance.
  var effectiveAccountId = accountId;
  if (!isCcPayment) {
    effectiveAccountId ??= await _matchAccountIdForParsed(parsed);
  }

  // ── Resolve clean transaction notes ──────────────────────────────────────
  // Priority: (1) clean display title  (2) parsed merchant name  (3) fallbackNote
  // Never use raw JSON strings or raw SMS sentences as notes.
  final cleanTitle = cleanTransactionDisplayTitle(
    parsed.merchant ?? parsed.rawText,
    categoryName: effectiveCategoryName,
    isCcPayment: isCcPayment,
  );
  final notes = isCcPayment
      ? (parsed.bankName != null ? 'Payment to ${parsed.bankName}' : 'Credit Card Repayment')
      : (cleanTitle.isNotEmpty && !cleanTitle.startsWith('{')
          ? cleanTitle
          : ((parsed.merchant != null && parsed.merchant!.trim().isNotEmpty)
              ? parsed.merchant!.trim()
              : (fallbackNote.isNotEmpty ? fallbackNote : 'Expense')));

  final transaction = Transaction(
    amount: parsed.amount,
    userId: 'offline_user',
    type: type,
    categoryId: effectiveCategoryId,
    accountId: effectiveAccountId,
    relatedEntityId: relatedEntityId,
    date: parsed.date,
    notes: notes,
    source: isCcPayment ? 'credit_card_payment' : 'review',
    externalRef: externalRef,
  );

  // 1. Insert transaction (with balance impact)
  await fSvc.createTransaction(transaction);

  // 2. Learn from this approval → merchant rules.
  //    Guarded so a learning failure can never abort the approval and leave
  //    the item stuck (which would re-collide on the next approve).
  final merchantText = parsed.merchant ?? fallbackNote;
  final learnCategoryId = effectiveCategoryId ?? transaction.categoryId;
  if (learnCategoryId != null && merchantText.isNotEmpty) {
    try {
      final keyword = MerchantExtractor.extract(merchantText);
      if (keyword.length >= 3) {
        await MerchantRuleRepo().upsert(
          keyword,
          learnCategoryId,
          accountId: effectiveAccountId ?? transaction.accountId,
        );
      }
    } catch (_) {}
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

  // 4. Mark as approved — always runs once the transaction is inserted.
  await rRepo.approve(item.id);
}

/// Approve a review item: insert as transaction, learn from it, remove from queue.
///
/// This is the primary learning signal — every approval teaches the system.
final approveReviewProvider = Provider((ref) {
  return (
    ReviewItem item, {
    String? categoryId,
    String? accountId,
  }) async {
    final financialService = ref.read(financialTransactionServiceProvider);
    final reviewRepo = ref.read(reviewRepoProvider);
    final txRepo = ref.read(transactionRepoProvider);
    await approveReviewItem(
      item: item,
      categoryId: categoryId,
      accountId: accountId,
      financialService: financialService,
      reviewRepo: reviewRepo,
      transactionRepo: txRepo,
    );
    ref.invalidate(reviewQueueProvider);
    ref.invalidate(reviewQueueCountProvider);
    ref.invalidate(transactionsProvider);
    ref.invalidate(accountsProvider);
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
