import 'package:flutter/foundation.dart' show debugPrint;

import '../data/repositories/net_worth_repo.dart';
import '../services/net_worth_service.dart';
import '../data/repositories/account_repo.dart';
import '../data/repositories/loan_repo.dart';

/// Triggers a daily net worth snapshot on app open.
/// Safe to call multiple times — deduplicates per day.
class SnapshotTrigger {
  static final SnapshotTrigger instance = SnapshotTrigger._();
  SnapshotTrigger._();

  bool _triggered = false;

  /// Call on app startup (e.g., from SplashScreen or main).
  /// Takes a snapshot of current net worth if one doesn't exist for today.
  Future<void> onAppOpen() async {
    if (_triggered) return;
    _triggered = true;

    try {
      final service = NetWorthService(AccountRepo(), LoanRepo());
      final result = await service.calculate();
      final repo = NetWorthRepo();
      final isNew = await repo.insertDailySnapshot(
        netWorth: result.netWorth,
        assets: result.assets,
        liabilities: result.liabilities,
      );
      if (isNew) {
        debugPrint('📸 Daily net worth snapshot captured: ${result.netWorth}');
      } else {
        debugPrint('📸 Daily net worth snapshot updated: ${result.netWorth}');
      }
    } catch (e) {
      debugPrint('📸 Snapshot trigger failed: $e');
      // Never block app startup
    }
  }

  /// Reset for testing or force re-snapshot.
  void reset() => _triggered = false;
}
