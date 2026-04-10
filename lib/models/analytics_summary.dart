import 'category.dart';
import 'budget.dart';
import 'transaction.dart';

/// A DTO representing the precomputed metrics derived from an AnalyticsBundle.
/// Avoids UI recomputation during re-renders.
class AnalyticsSummary {
  final double netWorth;
  final double monthlyIncome;
  final double monthlyExpense;
  final double previousMonthExpense;
  final Map<String, double> categorySpending;
  final List<({Budget budget, Category category, double spent})> budgetProgress;
  final List<Transaction> recentTransactions;
  final Map<String, Category> categoriesMap;

  const AnalyticsSummary({
    required this.netWorth,
    required this.monthlyIncome,
    required this.monthlyExpense,
    required this.previousMonthExpense,
    required this.categorySpending,
    required this.budgetProgress,
    required this.recentTransactions,
    required this.categoriesMap,
  });

  factory AnalyticsSummary.empty() => const AnalyticsSummary(
        netWorth: 0,
        monthlyIncome: 0,
        monthlyExpense: 0,
        previousMonthExpense: 0,
        categorySpending: {},
        budgetProgress: [],
        recentTransactions: [],
        categoriesMap: {},
      );
}
