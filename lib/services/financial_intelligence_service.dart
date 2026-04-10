import 'package:flutter/foundation.dart' show debugPrint;
import '../models/bank_balance_snapshot.dart';
import '../data/repositories/bank_balance_snapshot_repo.dart';
import '../services/ledger_service.dart';

class FinancialIntelligenceService {
  FinancialIntelligenceService._();
  static final FinancialIntelligenceService instance =
      FinancialIntelligenceService._();

  final LedgerService _ledger = LedgerService.instance;
  final BankBalanceSnapshotRepo _snapshots = BankBalanceSnapshotRepo();

  /// Takes a snapshot of the account balance if one doesn't already exist for today.
  /// Strictly throttled to 1 snapshot per account per day.
  Future<void> takeSnapshot(String accountId, {DateTime? timestamp}) async {
    try {
      final now = timestamp ?? DateTime.now();
      final normalized = BankBalanceSnapshot.normalize(now);

      // 1. Check if snapshot already exists for this account on this date
      final exists = await _snapshots.existsForDate(
        accountId,
        normalized.millisecondsSinceEpoch,
      );
      if (exists) return; // Throttled

      // 2. Fetch current balance from Ledger (Source of Truth)
      final balance = await _ledger.getAccountBalance(accountId);

      // 3. Insert new snapshot
      final snapshot = BankBalanceSnapshot(
        accountId: accountId,
        balance: balance,
        timestamp: normalized,
      );

      await _snapshots.insert(snapshot);

      // 4. Cleanup old snapshots occasionally
      await cleanupOldSnapshots();
    } catch (e) {
      debugPrint('[INTEL] takeSnapshot error: $e');
    }
  }

  /// Prunes snapshots older than 365 days to prevent DB bloat.
  Future<void> cleanupOldSnapshots() async {
    try {
      final threshold = DateTime.now()
          .subtract(const Duration(days: 365))
          .millisecondsSinceEpoch;
      await _snapshots.pruneBefore(threshold);
    } catch (e) {
      debugPrint('[INTEL] cleanupOldSnapshots error: $e');
    }
  }

  /// Finds the highest balance recorded for an account.
  Future<Map<String, dynamic>?> getHighestBalance(String accountId) async {
    try {
      return await _snapshots.getHighestBalance(accountId);
    } catch (e) {
      debugPrint('[INTEL] getHighestBalance error: $e');
      return null;
    }
  }

  /// Groups snapshots by month for trend analysis.
  Future<List<Map<String, dynamic>>> getMonthlyTrends(String accountId) async {
    try {
      final snapshots = await _snapshots.getSnapshotsForAccount(accountId);
      if (snapshots.isEmpty) return [];

      Map<String, List<double>> monthlyGroups = {};
      for (var s in snapshots) {
        final date = DateTime.fromMillisecondsSinceEpoch(
          s.timestamp.millisecondsSinceEpoch,
        );
        final key = '${date.year}-${date.month.toString().padLeft(2, '0')}';
        monthlyGroups.putIfAbsent(key, () => []).add(s.balance);
      }

      List<Map<String, dynamic>> trends = [];
      monthlyGroups.forEach((month, balances) {
        final opening = balances.first;
        final closing = balances.last;
        trends.add({
          'month': month,
          'opening': opening,
          'closing': closing,
          'change': closing - opening,
        });
      });

      return trends;
    } catch (e) {
      debugPrint('[INTEL] getMonthlyTrends error: $e');
      return [];
    }
  }
}
