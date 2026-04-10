import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../categories/providers/category_providers.dart';
import '../dashboard/insights_providers.dart';
import '../transactions/providers/transaction_providers.dart';
import 'smart_budget_engine.dart';

/// Auto-generated smart budgets based on spending history.
final smartBudgetProvider = FutureProvider<List<SmartBudget>>((ref) async {
  final txns = await ref.watch(transactionsProvider.future);
  final stats = await ref.watch(currentMonthStatsProvider.future);
  final categories = await ref.watch(categoriesProvider.future);

  return SmartBudgetEngine().generate(
    transactions: txns,
    monthlyIncome: stats?.income ?? 0,
    categories: categories,
  );
});

/// Categories that are over budget.
final overBudgetProvider = FutureProvider<List<SmartBudget>>((ref) async {
  final budgets = await ref.watch(smartBudgetProvider.future);
  return budgets.where((b) => b.isOverBudget).toList();
});
