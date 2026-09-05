import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/account_repo.dart';
import '../data/repositories/credit_repo.dart';
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
class LiveSmsService {
  LiveSmsService._();
  static final LiveSmsService instance = LiveSmsService._();

  static const MethodChannel _channel = MethodChannel('spendx/sms_live');
  static const String _enabledKey = 'live_sms_detection';
  static const String _caughtUpKey = 'live_sms_caught_up';

  bool _initialized = false;
  final List<String> _liveBuffer = [];
  Timer? _flushTimer;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSmsReceived') {
        final bodies = (call.arguments as List?)?.cast<String>() ?? const <String>[];
        // Batch bursts of incoming SMS into a single notification.
        _liveBuffer.addAll(bodies);
        _flushTimer?.cancel();
        _flushTimer = Timer(const Duration(seconds: 3), () {
          unawaited(_flushLiveBuffer());
        });
      }
    });

    // Process anything captured while the app wasn't running.
    await drainPending();

    // Pull in previous bank transactions from the SMS inbox (once) so the
    // app catches up on history without a manual scan.
    unawaited(catchUpHistorical());
  }

  Future<void> _flushLiveBuffer() async {
    if (_liveBuffer.isEmpty) return;
    final batch = List.of(_liveBuffer);
    _liveBuffer.clear();
    var added = 0;
    String? balanceNote;
    for (final body in batch) {
      final outcome = await _processBody(body);
      if (outcome.added) added++;
      if (outcome.balanceNote != null) balanceNote = outcome.balanceNote;
    }
    if (added > 0) {
      await NotificationServiceV2().showNotification(
        title: 'Transaction detected',
        body: '$added transaction${added == 1 ? '' : 's'} detected — '
            'review to confirm or delete.',
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

  /// Scans the SMS inbox for past bank transactions and adds the ones not
  /// already in the app to the Review Queue. Runs once (guarded by a flag).
  Future<void> catchUpHistorical({int daysBack = 90}) async {
    if (!await enabled) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_caughtUpKey) ?? false) return;

    // Don't prompt at startup — only proceed if already granted.
    if (!await Permission.sms.status.isGranted) return;

    try {
      final bundle = await SmsImportService.instance.scan(
        options: SmsScanOptions(daysBack: daysBack),
      );
      var added = 0;
      for (final t in bundle.transactions) {
        if (await _alreadyInApp(t.parsed)) continue;
        await _addToReviewQueue(t.parsed);
        added++;
      }
      await prefs.setBool(_caughtUpKey, true);
      if (added > 0) {
        await NotificationServiceV2().showNotification(
          title: 'Past transactions imported',
          body: '$added past transaction${added == 1 ? '' : 's'} detected '
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
      for (final t in sameAmount) {
        if (t.notes.contains(parsed.merchant ?? '\u0000')) return true;
      }
      final pending = await ReviewRepo().getPending();
      for (final r in pending) {
        if ((r.parsed.amount - parsed.amount).abs() < 0.01 &&
            r.parsed.merchant == parsed.merchant &&
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
      String? balanceNote;
      for (final body in pending) {
        final outcome = await _processBody(body);
        if (outcome.added) added++;
        if (outcome.balanceNote != null) balanceNote = outcome.balanceNote;
      }
      await _channel.invokeMethod('clearPendingSms');
      if (added > 0) {
        await NotificationServiceV2().showNotification(
          title: 'Transaction detected',
          body: '$added transaction${added == 1 ? '' : 's'} detected — '
              'review to confirm or delete.',
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
    } catch (_) {
      // Channel may be unavailable (e.g. tests / desktop) — ignore.
    }
  }

  /// Processes a single SMS body. Returns what it did so the caller can
/// consolidate the notification.
Future<({bool added, String? balanceNote})> _processBody(String body) async {
  if (body.trim().isEmpty) return (added: false, balanceNote: null);

  final result = SmsImportService.instance.classifyMessage(body, '');

  if (result.transaction != null) {
    // Auto-detect: add to the Review Queue with the parsed info. The user
    // approves it (becomes an expense/income + updates the account balance)
    // or rejects it to delete the error.
    await _addToReviewQueue(result.transaction!);
    return (added: true, balanceNote: null);
  }

  if (result.balance != null) {
    final hit = result.balance!;
    final applied = await _applyBalance(hit);
    final kind = hit.kind == BalanceKind.bank
        ? 'Bank balance'
        : hit.kind == BalanceKind.creditCard
        ? 'Credit card outstanding'
        : 'Loan balance';
    final note = applied
        ? '$kind set to ${AppFormat.currency(hit.amount)}'
        : '$kind ${AppFormat.currency(hit.amount)} detected';
    return (added: false, balanceNote: note);
  }

  return (added: false, balanceNote: null);
}

Future<void> _addToReviewQueue(ParsedTransaction parsed) async {
    try {
      final item = ReviewItem(
        rawSource: 'live_sms',
        parsed: parsed,
        confidence: parsed.confidence,
      );
      await ReviewRepo().insert(item);
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Auto-applies a detected balance to the best-matching account/card.
  /// Returns true when applied.
  Future<bool> _applyBalance(BalanceHit hit) async {
    try {
      if (hit.kind == BalanceKind.bank) {
        final accounts = await AccountRepo().getAll();
        final match = _matchAccount(accounts, hit);
        if (match == null) return false;
        await AccountRepo().updateBalance(match.id, hit.amount);
        return true;
      }
      if (hit.kind == BalanceKind.creditCard) {
        final cards = await CreditRepo().getAll();
        final match = hit.last4 == null
            ? null
            : cards.where((c) => c.last4 == hit.last4).firstOrNull;
        if (match == null) return false;
        await CreditRepo().update(match.copyWith(usedAmount: hit.amount));
        return true;
      }
      // Loan balances are handled in the Loans screen.
      return false;
    } catch (_) {
      return false;
    }
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
}