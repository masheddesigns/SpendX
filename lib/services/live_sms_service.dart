import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/account_repo.dart';
import '../data/repositories/credit_repo.dart';
import '../data/repositories/loan_repo.dart';
import '../models/credit_card.dart';
import '../models/loan.dart';
import '../data/repositories/review_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../models/bank_account.dart';
import '../models/review_item.dart';
import '../utils/app_format.dart';
import 'notification_service_v2.dart';
import 'sms_import_service.dart';

/// Live SMS detection: receives incoming bank SMS (via a native receiver),
/// classifies each message, and surfaces it as a notification so the user can
/// import the transaction or confirm a balance update. Also drains messages
/// captured while the app was closed.
class LiveSmsService with WidgetsBindingObserver {
  LiveSmsService._();
  static final LiveSmsService instance = LiveSmsService._();

  static const MethodChannel _channel = MethodChannel('spendx/sms_live');
  static const String _enabledKey = 'live_sms_detection';
  static const String _lastCatchUpKey = 'live_sms_last_catchup';
  static const Duration _resumeCatchUpCooldown = Duration(minutes: 5);

  bool _initialized = false;
  final List<({String sender, String body})> _liveBuffer = [];
  Timer? _flushTimer;
  DateTime? _lastResumeCatchUpAt;

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
          // Fallback: old format (bodies only)
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

    // Process anything captured while the app wasn't running.
    await drainPending();

