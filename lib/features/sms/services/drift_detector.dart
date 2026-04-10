import 'package:flutter/foundation.dart' show debugPrint;

import '../../../data/repositories/account_repo.dart';
import '../models/parsed_sms.dart';

/// Detects balance drift between expected (from transactions) and actual (from SMS).
///
/// Use case: if account balance from SMS doesn't match sum of tracked transactions,
/// something is wrong (missed transaction, wrong amount, or untracked manual spending).
///
/// Drift = |SMS balance - (last known balance ± transaction amount)|
/// If drift > threshold → alert user for manual reconciliation.
class DriftDetector {
  DriftDetector._();
  static final instance = DriftDetector._();

  static const _driftThresholdPercent = 5.0; // 5% tolerance
  static const _driftThresholdAbsolute = 100.0; // Rs.100 minimum to care

  /// Check for balance drift after a transaction import.
  /// Returns a DriftResult if drift is detected, null if OK.
  Future<DriftResult?> checkDrift({
    required ParsedSms sms,
    required String? accountId,
  }) async {
    // No balance in SMS or no account → can't check
    if (sms.balance == null || accountId == null) return null;

    try {
      final accRepo = AccountRepo();
      final accounts = await accRepo.getAll();
      final account = accounts.where((a) => a.id == accountId).firstOrNull;
      if (account == null) return null;

      // Expected balance after this transaction:
      // If debit: previous balance - amount = sms balance
      // If credit: previous balance + amount = sms balance
      final txnDelta = sms.isCredit ? sms.amount : -sms.amount;
      final expectedBalance = account.balance + txnDelta;
      final actualBalance = sms.balance!;
      final drift = (expectedBalance - actualBalance).abs();

      // Check if drift exceeds thresholds
      final percentDrift = actualBalance != 0
          ? (drift / actualBalance.abs()) * 100
          : drift > 0 ? 100.0 : 0.0;

      if (drift > _driftThresholdAbsolute &&
          percentDrift > _driftThresholdPercent) {
        debugPrint('\u26A0\uFE0F Balance drift detected: '
            'expected=$expectedBalance, actual=$actualBalance, drift=$drift');
        return DriftResult(
          accountId: accountId,
          accountName: account.name,
          expectedBalance: expectedBalance,
          actualBalance: actualBalance,
          driftAmount: drift,
          driftPercent: percentDrift,
        );
      }

      return null;
    } catch (e) {
      debugPrint('\u26A0\uFE0F Drift check error: $e');
      return null;
    }
  }
}

class DriftResult {
  final String accountId;
  final String accountName;
  final double expectedBalance;
  final double actualBalance;
  final double driftAmount;
  final double driftPercent;

  const DriftResult({
    required this.accountId,
    required this.accountName,
    required this.expectedBalance,
    required this.actualBalance,
    required this.driftAmount,
    required this.driftPercent,
  });

  String get message =>
      '$accountName: expected ${expectedBalance.toStringAsFixed(2)}, '
      'SMS says ${actualBalance.toStringAsFixed(2)} '
      '(drift: ${driftAmount.toStringAsFixed(2)})';
}
