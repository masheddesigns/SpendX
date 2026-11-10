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

  double income = 0, expense = 0;
  double prevMonthExp = 0;

  for (final t in allTxns) {
    if (!t.date.isBefore(currentMonthStart) && !t.date.isAfter(now)) {
      if (t.type == 'income') {
        income += t.amount;
      } else if (t.type == 'expense' || t.type == 'credit_card_purchase') {
        expense += t.amount;
      } else if (t.type == 'refund') {
        expense -= t.amount;
      } else if (t.type == 'loan_repayment' || t.type == 'loan_payment') {
        expense += _extractInterest(t);
      }
    } else if (!t.date.isBefore(previousMonthStart) &&
        t.date.isBefore(currentMonthStart)) {
      if (t.type == 'expense' || t.type == 'credit_card_purchase') {
        prevMonthExp += t.amount;
      } else if (t.type == 'refund') {
        prevMonthExp -= t.amount;
      } else if (t.type == 'loan_repayment' || t.type == 'loan_payment') {
        prevMonthExp += _extractInterest(t);
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

double _extractInterest(spx.Transaction t) {
  if (t.interestAmount != null) {
    return t.interestAmount!;
  }
  if (t.type == 'loan_repayment' || t.type == 'loan_payment') {
    final match = RegExp(r'Interest:\s*([\d\.]+)').firstMatch(t.notes);
    if (match != null) {
      return double.tryParse(match.group(1)!) ?? 0.0;
    }
  }
  return 0.0;
}

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