    // Pull in previous bank transactions from the SMS inbox (once) so the
    // app catches up on history without a manual scan.
    unawaited(catchUpHistorical());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Re-run the catch-up when returning to the app so SMS that arrived
    // while it was backgrounded are picked up (throttled).
    final last = _lastResumeCatchUpAt;
    if (last != null &&
        DateTime.now().difference(last) < _resumeCatchUpCooldown) {
      return;
    }
    _lastResumeCatchUpAt = DateTime.now();
    unawaited(drainPending());
    unawaited(catchUpHistorical());
  }

  Future<void> _flushLiveBuffer() async {
    if (_liveBuffer.isEmpty) return;
    final batch = List.of(_liveBuffer);
    _liveBuffer.clear();
    var added = 0;
    String? balanceNote;
    String? singleReviewId;
    ParsedTransaction? singleTransaction;
    for (final entry in batch) {
      final outcome = await _processBody(entry.body, sender: entry.sender);
      if (outcome.added) {
        added++;
        singleReviewId = outcome.reviewId;
        singleTransaction = outcome.transaction;
      }
      if (outcome.balanceNote != null) balanceNote = outcome.balanceNote;
    }
    if (added == 1 && singleReviewId != null && singleTransaction != null) {
      // Single detection → ask Expense vs Income right in the notification.
      await _showChoice(singleReviewId, singleTransaction);
    } else if (added > 1) {
      await NotificationServiceV2().showNotification(
        title: 'Transactions detected',
        body: '$added transactions detected — review to confirm or delete.',
        category: 'generalUpdates',
        payload: jsonEncode({'source_type': 'review'}),
      );
    } else if (balanceNote != null) {
      await NotificationServiceV2().showNotification(
        title: 'Balance update',
        body: '$balanceNote — tap to review.',
        category: 'generalUpdates',
        payload: jsonEncode({'source_type': 'balances'}),
      );
    }
  }

  /// Asks "Expense or Income?" with action buttons for one detected
  /// transaction. Tapping a button saves it; tapping the body opens review.
  Future<void> _showChoice(String reviewId, ParsedTransaction t) async {
    final direction = t.isCredit ? 'Received' : 'Spent';
    await NotificationServiceV2().showTransactionChoice(
      title: 'Add as Expense or Income?',
      body: '$direction ${AppFormat.currency(t.amount)}'
          '${t.merchant != null ? ' at ${t.merchant}' : ''} — choose below.',
      payload: jsonEncode({'source_type': 'live_choice', 'review_id': reviewId}),
    );
  }

  /// Incremental catch-up: on every launch, scans the SMS inbox and adds bank
  /// transactions newer than the last catch-up (deduped against saved + pending
  /// items) to the Review Queue. This is what surfaces today's UPI messages
  /// automatically without a manual scan.
  Future<void> catchUpHistorical({int daysBack = 365}) async {
    if (!await enabled) return;

    // Don't prompt at startup — only proceed if already granted.
    if (!await Permission.sms.status.isGranted) return;

    final prefs = await SharedPreferences.getInstance();
    final lastCatchUpAt = prefs.getInt(_lastCatchUpKey);

    try {
      final bundle = await SmsImportService.instance.scan(
        options: SmsScanOptions(daysBack: daysBack),
      );
      final now = DateTime.now();
      var added = 0;
      for (final t in bundle.transactions) {
        // Skip anything that arrived before the previous catch-up.
        if (lastCatchUpAt != null &&
            t.parsed.date.isBefore(
              DateTime.fromMillisecondsSinceEpoch(lastCatchUpAt),
            )) {
          continue;
        }
        if (await _alreadyInApp(t.parsed)) continue;
        await _addToReviewQueue(t.parsed);
        added++;
      }

      // Apply latest balance from each account's SMS so the displayed
      // balance reflects the most recent bank statement.
      // scan() already deduplicates to keep only the latest per account.
      print('[LiveSms] catchUpHistorical: applying ${bundle.balances.length} deduped balance(s)');
      for (final hit in bundle.balances) {
        print('[LiveSms] _applyBalance: ${hit.kind.name} last4=${hit.last4} amount=${hit.amount}');
        await _applyBalance(hit);
      }

      // Auto-register detected credit cards and loans that don't exist yet.
      await _autoRegisterCards(bundle.cards);
      await _autoRegisterLoans(bundle.loans);

      await prefs.setInt(_lastCatchUpKey, now.millisecondsSinceEpoch);
      if (added > 0) {
        await NotificationServiceV2().showNotification(
          title: 'New transactions detected',
          body: '$added new transaction${added == 1 ? '' : 's'} detected '
              'from your SMS — review to confirm.',
          category: 'generalUpdates',
          payload: jsonEncode({'source_type': 'review'}),
        );
      }
    } catch (_) {
      // Non-fatal — the user can scan manually from SMS Import.
    }
  }

  /// True when this parsed transaction already exists in the app (as a saved
  /// transaction or a pending review item) — avoids duplicates.
  Future<bool> _alreadyInApp(ParsedTransaction parsed) async {
    try {
      final txRepo = TransactionRepo();
      if (parsed.refId != null && parsed.refId!.isNotEmpty) {
        if (await txRepo.existsByExternalRef(parsed.refId!)) return true;
      }
      final sameAmount = await txRepo.findByAmountAndDateRange(
        amount: parsed.amount,
        from: parsed.date.subtract(const Duration(minutes: 30)),
        to: parsed.date.add(const Duration(minutes: 30)),
      );
      final normMerchant = _normalizeMerchantForDedup(parsed.merchant);
      for (final t in sameAmount) {
        if (_merchantsMatch(normMerchant, t.notes)) return true;
      }
      final pending = await ReviewRepo().getPending();
      for (final r in pending) {
        if ((r.parsed.amount - parsed.amount).abs() < 0.01 &&
            _merchantsMatch(normMerchant, r.parsed.merchant) &&
            r.parsed.date.difference(parsed.date).inMinutes.abs() <= 60) {
          return true;
        }
      }
    } catch (_) {}
    return false;
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
    try {
      final pending = await _channel.invokeListMethod<String>('getPendingSms');
      if (pending == null || pending.isEmpty) return;
      var added = 0;
      String? singleReviewId;
      ParsedTransaction? singleTransaction;
      for (final body in pending) {
        // Skip balance-only messages here — catchUpHistorical() will apply
        // the correct latest balance per account from the full inbox scan.
        final outcome = await _processBody(body, skipBalance: true);
        if (outcome.added) {
          added++;
          singleReviewId = outcome.reviewId;
          singleTransaction = outcome.transaction;
        }
      }
      await _channel.invokeMethod('clearPendingSms');
      if (added == 1 && singleReviewId != null && singleTransaction != null) {
        await _showChoice(singleReviewId, singleTransaction);
      } else if (added > 1) {
        await NotificationServiceV2().showNotification(
          title: 'Transactions detected',
          body: '$added transactions detected — '
              'review to confirm or delete.',
          category: 'generalUpdates',
          payload: jsonEncode({'source_type': 'review'}),
        );
      }
    } catch (_) {
      // Channel may be unavailable (e.g. tests / desktop) — ignore.
    }
  }

  /// Processes a single SMS body. Returns what it did so the caller can
