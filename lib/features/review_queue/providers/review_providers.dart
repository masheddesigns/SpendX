import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/category_resolver.dart';
import '../../../core/utils/merchant_extractor.dart';
import '../../../data/repositories/account_repo.dart';
import '../../../data/repositories/credit_repo.dart';
import '../../../data/repositories/review_repo.dart';
import '../../../data/repositories/transaction_repo.dart';
import '../../../models/bank_account.dart';
import '../../../models/credit_card.dart';
import '../../../shared/widgets/glass/spendx_transaction_tile.dart' show cleanTransactionDisplayTitle;
import '../../../models/transaction.dart';
import '../../../models/review_item.dart';
import '../../../services/financial_transaction_service.dart';
import '../../../services/smart_category_classifier.dart';
import '../../../services/balance_attribution.dart';
import '../../../services/data_change_bus.dart';
import '../../../services/transaction_text_parser.dart';
import '../../../services/sms_import_service.dart';
import '../../merchant_rules/data/merchant_rule_repo.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../accounts/providers/account_providers.dart';

/// Matches the account (by account-number last4 / bank name) for an
/// auto-detected transaction so approving it also updates that balance.
Future<String?> _matchAccountIdForParsed(ParsedTransaction parsed) async {
  try {
    final accounts = await AccountRepo().getAll();
    if (parsed.last4 != null) {
      final byLast4 = accounts.where((a) => a.last4 == parsed.last4).toList();
      if (byLast4.isNotEmpty) {
        if (parsed.bankName != null) {
          final matching = byLast4.where((a) => BalanceAttribution.issuerMatches(parsed.bankName!, a.bank, a.name)).firstOrNull;
          if (matching != null) return matching.id;
        } else if (parsed.method != 'card') {
          return byLast4.first.id;
        }
      }
    }
    if (parsed.bankName != null) {
      final kw = parsed.bankName!.toLowerCase();
      final byBank = accounts
          .where(
            (a) =>
                a.bank.toLowerCase().contains(kw) ||
                a.name.toLowerCase().contains(kw) ||
                BalanceAttribution.issuerMatches(kw, a.bank, a.name),
          )
          .toList();
      if (byBank.length == 1) return byBank.first.id;
    }

    // Check credit cards
    final cards = await CreditRepo().getAll();
    if (parsed.last4 != null) {
      final byLast4 = cards.where((c) => c.last4 == parsed.last4).toList();
      if (byLast4.isNotEmpty) {
        if (parsed.bankName != null) {
          final matching = byLast4.where((c) => BalanceAttribution.issuerMatches(parsed.bankName!, c.bank, c.name)).firstOrNull;
          if (matching != null) return matching.id;
        } else {
          return byLast4.first.id;
        }
      }
    }
    if (parsed.bankName != null) {
      final kw = parsed.bankName!.toLowerCase();
      final byBank = cards
          .where(
            (c) =>
                c.bank.toLowerCase().contains(kw) ||
                c.name.toLowerCase().contains(kw) ||
                BalanceAttribution.issuerMatches(kw, c.bank, c.name),
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

bool _isAutoResolving = false;

/// Auto-resolves verified review queue items (e.g. Amazon Pay wallet,
/// credit card repayments with known liabilities, and dismisses failed payments).
Future<void> autoResolvePendingReviewQueue() async {
  if (_isAutoResolving) return;
  _isAutoResolving = true;
  try {
    final reviewRepo = ReviewRepo();
    final pending = await reviewRepo.getPending();
    if (pending.isEmpty) return;

    final accountRepo = AccountRepo();
    final creditRepo = CreditRepo();
    final txRepo = TransactionRepo();
    final fSvc = FinancialTransactionService();

    bool anyResolved = false;

    for (final item in pending) {
      var currentItem = item;
      var parsed = item.parsed;
      final raw = item.rawSource.isNotEmpty ? item.rawSource : parsed.rawText;

      // Re-extract merchant if previously extracted as 'Dispute' or null/noisy
      final merchantLower = parsed.merchant?.toLowerCase() ?? '';
      if (merchantLower == 'dispute' ||
          merchantLower.isEmpty ||
          merchantLower == 'info' ||
          merchantLower == 'click') {
        final reParsed = TransactionTextParser.parse(raw);
        if (reParsed.merchant != null &&
            reParsed.merchant!.toLowerCase() != 'dispute') {
          parsed = parsed.copyWith(
            merchant: reParsed.merchant,
            merchantSource: reParsed.merchantSource,
          );
          currentItem = item.copyWith(parsed: parsed);
        }
      }

      final lower = '$raw ${parsed.merchant ?? ''}'.toLowerCase();

      // 1. Spurious non-transactional items (pension/PRAN/APY, balance items, etc.)
      if (lower.contains('pran') ||
          lower.contains('atal pension') ||
          (lower.contains('contribution of') && lower.contains('pran')) ||
          item.id.startsWith('rev_bal_') ||
          parsed.source == 'sms_balance' ||
          parsed.method == 'balance') {
        await reviewRepo.reject(item.id);
        anyResolved = true;
        continue;
      }

      // 2. Drop failed payments / could not process
      if (TransactionTextParser.isFailedPayment(raw) ||
          lower.contains('could not process') ||
          lower.contains('could not be processed') ||
          lower.contains('failed to process') ||
          lower.contains('failed') ||
          lower.contains('declined') ||
          lower.contains('unsuccessful')) {
        await reviewRepo.reject(item.id);
        anyResolved = true;
        continue;
      }

      // 3. Auto-resolve Apay / Amazon Pay / Digital Wallets
      if (lower.contains('apay') || lower.contains('amazon pay')) {
        final accounts = await accountRepo.getAll();
        BankAccount? apay = accounts
            .where((a) =>
                a.accountType == 'wallet' &&
                (a.name.toLowerCase().contains('amazon') ||
                    a.name.toLowerCase().contains('apay')))
            .firstOrNull;
        if (apay == null) {
          final newId = await accountRepo.insertAccount(
            BankAccount(
              name: 'Amazon Pay Wallet',
              bank: 'Amazon Pay',
              accountType: 'wallet',
              balance: 0,
            ),
          );
          apay = await accountRepo.getById(newId);
        }
        if (apay != null) {
          await approveReviewItem(
            item: item,
            accountId: apay.id,
            financialService: fSvc,
            reviewRepo: reviewRepo,
          );
          anyResolved = true;
          continue;
        }
      }

      // 4. Auto-resolve Credit Card Repayments (both confirmation receipts & bank debits)
      final isCcPay = parsed.source == 'credit_card_payment' ||
          parsed.merchantSource == 'card_payment_receipt' ||
          (lower.contains('payment of') && (lower.contains('card') || lower.contains('received on your'))) ||
          lower.contains('credited to your card') ||
          lower.contains('received towards your') ||
          lower.contains('towards your credit card') ||
          lower.contains('towards your hdfc') ||
          lower.contains('towards your sbi') ||
          lower.contains('payment for your edge csb') ||
          lower.contains('via upi to jupiter') ||
          lower.contains('against your onecard') ||
          lower.contains('payment against your') ||
          lower.contains('to onecard') ||
          (lower.contains('onecard') && (lower.contains('payment') || lower.contains('received')));

      if (isCcPay) {
        final cards = await creditRepo.getAll();
        CreditCard? matchedCard;
        final effectiveLast4 = SmsImportService.extractCardLast4(raw) ??
            parsed.last4 ??
            RegExp(r'(?:card|ending|xx|x)\s*(\d{4,5})\b', caseSensitive: false)
                .firstMatch(raw)
                ?.group(1);
        if (effectiveLast4 != null && effectiveLast4.isNotEmpty) {
          matchedCard = cards.where((c) => c.last4 == effectiveLast4).firstOrNull;
        }
        if (matchedCard == null && lower.contains('onecard')) {
          matchedCard = cards.where((c) =>
              c.name.toLowerCase().contains('onecard') ||
              c.bank.toLowerCase().contains('onecard') ||
              c.bank.toLowerCase().contains('bobcard') ||
              c.bank.toLowerCase().contains('bob')).firstOrNull;
        }
        if (matchedCard == null) {
          for (final c in cards) {
            if (BalanceAttribution.issuerMatches(lower, c.bank, c.name)) {
              matchedCard = c;
              break;
            }
          }
        }

        if (matchedCard != null) {
          final targetCard = matchedCard;
          // Check if an existing credit_payment already exists for this amount and card
          final candidateDebits = await txRepo.findByAmountAndDateRange(
            amount: parsed.amount,
            from: parsed.date.subtract(const Duration(hours: 48)),
            to: parsed.date.add(const Duration(hours: 48)),
          );
          final existingDebit = candidateDebits.where((tx) =>
              tx.type == 'credit_payment' &&
              (tx.relatedEntityId == targetCard.id ||
                  tx.notes.contains(targetCard.last4) ||
                  tx.notes.toLowerCase().contains(targetCard.bank.toLowerCase()))).firstOrNull;

          if (existingDebit != null) {
            // Merged as duplicate
            await reviewRepo.approve(item.id);
            anyResolved = true;
            continue;
          }

          String? payingBankId;
          final payingLast4 = SmsImportService.extractBankAccountLast4(raw) ??
              RegExp(
                r'(?:from\s+a\/c|from\s+account|a\/c|ac)\s*[:\-]?\s*(?:[xX*]*(\d{3,6}))\b',
                caseSensitive: false,
              ).firstMatch(raw)?.group(1);
          final accounts = await accountRepo.getAll();
          if (payingLast4 != null && payingLast4.isNotEmpty) {
            payingBankId = accounts.where((a) => a.isAsset && a.last4 != null && a.last4!.contains(payingLast4)).firstOrNull?.id;
          }
          if (payingBankId == null) {
            final assetBanks = accounts
                .where((a) => a.isAsset && a.accountType != 'wallet')
                .toList();
            if (assetBanks.length == 1) {
              payingBankId = assetBanks.first.id;
            }
          }

          await approveReviewItem(
            item: item,
            accountId: payingBankId,
            typeOverride: 'credit_payment',
            financialService: fSvc,
            reviewRepo: reviewRepo,
          );
          anyResolved = true;
          continue;
        }
      }

      // 4.5. Auto-resolve Edge CSB Bank RuPay Credit Card purchases
      if (lower.contains('edge csb') || lower.contains('csb bank rupay credit card') || lower.contains('csb bank')) {
        final cards = await creditRepo.getAll();
        final csbCard = cards.where((c) =>
            c.name.toLowerCase().contains('csb') ||
            c.bank.toLowerCase().contains('csb')).firstOrNull;
        if (csbCard != null) {
          await approveReviewItem(
            item: item,
            accountId: csbCard.id,
            typeOverride: 'credit_card_purchase',
            financialService: fSvc,
            reviewRepo: reviewRepo,
          );
          anyResolved = true;
          continue;
        }
      }

      // 5. Auto-resolve Jupiter Account (Pots) / Jupiter Bank debits
      if (lower.contains('jupiter account') || lower.contains('jupiter')) {
        final accounts = await accountRepo.getAll();
        final jupiterAcc = accounts.where((a) =>
            a.name.toLowerCase().contains('jupiter') ||
            a.bank.toLowerCase().contains('jupiter') ||
            (a.last4 != null && a.last4!.contains('8434'))).firstOrNull;
        if (jupiterAcc != null) {
          await approveReviewItem(
            item: item,
            accountId: jupiterAcc.id,
            financialService: fSvc,
            reviewRepo: reviewRepo,
          );
          anyResolved = true;
          continue;
        }
      }

      // 4.8. Auto-resolve inter-account transfers (IMPS / NEFT / UPI between user's own bank accounts)
      if (parsed.refId != null && parsed.refId!.isNotEmpty) {
        final matchingTx = await txRepo.findByAmountAndDateRange(
          amount: parsed.amount,
          from: parsed.date.subtract(const Duration(hours: 48)),
          to: parsed.date.add(const Duration(hours: 48)),
        );
        final pairedLeg = matchingTx.where((tx) =>
          tx.externalRef == parsed.refId ||
          tx.notes.contains(parsed.refId!) ||
          (tx.rawPayload != null && tx.rawPayload!.contains(parsed.refId!))
        ).firstOrNull;

        if (pairedLeg != null && pairedLeg.accountId != null) {
          final accounts = await accountRepo.getAll();
          final currentAcc = accounts.where((a) =>
            a.last4 != null && (
              a.last4 == parsed.last4 ||
              (parsed.bankName != null && BalanceAttribution.issuerMatches(parsed.bankName!, a.bank, a.name))
            )
          ).firstOrNull;

          if (currentAcc != null && currentAcc.id != pairedLeg.accountId) {
            await approveReviewItem(
              item: item,
              accountId: currentAcc.id,
              typeOverride: 'transfer',
              financialService: fSvc,
              reviewRepo: reviewRepo,
            );
            anyResolved = true;
            continue;
          }
        }
      }

      // 5. Auto-resolve bank debit if last4 matches an existing bank account
      final bankLast4 = parsed.last4 ??
          RegExp(r'(?:a\/c|ac|acc|ending|xx|x)\s*(\d{4})\b', caseSensitive: false)
              .firstMatch(raw)
              ?.group(1);
      if (bankLast4 != null && bankLast4.isNotEmpty) {
        final accounts = await accountRepo.getAll();
        final match = accounts.where((a) => a.last4 == bankLast4).firstOrNull;
        if (match != null) {
          await approveReviewItem(
            item: item,
            accountId: match.id,
            financialService: fSvc,
            reviewRepo: reviewRepo,
          );
          anyResolved = true;
          continue;
        }
      }

      // 6. Auto-resolve Credit Card Purchases (BOBCARD OneCard 2510, HDFC 6366, Jupiter Edge CSB, etc.)
      final isCardSpend = parsed.method == 'card' ||
          parsed.source == 'credit_card_purchase' ||
          lower.contains('credit card') ||
          lower.contains('crd card') ||
          lower.contains('one credit card') ||
          lower.contains('hdfc bank card') ||
          lower.contains('spent on hdfc') ||
          lower.contains('spent at') ||
          lower.contains('spent on') ||
          lower.contains('charged to') ||
          lower.contains('used on your');

      if (isCardSpend && !isCcPay) {
        final cards = await creditRepo.getAll();
        CreditCard? matchedCard;
        final cardLast4 = SmsImportService.extractCardLast4(raw) ??
            parsed.last4 ??
            RegExp(r'(?:card|ending|xx|x)\s*(\d{4,5})\b', caseSensitive: false)
                .firstMatch(raw)
                ?.group(1);

        if (cardLast4 != null && cardLast4.isNotEmpty) {
          matchedCard = cards.where((c) => c.last4 == cardLast4).firstOrNull;
          if (matchedCard == null) {
            String? effectiveIssuer;
            if (lower.contains('hdfc')) {
              effectiveIssuer = 'HDFC Bank';
            } else if (lower.contains('bobcard') || lower.contains('onecard') || lower.contains('one credit card')) {
              effectiveIssuer = 'BOBCARD';
            } else if (lower.contains('sbi')) {
              effectiveIssuer = 'SBI Card';
            } else if (lower.contains('icici')) {
              effectiveIssuer = 'ICICI Bank';
            } else if (lower.contains('axis')) {
              effectiveIssuer = 'Axis Bank';
            } else if (lower.contains('csb') || lower.contains('jupiter')) {
              effectiveIssuer = 'CSB Bank';
            } else if (parsed.bankName != null && parsed.bankName!.isNotEmpty) {
              effectiveIssuer = parsed.bankName;
            }

            if (effectiveIssuer != null) {
              final newCard = CreditCard(
                name: '$effectiveIssuer Credit Card (..$cardLast4)',
                bank: effectiveIssuer,
                last4: cardLast4,
                limitAmount: 0.0,
                usedAmount: 0.0,
              );
              final newId = await creditRepo.insert(newCard);
              matchedCard = await creditRepo.getCard(newId);
            }
          }
        } else {
          for (final c in cards) {
            if (BalanceAttribution.issuerMatches(lower, c.bank, c.name)) {
              matchedCard = c;
              break;
            }
          }
        }

        if (matchedCard != null) {
          await approveReviewItem(
            item: currentItem,
            accountId: matchedCard.id,
            typeOverride: 'credit_card_purchase',
            financialService: fSvc,
            reviewRepo: reviewRepo,
          );
          anyResolved = true;
          continue;
        }
      }
    }

    if (anyResolved) {
      DataChangeBus.instance.notify();
    }
  } catch (e) {
    debugPrint('[ReviewProviders] Error in autoResolvePendingReviewQueue: $e');
  } finally {
    _isAutoResolving = false;
  }
}

/// Pending review items.
final reviewQueueProvider = FutureProvider<List<ReviewItem>>((ref) async {
  await autoResolvePendingReviewQueue();
  final items = await ref.watch(reviewRepoProvider).getPending();
  debugPrint('📋 Review queue: ${items.length} pending');
  return items;
});

/// Count of pending reviews (for badges).
final reviewQueueCountProvider = FutureProvider<int>((ref) async {
  await autoResolvePendingReviewQueue();
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
    currency: parsed.currency,
    userId: 'offline_user',
    type: type,
    categoryId: effectiveCategoryId,
    accountId: effectiveAccountId,
    relatedEntityId: relatedEntityId,
    date: parsed.date,
    notes: notes,
    source: isCcPayment ? 'credit_card_payment' : 'review',
    externalRef: externalRef,
    rawPayload: parsed.rawText,
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
