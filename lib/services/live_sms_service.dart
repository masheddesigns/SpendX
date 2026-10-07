import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/utils/category_resolver.dart';
import '../core/utils/merchant_extractor.dart';
import '../data/core/database_lifecycle_coordinator.dart';
import '../data/repositories/account_repo.dart';
import '../data/repositories/canonical/canonical_event_repository.dart';
import '../data/repositories/canonical/canonical_transaction_adapter.dart';
import '../data/repositories/credit_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../domain/finance/finance.dart';
import '../features/merchant_rules/data/merchant_rule_repo.dart';
import '../models/bank_account.dart';
import '../models/credit_card.dart';
import '../models/review_item.dart';
import '../models/transaction.dart';
import '../utils/app_format.dart';
import '../utils/text_formatter.dart';
import 'financial_transaction_service.dart';
import 'gamification_service.dart';
import 'notification_service_v2.dart';
import 'smart_category_classifier.dart';
import 'sms_import_service.dart';

/// Live SMS detection: receives incoming bank/card/wallet SMS (via a native receiver),
/// automatically classifies the transaction and instrument (credit card, bank, or wallet),
/// assigns category via merchant memory or static rules (defaulting to Miscellaneous),
/// learns merchant associations, updates balances, and notifies the user.
class LiveSmsService with WidgetsBindingObserver {
  LiveSmsService._();
  static final LiveSmsService instance = LiveSmsService._();

  static const MethodChannel _channel = MethodChannel('spendx/sms_live');
  static const String _enabledKey = 'live_sms_detection';

  bool _initialized = false;
  final List<({String sender, String body})> _liveBuffer = [];
  Timer? _flushTimer;

