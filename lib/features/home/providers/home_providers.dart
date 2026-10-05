import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../alerts/data/app_alert.dart';
import '../../alerts/providers/alert_providers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../models/transaction.dart' as spx;
import '../../../data/providers.dart';
import '../../../domain/finance/finance.dart';

/// Provides a summary of the user's finances for the home screen.
/// Derived strictly from canonical transactionsProvider (economic events & postings).
final homeSummaryProvider = Provider<DashboardSummaryData>((ref) {
  final allTxns = ref.watch(transactionsProvider).valueOrNull ?? const [];
  final now = DateTime.now();
  final currentMonthStart = DateTime(now.year, now.month, 1);
  final previousMonthStart = DateTime(now.year, now.month - 1, 1);
  final previousMonthEnd = DateTime(now.year, now.month, 0, 23, 59, 59);

  double income = 0, expense = 0;
  double prevMonthExp = 0;

  for (final t in allTxns) {
    if (!t.date.isBefore(currentMonthStart) && !t.date.isAfter(now)) {
      if (t.type == 'income') {
        income += t.amount;
      } else if (t.type == 'expense') {
        expense += t.amount;
      }
    } else if (!t.date.isBefore(previousMonthStart) &&
        !t.date.isAfter(previousMonthEnd)) {
      if (t.type == 'expense') {
        prevMonthExp += t.amount;
      }
    }
  }

  return DashboardSummaryData(
    income: income,
    expense: expense,
    // Balance = income minus expense for this period (not net worth)
    balance: income - expense,
    currentMonthExpense: expense,
    previousMonthExpense: prevMonthExp,
  );
});

/// Provides the last 10 transactions for the home screen preview.
/// Uses the canonical transactions from transactionsProvider.
final homeTransactionsProvider = Provider<List<spx.Transaction>>((ref) {
  final txns = ref.watch(transactionsProvider).valueOrNull ?? const [];
  return txns.take(10).toList();
});

/// Re-exports canonical Safe-to-Spend calculation for home screen and widgets.
final homeSafeToSpendProvider =
    Provider<AsyncValue<SafeToSpendCalculation>>((ref) {
  return ref.watch(safeToSpendProvider);
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
