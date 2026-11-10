import 'package:flutter/foundation.dart' show debugPrint;
import '../models/analytics_bundle.dart';
import '../models/analytics_summary.dart';
import '../models/category.dart';
import '../models/transaction.dart';

/// Centralized service for processing raw financial data into actionable metrics.
/// Optimized for batch processing to minimize redundant calculations during UI updates.
class AnalyticsService {
  
  /// Computes a full summary from the provided data bundle.
  AnalyticsSummary computeSummary(AnalyticsBundle bundle) {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1);
    final startOfPrevMonth = DateTime(now.year, now.month - 1, 1);

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
        } else if (txn.type == 'expense' || txn.type == 'credit_card_purchase') {
          monthlyExpense += txn.amount;
          final catId = txn.categoryId ?? 'other';
          categorySpending[catId] = (categorySpending[catId] ?? 0.0) + txn.amount;
        } else if (txn.type == 'refund') {
          monthlyExpense -= txn.amount;
          final catId = txn.categoryId ?? 'other';
          categorySpending[catId] = (categorySpending[catId] ?? 0.0) - txn.amount;
        } else if (txn.type == 'loan_repayment' || txn.type == 'loan_payment') {
          final interest = _extractInterest(txn);
          if (interest > 0) {
            monthlyExpense += interest;
            final catId = txn.categoryId ?? 'interest';
            categorySpending[catId] = (categorySpending[catId] ?? 0.0) + interest;
          }
        }
      }
      // Previous month: half-open [startOfPrevMonth, startOfMonth)
      else if (!txn.date.isBefore(startOfPrevMonth) && txn.date.isBefore(startOfMonth)) {
        if (txn.type == 'expense' || txn.type == 'credit_card_purchase') {
          previousMonthExpense += txn.amount;
        } else if (txn.type == 'refund') {
          previousMonthExpense -= txn.amount;
        } else if (txn.type == 'loan_repayment' || txn.type == 'loan_payment') {
          previousMonthExpense += _extractInterest(txn);
        }
      }
    }

    // 2. Net Worth Calculation (Canonical double-entry truth preferred)
    final double netWorth;
    if (bundle.canonicalNetWorth != null) {
      netWorth = bundle.canonicalNetWorth!;
    } else {
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
      netWorth = assets - liabilities;
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
      netWorth: netWorth,
      monthlyIncome: monthlyIncome,
      monthlyExpense: monthlyExpense,
      previousMonthExpense: previousMonthExpense,
      categorySpending: categorySpending,
      budgetProgress: budgetProgress,
      recentTransactions: bundle.transactions.take(10).toList(),
      categoriesMap: catMap,
    );
  }

  static double _extractInterest(Transaction t) {
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
}