  int get bufferCountForTesting => _liveBuffer.length;
  void addLiveBufferForTesting(String sender, String body) {
    _liveBuffer.add((sender: sender, body: body));
  }
  Future<void> flushLiveBufferForTesting() => _flushLiveBuffer();
  void clearLiveBufferForTesting() => _liveBuffer.clear();

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSmsReceived') {
        final args = call.arguments as List?;
        String sender = '';
        String body = '';
        if (args != null && args.length >= 2) {
          sender = args[0]?.toString() ?? '';
          body = args[1]?.toString() ?? '';
        } else if (args != null && args.isNotEmpty) {
          body = args.cast<String>().join('\n');
        }
        if (body.isNotEmpty) {
          _liveBuffer.add((sender: sender, body: body));
          _flushTimer?.cancel();
          _flushTimer = Timer(const Duration(seconds: 3), () {
            unawaited(_flushLiveBuffer());
          });
        }
      }
    });

    WidgetsBinding.instance.addObserver(this);

    // Drain any pending messages received while the app was closed.
    await drainPending();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(drainPending());
  }

  Future<void> _flushLiveBuffer() async {
    if (_liveBuffer.isEmpty) return;
    await DatabaseLifecycleCoordinator.instance.waitUntilWritable();
    final batch = List.of(_liveBuffer);
    _liveBuffer.clear();
    var added = 0;
    String? balanceNote;
    Transaction? singleTransaction;
    for (final entry in batch) {
      final outcome = await _processBody(entry.body, sender: entry.sender);
      if (outcome.added) {
        added++;
        singleTransaction = outcome.transaction;
      }
      if (outcome.balanceNote != null) balanceNote = outcome.balanceNote;
    }
    if (added == 1 && singleTransaction != null) {
      final dir = singleTransaction.type == 'income' ? 'Received' : 'Spent';
      final merchant = singleTransaction.notes.isNotEmpty ? ' at ${singleTransaction.notes}' : '';
      await NotificationServiceV2().showNotification(
        title: '$dir ${AppFormat.currency(singleTransaction.amount)}',
        body: '$dir ${AppFormat.currency(singleTransaction.amount)}$merchant — tap to view or edit in Activity.',
        category: 'generalUpdates',
        payload: jsonEncode({'source_type': 'activity'}),
      );
    } else if (added > 1) {
      await NotificationServiceV2().showNotification(
        title: '$added transactions recorded',
        body: '$added new transactions added from SMS — tap to view in Activity.',
        category: 'generalUpdates',
        payload: jsonEncode({'source_type': 'activity'}),
      );
    } else if (balanceNote != null) {
      await NotificationServiceV2().showNotification(
        title: 'Balance updated',
        body: '$balanceNote — tap to view Accounts.',
        category: 'generalUpdates',
        payload: jsonEncode({'source_type': 'balances'}),
      );
    }
  }

  Future<bool> get enabled async =>
      (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? true;

  Future<void> setEnabled(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(_enabledKey, value);
  }

  /// Best-effort request for the RECEIVE_SMS runtime permission (Android).
  Future<void> requestReceivePermission() async {
    try {
      await _channel.invokeMethod('requestReceiveSmsPermission');
    } catch (_) {
      // Ignore on platforms without the channel.
    }
  }

  Future<void> drainPending() async {
    if (!await enabled) return;
    await DatabaseLifecycleCoordinator.instance.waitUntilWritable();
    try {
      final pending = await _channel.invokeListMethod<dynamic>('getPendingSms');
      if (pending == null || pending.isEmpty) return;
      var added = 0;
      Transaction? singleTransaction;
      for (final item in pending) {
        String sender = '';
        String body = '';
        if (item is Map) {
          sender = item['sender']?.toString() ?? '';
          body = item['body']?.toString() ?? '';
        } else if (item is String) {
          if (item.contains('\u0002')) {
            final parts = item.split('\u0002');
            sender = parts[0];
            body = parts.sublist(1).join('\u0002');
          } else {
            body = item;
          }
        }
        if (body.trim().isEmpty) continue;

        final outcome = await _processBody(body, sender: sender, skipBalance: false);
        if (outcome.added) {
          added++;
          singleTransaction = outcome.transaction;
        }
      }
      await _channel.invokeMethod('clearPendingSms');
      if (added == 1 && singleTransaction != null) {
        final dir = singleTransaction.type == 'income' ? 'Received' : 'Spent';
        final merchant = singleTransaction.notes.isNotEmpty ? ' at ${singleTransaction.notes}' : '';
        await NotificationServiceV2().showNotification(
          title: '$dir ${AppFormat.currency(singleTransaction.amount)}',
          body: '$dir ${AppFormat.currency(singleTransaction.amount)}$merchant — tap to view or edit in Activity.',
          category: 'generalUpdates',
          payload: jsonEncode({'source_type': 'activity'}),
        );
      } else if (added > 1) {
        await NotificationServiceV2().showNotification(
          title: '$added transactions recorded',
          body: '$added new transactions added from SMS — tap to view in Activity.',
          category: 'generalUpdates',
          payload: jsonEncode({'source_type': 'activity'}),
        );
      }
    } catch (_) {
      // Channel may be unavailable (e.g. tests / desktop) — ignore.
    }
  }

  /// Resolves the instrument (credit card, bank, or digital wallet) for a transaction.
  Future<({String? accountId, String source, String instrumentType})> _classifyAndResolveAccount({
    required ParsedTransaction parsed,
    required String sender,
    required String body,
    BalanceHit? balanceHit,
  }) async {
    final lowerSender = sender.toLowerCase();
    final lowerBody = body.toLowerCase();

    // 1. Check for Credit Card
    final cards = await CreditRepo().getAll();
    final matchedCardByLast4 = (parsed.last4 != null && parsed.last4!.isNotEmpty)
        ? cards.where((c) => c.last4 == parsed.last4).firstOrNull
        : null;

    final isCcSignal = matchedCardByLast4 != null ||
        balanceHit?.kind == BalanceKind.creditCard ||
        lowerSender.contains('crd') ||
        lowerSender.contains('card') ||
        lowerSender.contains('cc') ||
        lowerSender.contains('onecrd') ||
        lowerSender.contains('bobcrd') ||
        lowerSender.contains('sbicrd') ||
        lowerSender.contains('jtedge') ||
        lowerBody.contains('credit card') ||
        lowerBody.contains('card ending') ||
        lowerBody.contains('credit card ending');

    if (isCcSignal) {
      CreditCard? matchedCard = matchedCardByLast4;
      if (matchedCard == null && parsed.last4 != null && parsed.last4!.isNotEmpty) {
        matchedCard = cards.where((c) => c.last4 == parsed.last4).firstOrNull;
      }
      if (matchedCard == null && parsed.bankName != null) {
        final kw = parsed.bankName!.toLowerCase();
        matchedCard = cards.where((c) =>
          c.name.toLowerCase().contains(kw) ||
          c.bank.toLowerCase().contains(kw),
        ).firstOrNull;
      }
      if (matchedCard != null) {
        return (
          accountId: matchedCard.id,
          source: 'credit_card_purchase',
          instrumentType: 'credit_card',
        );
      }
      // If recognized as credit card but not yet in CreditRepo, auto-create
      if (parsed.bankName != null || parsed.last4 != null) {
        final cardName = '${parsed.bankName ?? 'Credit'} Card';
        final newCard = CreditCard(
          name: cardName,
          bank: parsed.bankName ?? 'Credit Card',
          last4: parsed.last4 ?? '',
          limitAmount: 0,
          usedAmount: 0,
        );
        final newId = await CreditRepo().insert(newCard);
        return (
          accountId: newId,
          source: 'credit_card_purchase',
          instrumentType: 'credit_card',
        );
      }
    }

    // 2. Check for Digital Wallet
    final isWalletSignal = balanceHit?.kind == BalanceKind.wallet ||
        lowerSender.contains('qcamzn') ||
        lowerSender.contains('juspay') ||
        lowerSender.contains('ipaytm') ||
        lowerSender.contains('irsmsa') ||
        lowerBody.contains('wallet');

    if (isWalletSignal) {
      final accounts = await AccountRepo().getAll();
      final walletAcc = accounts.where((a) =>
        a.accountType == 'wallet' ||
        a.name.toLowerCase().contains('wallet') ||
        a.bank.toLowerCase().contains('wallet') ||
        a.name.toLowerCase().contains('paytm') ||
        a.name.toLowerCase().contains('amazon pay'),
      ).firstOrNull;
      if (walletAcc != null) {
        return (
          accountId: walletAcc.id,
          source: 'sms',
          instrumentType: 'wallet',
        );
      }
      // Auto-create wallet account
      final walletName = lowerSender.contains('qcamzn')
          ? 'Amazon Pay Wallet'
          : (lowerSender.contains('ipaytm') ? 'Paytm Wallet' : 'Digital Wallet');
      final newWallet = BankAccount(
        name: walletName,
        bank: walletName,
        accountType: 'wallet',
        balance: 0,
      );
      final newId = await AccountRepo().insertAccount(newWallet);
      return (
        accountId: newId,
        source: 'sms',
        instrumentType: 'wallet',
      );
    }

    // 3. Bank Account matching
    final accounts = await AccountRepo().getAll();
    BankAccount? matchedBank;
    if (parsed.last4 != null && parsed.last4!.isNotEmpty) {
      matchedBank = accounts.where((a) => a.last4 == parsed.last4).firstOrNull;
    }
    if (matchedBank == null && parsed.bankName != null) {
      final kw = parsed.bankName!.toLowerCase();
      final matching = accounts.where((a) =>
        a.bank.toLowerCase().contains(kw) ||
        a.name.toLowerCase().contains(kw),
      ).toList();
      if (matching.isNotEmpty) matchedBank = matching.first;
    }

    if (matchedBank != null) {
      return (
        accountId: matchedBank.id,
        source: 'sms',
        instrumentType: matchedBank.accountType == 'wallet' ? 'wallet' : 'bank',
      );
    }

    // If explicit bank name or last4 was detected, auto-create bank account
    if (parsed.bankName != null || (parsed.last4 != null && parsed.last4!.isNotEmpty)) {
      final bankTitle = parsed.bankName ?? 'Bank';
      final accName = '$bankTitle Account${parsed.last4 != null && parsed.last4!.isNotEmpty ? ' (..${parsed.last4})' : ''}';
      final newAcc = BankAccount(
        name: accName,
        bank: bankTitle,
        last4: parsed.last4 ?? '',
        accountType: 'savings',
        balance: 0,
      );
      final newId = await AccountRepo().insertAccount(newAcc);
      return (
        accountId: newId,
        source: 'sms',
        instrumentType: 'bank',
      );
    }

    // 4. Safe Unknown: When instrument cannot be safely determined, do NOT arbitrarily corrupt an account
    return (
      accountId: null,
      source: 'sms',
      instrumentType: 'unknown',
    );
  }

  /// Processes a single SMS body.
  /// Automatically creates canonical transaction, applies balance update,
  /// learns merchant category associations, and returns the result.
  Future<
    ({
      bool added,
      String? balanceNote,
      Transaction? transaction,
    })
  >
  _processBody(String body, {String sender = '', bool skipBalance = false}) async {
    if (body.trim().isEmpty) {
      return (added: false, balanceNote: null, transaction: null);
    }

    final result = SmsImportService.instance.classifyMessage(body, sender);
    Transaction? createdTx;
    String? balanceNote;

    // 1. Transaction processing
    if (result.transaction != null) {
      final parsed = result.transaction!;
      if (!await _alreadyInApp(parsed)) {
        final type = parsed.isCredit ? 'income' : 'expense';

        // Resolve Category: Merchant memory -> static rules -> 'Miscellaneous'
        final resolution = await resolveCategoryForText(
          rawText: parsed.rawText,
          merchant: parsed.merchant,
          type: type,
        );

        // Classify Instrument & Resolve Account (Credit Card, Bank, or Wallet)
        final instrument = await _classifyAndResolveAccount(
          parsed: parsed,
          sender: sender,
          body: body,
          balanceHit: result.balance,
        );

        final rawMerchantOrNote = parsed.merchant ??
            (parsed.rawText.length > 80 ? parsed.rawText.substring(0, 80) : parsed.rawText);
        final notes = TextFormatter.normalizeName(rawMerchantOrNote);

        final isCreditCardPurchase = instrument.source == 'credit_card_purchase' && type == 'expense';

        final externalRef = parsed.refId ??
            'live_sms|${parsed.date.millisecondsSinceEpoch}|${parsed.amount.toStringAsFixed(2)}';

        final tx = Transaction(
          amount: parsed.amount,
          userId: 'offline_user',
          type: type,
          categoryId: resolution.id,
          accountId: instrument.accountId,
          date: parsed.date,
          notes: notes,
          source: isCreditCardPurchase ? 'credit_card_purchase' : 'sms',
          externalRef: externalRef,
        );

        // Create transaction in canonical double-entry ledger
        await FinancialTransactionService().createTransaction(tx);
        createdTx = tx;

        // Gamification XP
        try {
          await GamificationService.instance.addXP(10, isTransaction: true);
        } catch (_) {}

        // Learn Merchant Rule (notes/keyword -> category & account)
        if (resolution.id != null && notes.isNotEmpty) {
          try {
            final keyword = MerchantExtractor.extract(notes);
            if (keyword.length >= 3) {
              await MerchantRuleRepo().upsert(
                keyword,
                resolution.id!,
                accountId: instrument.accountId,
              );
            }
          } catch (_) {}
        }

        // Learn Merchant Memory for repeat transactions
        if (parsed.merchant != null && resolution.name != null) {
          try {
            await SmartCategoryClassifier.instance.learn(
              rawText: parsed.rawText,
              merchant: parsed.merchant,
              category: resolution.name!,
            );
          } catch (_) {}
        }
      }
    }

    // 2. Balance update from message itself
    if (result.balance != null && !skipBalance) {
      final hit = result.balance!;
      final applied = await _applyBalance(hit);
      if (applied) {
        final kind = hit.kind == BalanceKind.bank
            ? 'Bank balance'
            : hit.kind == BalanceKind.creditCard
            ? 'Credit card outstanding'
            : hit.kind == BalanceKind.wallet
            ? 'Wallet balance'
            : 'Loan balance';
        balanceNote = '$kind set to ${AppFormat.currency(hit.amount)}';
      }
    }

    return (
      added: createdTx != null,
      balanceNote: balanceNote,
      transaction: createdTx,
    );
  }

  /// Records a detected balance statement and updates the canonical account/card balance.
  Future<bool> _applyBalance(BalanceHit hit) async {
    try {
      final fingerprint = CanonicalTransactionAdapter.computeSha256(hit.body);
      final ev = Evidence(
        id: const Uuid().v4(),
        sourceType: 'sms',
        sourceIdentifier: hit.sender.isNotEmpty ? hit.sender : (hit.bankKeyword ?? 'sms'),
        sourceTimestamp: DateTime.now().toUtc(),
        bodyFingerprint: fingerprint,
        extractedAmount: Money.fromRupees(hit.amount),
        accountContext: hit.last4 != null ? 'XX${hit.last4}' : hit.bankKeyword,
        rawPayloadEncrypted: hit.body,
        retentionExpiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
        isPayloadPurged: false,
        economicEventId: null,
        createdAt: DateTime.now().toUtc(),
      );
      await CanonicalEventRepository().insertEvidence(ev);

      // Reconcile and update account balance in canonical repositories
      if (hit.kind == BalanceKind.creditCard) {
        final cards = await CreditRepo().getAll();
        CreditCard? card;
        if (hit.last4 != null && hit.last4!.isNotEmpty) {
          card = cards.where((c) => c.last4 == hit.last4).firstOrNull;
        }
        if (card == null && hit.bankKeyword != null) {
          final kw = hit.bankKeyword!.toLowerCase();
          card = cards.where((c) =>
            c.name.toLowerCase().contains(kw) ||
            c.bank.toLowerCase().contains(kw),
          ).firstOrNull;
        }
        if (card != null) {
          await CreditRepo().updateBalance(card.id, hit.amount);
          return true;
        }
      } else {
        // Bank or Wallet
        final accounts = await AccountRepo().getAll();
        BankAccount? account;
        if (hit.last4 != null && hit.last4!.isNotEmpty) {
          account = accounts.where((a) => a.last4 == hit.last4).firstOrNull;
        }
        if (account == null && hit.kind == BalanceKind.wallet) {
          account = accounts.where((a) => a.accountType == 'wallet').firstOrNull;
        }
        if (account == null && hit.bankKeyword != null) {
          final kw = hit.bankKeyword!.toLowerCase();
          account = accounts.where((a) =>
            a.name.toLowerCase().contains(kw) ||
            a.bank.toLowerCase().contains(kw),
          ).firstOrNull;
        }
        if (account != null) {
          await AccountRepo().updateBalance(account.id, hit.amount);
          return true;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when this parsed transaction already exists in the app — avoids duplicates.
  Future<bool> _alreadyInApp(ParsedTransaction parsed) async {
    try {
      final eventRepo = CanonicalEventRepository();
      if (parsed.refId != null && parsed.refId!.trim().isNotEmpty) {
        final existingRef =
            await eventRepo.getEvidenceByExternalReference(parsed.refId!.trim());
        if (existingRef != null) return true;
      }
      final fingerprint =
          CanonicalTransactionAdapter.computeSha256(parsed.rawText);
      final existingHash =
          await eventRepo.getEvidenceByFingerprint(fingerprint);
      if (existingHash != null) return true;

      final sameAmount = await TransactionRepo().findByAmountAndDateRange(
        amount: parsed.amount,
        from: parsed.date.subtract(const Duration(minutes: 30)),
        to: parsed.date.add(const Duration(minutes: 30)),
      );
      final normMerchant = _normalizeMerchantForDedup(parsed.merchant);
      for (final t in sameAmount) {
        if (_merchantsMatch(normMerchant, t.notes)) return true;
      }
    } catch (_) {}
    return false;
  }



  /// Normalizes a merchant name for dedup comparison: lowercases, strips
  /// common suffixes (online, store, etc.), collapses whitespace.
  static String _normalizeMerchantForDedup(String? merchant) {
    if (merchant == null || merchant.trim().isEmpty) return '';
    var m = merchant.toLowerCase().trim();
    // Strip common suffixes that vary between bank/UPI SMS
    m = m.replaceAll(
      RegExp(r'\b(?:online|store|india|pvt\.?|ltd\.?|limited|llp)\b', caseSensitive: false),
      '',
    );
    // Collapse whitespace
    m = m.replaceAll(RegExp(r'\s+'), ' ').trim();
    return m;
  }

  /// Fuzzy merchant match for dedup: checks if the normalized merchant
  /// names share a common prefix of ≥4 chars, or if one contains the other.
  /// Catches "ZOMATO" vs "Zomato Online", "5 KADEEJA" vs "Kadeeja", etc.
  static bool _merchantsMatch(String normA, String? b) {
    if (normA.isEmpty || b == null || b.isEmpty) return false;
    final normB = _normalizeMerchantForDedup(b);
    if (normA == normB) return true;
    // One contains the other (e.g., "zomato" in "zomato online")
    if (normA.contains(normB) || normB.contains(normA)) return true;
    // Share a common prefix of ≥5 chars (e.g., "zomato" vs "zomatoo")
    final minLen = normA.length < normB.length ? normA.length : normB.length;
    if (minLen >= 5) {
      int shared = 0;
      for (var i = 0; i < minLen; i++) {
        if (normA[i] == normB[i]) {
          shared++;
        } else {
          break;
        }
      }
      if (shared >= 5) return true;
    }
    return false;
  }
}