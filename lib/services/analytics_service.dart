import 'package:flutter/foundation.dart' show debugPrint;
import '../models/analytics_bundle.dart';
import '../models/analytics_summary.dart';
import '../models/category.dart';

/// Centralized service for processing raw financial data into actionable metrics.
/// Optimized for batch processing to minimize redundant calculations during UI updates.
class AnalyticsService {
  
  /// Computes a full summary from the provided data bundle.
  AnalyticsSummary computeSummary(AnalyticsBundle bundle) {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1);
    final startOfPrevMonth = DateTime(now.year, now.month - 1, 1);
    final endOfPrevMonth = DateTime(now.year, now.month, 0, 23, 59, 59);

    // 1. Calculate Monthly Metrics
    double monthlyIncome = 0;
    double monthlyExpense = 0;
    double previousMonthExpense = 0;
    final Map<String, double> categorySpending = {};

    // Use calendar month consistently (not rolling 30 days)
    for (final txn in bundle.transactions) {
      // Current month: from 1st of this month to now
      final inCurrentMonth = !txn.date.isBefore(startOfMonth) && !txn.date.isAfter(now);
      if (inCurrentMonth) {
        if (txn.type == 'income') {
          monthlyIncome += txn.amount;
        } else if (txn.type == 'expense') {
          monthlyExpense += txn.amount;
          final catId = txn.categoryId ?? 'other';
          categorySpending[catId] = (categorySpending[catId] ?? 0.0) + txn.amount;
        }
      }
      // Previous month: inclusive upper bound (don't miss last second)
      else if (!txn.date.isBefore(startOfPrevMonth) && !txn.date.isAfter(endOfPrevMonth)) {
        if (txn.type == 'expense') {
          previousMonthExpense += txn.amount;
        }
      }
    }

    // 2. Net Worth Calculation (Same as before)
    double assets = 0;
    double liabilities = 0;

    for (final account in bundle.accounts) {
      if (account.isAsset) {
        assets += account.balance;
      } else {
        liabilities += account.balance.abs(); // standardize with account_list_screen
      }
    }

    for (final loan in bundle.loans) {
      liabilities += (loan.total - loan.paidAmount);
    }

    for (final card in bundle.cards) {
      liabilities += card.usedAmount;
    }

    // 3. Budget Progress
    final catMap = {for (final c in bundle.categories) c.id: c};
    final budgetProgress = bundle.budgets.map((b) {
      final cat =
          catMap[b.categoryId] ??
          Category(
            id: '?',
            name: 'Unknown',
            icon: 'help',
            color: '#888888',
            userId: '',
            type: 'expense',
          );
      return (
        budget: b,
        category: cat,
        spent: categorySpending[b.categoryId] ?? 0.0,
      );
    }).where((item) => item.category.id != '?').toList();

    debugPrint('\u{1F4CA} Analytics: ${bundle.transactions.length} txns, '
        'period=$startOfMonth..now, '
        'income=$monthlyIncome, expense=$monthlyExpense');

    return AnalyticsSummary(
      netWorth: assets - liabilities,
      monthlyIncome: monthlyIncome,
      monthlyExpense: monthlyExpense,
      previousMonthExpense: previousMonthExpense,
      categorySpending: categorySpending,
      budgetProgress: budgetProgress,
      recentTransactions: bundle.transactions.take(10).toList(),
      categoriesMap: catMap,
    );
  }
}
