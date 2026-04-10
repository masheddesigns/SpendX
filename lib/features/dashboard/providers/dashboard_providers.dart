import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/transaction.dart' as spx;
import '../../../models/category.dart';
import '../../../services/credit_intelligence_service.dart';
import '../../../data/providers.dart';

final dashboardPeriodProvider = StateProvider<String>((ref) => '1m');

final dashboardCategoryMapProvider = Provider<Map<String, Category>>((ref) {
  final categories = ref.watch(categoriesProvider).value ?? [];
  return {for (var c in categories) c.id: c};
});

final dashboardAccountsProvider = Provider<List<dynamic>>((ref) {
  return ref.watch(accountsProvider).value ?? [];
});

class DashboardSummaryData {
  final double income;
  final double expense;
  final double balance;
  final double currentMonthExpense;
  final double previousMonthExpense;

  DashboardSummaryData({
    required this.income,
    required this.expense,
    required this.balance,
    required this.currentMonthExpense,
    required this.previousMonthExpense,
  });
}

final dashboardSummaryProvider = Provider<DashboardSummaryData>((ref) {
  final period = ref.watch(dashboardPeriodProvider);
  final allTxns = ref.watch(transactionsProvider).value ?? [];
  final now = DateTime.now();

  DateTime? startDate;
  if (period == '1m') {
    startDate = DateTime(now.year, now.month - 1, now.day);
  } else if (period == '3m') {
    startDate = DateTime(now.year, now.month - 3, now.day);
  } else if (period == '6m') {
    startDate = DateTime(now.year, now.month - 6, now.day);
  } else if (period == '1y') {
    startDate = DateTime(now.year - 1, now.month, now.day);
  }

  final currentMonthStart = DateTime(now.year, now.month, 1);
  final previousMonthStart = DateTime(now.year, now.month - 1, 1);
  final previousMonthEnd = DateTime(now.year, now.month, 0, 23, 59, 59);

  double income = 0, expense = 0;
  double curMonthExp = 0, prevMonthExp = 0;

  for (final t in allTxns) {
    if (startDate == null || !t.date.isBefore(startDate)) {
      if (t.type == 'income') {
        income += t.amount;
      } else if (t.type == 'expense') {
        expense += t.amount;
      }
    }

    if (!t.date.isBefore(currentMonthStart) && t.type == 'expense') {
      curMonthExp += t.amount;
    }

    if (!t.date.isBefore(previousMonthStart) &&
        t.date.isBefore(previousMonthEnd) &&
        t.type == 'expense') {
      prevMonthExp += t.amount;
    }
  }

  return DashboardSummaryData(
    income: income,
    expense: expense,
    balance: income - expense,
    currentMonthExpense: curMonthExp,
    previousMonthExpense: prevMonthExp,
  );
});

final dashboardTransactionsProvider = Provider<List<spx.Transaction>>((ref) {
  final period = ref.watch(dashboardPeriodProvider);
  final allTxns = ref.watch(transactionsProvider).value ?? [];
  final now = DateTime.now();

  DateTime? startDate;
  if (period == '1m') {
    startDate = DateTime(now.year, now.month - 1, now.day);
  } else if (period == '3m') {
    startDate = DateTime(now.year, now.month - 3, now.day);
  } else if (period == '6m') {
    startDate = DateTime(now.year, now.month - 6, now.day);
  } else if (period == '1y') {
    startDate = DateTime(now.year - 1, now.month, now.day);
  }

  return allTxns.where((t) {
    if (startDate == null) return true;
    return !t.date.isBefore(startDate);
  }).toList()..sort((a, b) => b.date.compareTo(a.date));
});

final dashboardIntelProvider = FutureProvider<CreditIntelligenceData?>((
  ref,
) async {
  final cards = ref.watch(cardsProvider).value ?? const [];
  if (cards.isEmpty) return null;
  return await CreditIntelligenceService.instance.getCardIntelligence(
    cards.first,
  );
});