/// consolidate the notification.
  Future<
    ({
      bool added,
      String? balanceNote,
      String? reviewId,
      ParsedTransaction? transaction,
    })
  >
  _processBody(String body, {String sender = '', bool skipBalance = false}) async {
    if (body.trim().isEmpty) {
      return (added: false, balanceNote: null, reviewId: null, transaction: null);
    }

    final result = SmsImportService.instance.classifyMessage(body, sender);

    if (result.transaction != null) {
      // Auto-detect: add to the Review Queue with the parsed info. The user
      // approves it (becomes an expense/income + updates the account balance)
      // or rejects it to delete the error — or answers Expense/Income right
      // in the notification.
      final reviewId = await _addToReviewQueue(result.transaction!);
      return (
        added: reviewId != null,
        balanceNote: null,
        reviewId: reviewId,
        transaction: result.transaction,
      );
    }

  if (result.balance != null && !skipBalance) {
    final hit = result.balance!;
    final applied = await _applyBalance(hit);
    final kind = hit.kind == BalanceKind.bank
        ? 'Bank balance'
        : hit.kind == BalanceKind.creditCard
        ? 'Credit card outstanding'
        : hit.kind == BalanceKind.wallet
        ? 'Wallet balance'
        : 'Loan balance';
    final note = applied
        ? '$kind set to ${AppFormat.currency(hit.amount)}'
        : '$kind ${AppFormat.currency(hit.amount)} detected';
    return (
      added: false,
      balanceNote: note,
      reviewId: null,
      transaction: null,
    );
  }

  return (
    added: false,
    balanceNote: null,
    reviewId: null,
    transaction: null,
  );
}

