import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../alerts/data/app_alert.dart';
import '../../alerts/providers/alert_providers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../models/transaction.dart' as spx;
import '../../../data/providers.dart';

/// Provides a summary of the user's finances for the home screen.
/// Mapped from the batched AnalyticsSummary for Phase 3 efficiency.
final homeSummaryProvider = Provider<DashboardSummaryData>((ref) {
  final summary = ref.watch(analyticsSummaryProvider);

  return DashboardSummaryData(
    income: summary.monthlyIncome,
    expense: summary.monthlyExpense,
    // Balance = income minus expense for this period (not net worth)
    balance: summary.monthlyIncome - summary.monthlyExpense,
    currentMonthExpense: summary.monthlyExpense,
    previousMonthExpense: summary.previousMonthExpense,
  );
});

/// Provides the last 10 transactions for the home screen preview.
/// Uses the precomputed recentTransactions from AnalyticsSummary.
final homeTransactionsProvider = Provider<List<spx.Transaction>>((ref) {
  return ref.watch(
    analyticsSummaryProvider.select((s) => s.recentTransactions),
  );
});

/// Provides active alerts for the home strip with actions.
class HomeAlertsNotifier extends AsyncNotifier<List<AppAlert>> {
  @override
  FutureOr<List<AppAlert>> build() {
    return ref.watch(activeAlertsSnapshotProvider.future);
  }

  Future<void> markDone(String id) async {
    await ref.read(alertServiceProvider).markDone(id);
    ref.invalidate(activeAlertsSnapshotProvider);
  }

  Future<void> snooze(String id) async {
    await ref.read(alertServiceProvider).snooze(id, const Duration(hours: 1));
    ref.invalidate(activeAlertsSnapshotProvider);
  }
}

final homeAlertsProvider =
    AsyncNotifierProvider<HomeAlertsNotifier, List<AppAlert>>(
      HomeAlertsNotifier.new,
    );
