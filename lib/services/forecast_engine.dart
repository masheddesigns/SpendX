import 'dart:math' as math;
import 'package:flutter/foundation.dart' show debugPrint;

import '../data/repositories/canonical/canonical_financial_query_repository.dart';
import '../domain/finance/finance.dart';
import 'canonical_forecast_engine.dart';

/// End-of-month financial forecast adapter.
///
/// Refactored in Milestone C6 to delegate to [CanonicalForecastEngine]
/// and [CanonicalFinancialQueryRepository].
///
/// CRITICAL FIX: The catastrophic linear salary velocity multiplier
/// ((monthIncome / daysElapsed) * daysInMonth) has been eliminated.
/// Projections are derived strictly from canonical accounting truth and contractual dates.
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
    projectedIncome: 0,
    projectedExpense: 0,
    projectedSavings: 0,
    categoryForecasts: {},
    dailyBurnRate: 0,
    daysElapsed: 0,
    daysInMonth: 30,
    isOverspendRisk: false,
    overspendAmount: 0,
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

/// Forecast computation engine compatibility adapter.
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

  /// Compute end-of-month forecast derived from canonical accounting truth.
  Future<Forecast> compute({
    CanonicalFinancialQueryRepository? queryRepository,
    CanonicalForecastEngine? forecastEngine,
  }) async {
    // 5-minute cache
    if (queryRepository == null &&
        forecastEngine == null &&
        _cache != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < const Duration(minutes: 5)) {
      return _cache!;
    }

    final queryRepo = queryRepository ?? CanonicalFinancialQueryRepository();
    final engine = forecastEngine ?? CanonicalForecastEngine.instance;
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final endOfMonth = DateTime(now.year, now.month, daysInMonth, 23, 59, 59);
    final daysElapsed = now.day.clamp(1, daysInMonth);
    final remainingDays = (daysInMonth - daysElapsed).clamp(0, daysInMonth);

    // Compute canonical forecast
    final canonicalForecast = await engine.computeForecast(
      horizonDays: remainingDays > 0 ? remainingDays : 1,
      referenceDate: now,
    );

    // Actual posted MTD figures from canonical ledger
    final mtdIncome = await queryRepo.getTotalIncome(
      startDate: startOfMonth,
      endDate: now,
    );
    final mtdExpense = await queryRepo.getTotalExpenses(
      startDate: startOfMonth,
      endDate: now,
    );

    // Contractual upcoming inflows and commitments until month end
    final upcomingIncome = await queryRepo.getUpcomingExpectedInflows(
      fromDate: now,
      toDate: endOfMonth,
    );
    final upcomingCommitments = await queryRepo.getUpcomingExpectedCommitments(
      fromDate: now,
      toDate: endOfMonth,
    );

    // Projected totals: actual MTD + known upcoming + remaining discretionary burn
    final remainingDiscretionary =
        canonicalForecast.dailyBurnRate.minorUnits * remainingDays;
    final totalProjectedIncome = mtdIncome + upcomingIncome;
    final totalProjectedExpense = mtdExpense +
        upcomingCommitments +
        Money.fromMinorUnits(remainingDiscretionary);
    final totalProjectedSavings = totalProjectedIncome - totalProjectedExpense;

    // Previous month total expenses for overspend comparison
    final startOfPrevMonth = DateTime(now.year, now.month - 1, 1);
    final endOfPrevMonth = DateTime(now.year, now.month, 0, 23, 59, 59);
    final prevTotalExpense = await queryRepo.getTotalExpenses(
      startDate: startOfPrevMonth,
      endDate: endOfPrevMonth,
    );

    // Category breakdown derived from canonical postings
    final currentCatSpending = await queryRepo.getAllCategorySpending(
      startDate: startOfMonth,
      endDate: now,
    );
    final prevCatSpending = await queryRepo.getAllCategorySpending(
      startDate: startOfPrevMonth,
      endDate: endOfPrevMonth,
    );

    final categoryForecasts = <String, CategoryForecast>{};
    for (final entry in currentCatSpending.entries) {
      final spent = entry.value.asRupees;
      final prev = prevCatSpending[entry.key]?.asRupees ?? 0.0;
      final daily = daysElapsed > 0 ? spent / daysElapsed : 0.0;
      final proj = daily * daysInMonth;
      final drift = prev > 0 ? ((proj - prev) / prev) * 100 : 0.0;

      categoryForecasts[entry.key] = CategoryForecast(
        categoryName: entry.key,
        spentSoFar: spent,
        projected: proj,
        previousMonthTotal: prev,
        driftPercent: drift,
      );
    }

    final projectedExpenseRupees = totalProjectedExpense.asRupees;
    final projectedIncomeRupees = totalProjectedIncome.asRupees;
    final projectedSavingsRupees = totalProjectedSavings.asRupees;

    final exceedsPrevMonth = prevTotalExpense.asRupees > 0 &&
        projectedExpenseRupees > prevTotalExpense.asRupees * 1.1;
    final negativeSavings = projectedSavingsRupees < 0;
    final isOverspendRisk = exceedsPrevMonth || negativeSavings;
    final overspendAmount = isOverspendRisk
        ? (negativeSavings
            ? projectedExpenseRupees - projectedIncomeRupees
            : projectedExpenseRupees - prevTotalExpense.asRupees)
        : 0.0;

    final result = Forecast(
      projectedIncome: projectedIncomeRupees,
      projectedExpense: projectedExpenseRupees,
      projectedSavings: projectedSavingsRupees,
      categoryForecasts: categoryForecasts,
      dailyBurnRate: canonicalForecast.dailyBurnRate.asRupees,
      daysElapsed: daysElapsed,
      daysInMonth: daysInMonth,
      isOverspendRisk: isOverspendRisk,
      overspendAmount: math.max(0, overspendAmount),
    );

    _cache = result;
    _cacheTime = DateTime.now();
    debugPrint('📈 Canonical Forecast: projected expense=${projectedExpenseRupees.toStringAsFixed(0)}, '
        'savings=${projectedSavingsRupees.toStringAsFixed(0)}, '
        'overspend=${isOverspendRisk ? overspendAmount.toStringAsFixed(0) : "no"}');
    return result;
  }
}
