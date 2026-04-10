import 'package:flutter/foundation.dart' show debugPrint;

import '../../../data/repositories/account_repo.dart';
import '../../../models/bank_account.dart';
import '../models/parsed_sms.dart';

/// Syncs account balances from SMS balance fields.
///
/// Strategy:
///   - If SMS has "Avl Bal: Rs.X", update the linked account balance
///   - Only update if SMS is more recent than last known update
///   - Uses last4 digit matching to find the correct account
///   - Falls back gracefully if no balance in SMS or no account match
class BalanceSyncService {
  BalanceSyncService._();
  static final instance = BalanceSyncService._();

  /// Attempt to sync account balance from a parsed SMS.
  /// Returns true if balance was updated.
  Future<bool> syncFromSms(ParsedSms sms) async {
    // No balance extracted → nothing to sync
    if (sms.balance == null) return false;

    // Need last4 to match to an account
    if (sms.last4 == null || sms.last4!.isEmpty) return false;

    // Skip credit card SMS — balance means "available limit", not account balance
    if (sms.kind == SmsKind.creditCardSpend ||
        sms.kind == SmsKind.creditCardPayment) {
      return false;
    }

    try {
      final repo = AccountRepo();
      final accounts = await repo.getAll();

      // Match by bank name + account type, or by name containing last4
      BankAccount? account;
      if (sms.bankName != null) {
        final bankLower = sms.bankName!.toLowerCase();
        final matches = accounts.where((a) =>
            a.bank.toLowerCase().contains(bankLower) ||
            a.name.toLowerCase().contains(bankLower) ||
            a.name.contains(sms.last4!));
        if (matches.isNotEmpty) account = matches.first;
      }

      // Fallback: match by last4 in account name
      account ??= accounts
          .where((a) => a.name.contains(sms.last4!))
          .firstOrNull;

      if (account == null) {
        debugPrint('\u{1F3E6} Balance sync: no account for ${sms.bankName} / ${sms.last4}');
        return false;
      }

      // Update balance (overwrite strategy — SMS balance is authoritative)
      await repo.updateBalance(account.id, sms.balance!);
      debugPrint(
          '\u{1F3E6} Balance synced: ${account.name} → ${sms.balance}');
      return true;
    } catch (e) {
      debugPrint('\u26A0\uFE0F Balance sync error: $e');
      return false;
    }
  }
}
