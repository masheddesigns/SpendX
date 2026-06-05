import 'package:flutter/foundation.dart' show debugPrint;

import '../data/repositories/transaction_repo.dart';

/// End-of-month financial forecast based on current spending velocity.
///
/// Deterministic, explainable, fast. No ML — just math.
class Forecast {
  final double projectedIncome;
  final double projectedExpense;
  final double projectedSavings;
  final Map<String, CategoryForecast> categoryForecasts;
  final double dailyBurnRate;
  final int daysElapsed;
  final int daysInMonth;
  final bool isOverspendRisk;
  final double overspendAmount;

  const Forecast({
    required this.projectedIncome,
    required this.projectedExpense,
    required this.projectedSavings,
    required this.categoryForecasts,
    required this.dailyBurnRate,
    required this.daysElapsed,
    required this.daysInMonth,
    required this.isOverspendRisk,
    required this.overspendAmount,
  });

  static const empty = Forecast(
    projectedIncome: 0, projectedExpense: 0, projectedSavings: 0,
    categoryForecasts: {}, dailyBurnRate: 0,
    daysElapsed: 0, daysInMonth: 30,
    isOverspendRisk: false, overspendAmount: 0,
  );
}

class CategoryForecast {
  final String categoryName;
  final double spentSoFar;
  final double projected;
  final double previousMonthTotal;
  final double driftPercent; // positive = spending more

  const CategoryForecast({
    required this.categoryName,
    required this.spentSoFar,
    required this.projected,
    required this.previousMonthTotal,
    required this.driftPercent,
  });

  bool get isTrendingUp => driftPercent > 15;
}

/// Forecast computation engine.
class ForecastEngine {
  ForecastEngine._();
  static final instance = ForecastEngine._();

  // Cache
  Forecast? _cache;
  DateTime? _cacheTime;

  void invalidateCache() {
    _cache = null;
    _cacheTime = null;
  }

  /// Compute end-of-month forecast from current data.
  Future<Forecast> compute() async {
    // Use 5-minute cache
    if (_cache != null && _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < const Duration(minutes: 5)) {
      return _cache!;
    }

    final repo = TransactionRepo();
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final daysElapsed = now.day.clamp(1, daysInMonth);

    // Previous month for comparison
    final startOfPrevMonth = DateTime(now.year, now.month - 1, 1);
    final endOfPrevMonth = DateTime(now.year, now.month, 0, 23, 59, 59);

    final allTxns = await repo.getAll();

    // Current month
    double monthIncome = 0;
    double monthExpense = 0;
    final catSpending = <String, double>{};

    // Previous month
    double prevExpense = 0;
    final prevCatSpending = <String, double>{};

    for (final t in allTxns) {
      // Current month
      if (!t.date.isBefore(startOfMonth) && !t.date.isAfter(now)) {
        if (t.type == 'income') {
          monthIncome += t.amount;
        } else if (t.type == 'expense') {
          monthExpense += t.amount;
          final cat = t.categoryId ?? 'other';
          catSpending[cat] = (catSpending[cat] ?? 0) + t.amount;
        }
      }
      // Previous month
      else if (!t.date.isBefore(startOfPrevMonth) &&
          !t.date.isAfter(endOfPrevMonth)) {
        if (t.type == 'expense') {
          prevExpense += t.amount;
          final cat = t.categoryId ?? 'other';
          prevCatSpending[cat] = (prevCatSpending[cat] ?? 0) + t.amount;
        }
      }
    }

    // Daily rates
    final dailyExpense = daysElapsed > 0 ? monthExpense / daysElapsed : 0.0;
    final dailyIncome = daysElapsed > 0 ? monthIncome / daysElapsed : 0.0;

    // Projections
    final projectedExpense = dailyExpense * daysInMonth;
    final projectedIncome = dailyIncome * daysInMonth;
    final projectedSavings = projectedIncome - projectedExpense;

    // Overspend risk — true if EITHER:
    //   (a) projected spending exceeds last month by >10%, OR
    //   (b) projected savings is negative (spending more than earning).
    // The second condition catches the "you're losing money but it's fine"
    // bug where prev-month was low so the 10% threshold never triggered.
    final exceedsPrevMonth =
        prevExpense > 0 && projectedExpense > prevExpense * 1.1;
    final negativeSavings = projectedSavings < 0;
    final isOverspendRisk = exceedsPrevMonth || negativeSavings;
    final overspendAmount = isOverspendRisk
        ? (negativeSavings
            ? projectedExpense - projectedIncome
            : projectedExpense - prevExpense)
        : 0.0;

    // Category forecasts with drift
    final categoryForecasts = <String, CategoryForecast>{};
    for (final entry in catSpending.entries) {
      final catProjected = (entry.value / daysElapsed) * daysInMonth;
      final prevTotal = prevCatSpending[entry.key] ?? 0;
      final drift = prevTotal > 0
          ? ((catProjected - prevTotal) / prevTotal) * 100
          : 0.0;

      categoryForecasts[entry.key] = CategoryForecast(
        categoryName: entry.key,
        spentSoFar: entry.value,
        projected: catProjected,
        previousMonthTotal: prevTotal,
        driftPercent: drift,
      );
    }

    final result = Forecast(
      projectedIncome: projectedIncome,
      projectedExpense: projectedExpense,
      projectedSavings: projectedSavings,
      categoryForecasts: categoryForecasts,
      dailyBurnRate: dailyExpense,
      daysElapsed: daysElapsed,
      daysInMonth: daysInMonth,
      isOverspendRisk: isOverspendRisk,
      overspendAmount: overspendAmount,
    );

    _cache = result;
    _cacheTime = DateTime.now();
    debugPrint('\u{1F4C8} Forecast: projected expense=${projectedExpense.toStringAsFixed(0)}, '
        'savings=${projectedSavings.toStringAsFixed(0)}, '
        'overspend=${isOverspendRisk ? overspendAmount.toStringAsFixed(0) : "no"}');
    return result;
  }
}