/// Inserts a pending review item (skipping it when the same transaction is
/// already saved or pending). Returns its id, or null on failure/duplicate.
Future<String?> _addToReviewQueue(ParsedTransaction parsed) async {
    try {
      if (await _alreadyInApp(parsed)) return null;
      final item = ReviewItem(
        rawSource: 'live_sms',
        parsed: parsed,
        confidence: parsed.confidence,
      );
      await ReviewRepo().insert(item);
      return item.id;
    } catch (_) {
      // Non-fatal.
      return null;
    }
  }

  /// Auto-applies a detected balance to the best-matching account/card.
  /// Returns true when applied.
  Future<bool> _applyBalance(BalanceHit hit) async {
    try {
      if (hit.kind == BalanceKind.bank) {
        final accounts = await AccountRepo().getAll();
        final match = _matchAccount(accounts, hit);
        if (match == null) {
          print('[LiveSms] _applyBalance: no matching account for last4=${hit.last4} kw=${hit.bankKeyword}');
          return false;
        }
        print('[LiveSms] _applyBalance: updating account ${match.id} (${match.bank} ...${match.last4}) to ${hit.amount}');
        await AccountRepo().updateBalance(match.id, hit.amount);
        return true;
      }
      if (hit.kind == BalanceKind.creditCard) {
        final cards = await CreditRepo().getAll();
        // Match by last4 first, then fall back to bank keyword.
        CreditCard? match;
        if (hit.last4 != null && hit.last4!.isNotEmpty) {
          match = cards.where((c) => c.last4 == hit.last4).firstOrNull;
        }
        if (match == null && hit.bankKeyword != null) {
          final kw = hit.bankKeyword!.toLowerCase();
          final byBank = cards
              .where(
                (c) =>
                    c.bank.toLowerCase().contains(kw) ||
                    c.name.toLowerCase().contains(kw),
              )
              .toList();
          if (byBank.length == 1) match = byBank.first;
        }
        if (match == null) {
          print('[LiveSms] _applyBalance: no matching card for last4=${hit.last4} kw=${hit.bankKeyword}');
          return false;
        }
        print('[LiveSms] _applyBalance: updating card ${match.id} (${match.bank} ...${match.last4}) usedAmount to ${hit.amount}');
        await CreditRepo().update(match.copyWith(usedAmount: hit.amount));
        return true;
      }
      // Loan balances: match by bank name and show in notification.
      // The actual loan record is managed through the Loans screen.
      if (hit.kind == BalanceKind.loan) {
        final loans = await LoanRepo().getLoans();
        final kw = hit.bankKeyword?.toLowerCase();
        Loan? match;
        if (kw != null) {
          final byBank = loans
              .where(
                (l) =>
                    l.bank.toLowerCase().contains(kw) ||
                    l.name.toLowerCase().contains(kw),
              )
              .toList();
          if (byBank.length == 1) match = byBank.first;
        }
        if (match != null) {
          print('[LiveSms] _applyBalance: matched loan ${match.id} (${match.bank}) — outstanding ${hit.amount}');
        } else {
          print('[LiveSms] _applyBalance: no matching loan for kw=${hit.bankKeyword}');
        }
        // Return true so notification says "set to" instead of just "detected".
        return match != null;
      }
      // Digital wallet balances: detect and notify only (no DB to update).
      if (hit.kind == BalanceKind.wallet) {
        final displayName = hit.bankKeyword?.toUpperCase() ?? 'Wallet';
        print('[LiveSms] _applyBalance: wallet $displayName balance ${hit.amount}');
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Auto-registers detected credit cards that don't exist yet.
  Future<void> _autoRegisterCards(List<DetectedCard> cards) async {
    if (cards.isEmpty) return;
    try {
      final existing = await CreditRepo().getAll();
      for (final card in cards) {
        if (card.last4 == null || card.last4!.isEmpty) continue;
        final alreadyExists = existing.any((c) => c.last4 == card.last4);
        if (!alreadyExists) {
          print('[LiveSms] _autoRegisterCards: adding ${card.bank} ...${card.last4}');
          await CreditRepo().insert(
            CreditCard(
              name: '${card.bank} Card',
              bank: card.bank,
              last4: card.last4!,
              limitAmount: 0,
              usedAmount: card.outstanding,
            ),
          );
        }
      }
    } catch (_) {}
  }

  /// Auto-registers detected loans that don't exist yet.
  Future<void> _autoRegisterLoans(List<DetectedLoan> loans) async {
    if (loans.isEmpty) return;
    try {
      final existing = await LoanRepo().getLoans();
      for (final loan in loans) {
        final kw = loan.bank.toLowerCase();
        final alreadyExists = existing.any(
          (l) =>
              l.bank.toLowerCase().contains(kw) ||
              l.name.toLowerCase().contains(kw),
        );
        if (!alreadyExists) {
          print('[LiveSms] _autoRegisterLoans: adding ${loan.bank}');
          await LoanRepo().insertLoan(
            Loan(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: '${loan.bank} Loan',
              bank: loan.bank,
              total: loan.outstanding,
              interestRate: 0,
              tenureMonths: 0,
              monthlyInstallment: 0,
              startDate: DateTime.now(),
              paidAmount: 0,
              loanStatus: 'active',
              dueDay: 1,
            ),
          );
        }
      }
    } catch (_) {}
  }

  BankAccount? _matchAccount(List<BankAccount> accounts, BalanceHit hit) {
    if (hit.last4 != null) {
      final byLast4 = accounts.where((a) => a.last4 == hit.last4).firstOrNull;
      if (byLast4 != null) return byLast4;
    }
    final kw = hit.bankKeyword?.toLowerCase();
    if (kw != null) {
      final byBank = accounts
          .where(
            (a) =>
                a.bank.toLowerCase().contains(kw) ||
                a.name.toLowerCase().contains(kw),
          )
          .toList();
      if (byBank.length == 1) return byBank.first;
    }
    return null;
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