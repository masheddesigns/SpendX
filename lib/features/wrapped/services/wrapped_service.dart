import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/repositories/transaction_repo.dart';
import '../models/wrapped_summary.dart';

/// Service that computes and caches Wrapped summaries.
/// UI → Provider → WrappedService → Repository → DB
///
/// Periods auto-dismiss after 5 days from first appearance.
class WrappedService {
  final TransactionRepo _repo;
  final Map<String, WrappedSummary> _cache = {};
  static const _seenKeyPrefix = 'wrapped_first_seen_';
  static const _dismissDays = 5;

  WrappedService(this._repo);

  /// Get a cached or freshly computed summary for a period.
  /// [period] is "2026-W14" (weekly), "2026-03" (monthly), or "2025" (yearly).
  Future<WrappedSummary?> getSummary(String period) async {
    if (_cache.containsKey(period)) return _cache[period];

    WrappedSummary? summary;
    if (period.contains('-W')) {
      summary = await _computeWeekly(period);
    } else if (period.contains('-')) {
      summary = await _computeMonthly(period);
    } else {
      summary = await _computeYearly(period);
    }

    if (summary != null) _cache[period] = summary;
    return summary;
  }

  /// Clear cache (e.g., after new transactions imported).
  void invalidate() => _cache.clear();

  /// Get available periods (latest first, max 6).
  /// Periods auto-dismiss after 5 days from first appearance.
  /// Includes: current week, recent months, years.
  Future<List<String>> getAvailablePeriods() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    final months = await _repo.getDistinctMonths(limit: 5);

    // Build candidate periods
    final candidates = <String>[];

    // Current week wrapped
    final weekNum = _isoWeekNumber(now);
    final weekKey = '${now.year}-W${weekNum.toString().padLeft(2, '0')}';
    candidates.add(weekKey);

    // Previous week (if within 5 days)
    final prevWeekDate = now.subtract(const Duration(days: 7));
    final prevWeekNum = _isoWeekNumber(prevWeekDate);
    final prevWeekKey =
        '${prevWeekDate.year}-W${prevWeekNum.toString().padLeft(2, '0')}';
    candidates.add(prevWeekKey);

    // Monthly
    candidates.addAll(months);

    // Yearly
    final years = <String>{};
    for (final m in months) {
      years.add(m.split('-').first);
    }
    candidates.addAll(years);

    // Filter: remove duplicates, check 5-day dismiss
    final seen = <String>{};
    final result = <String>[];
    for (final period in candidates) {
      if (seen.contains(period)) continue;
      seen.add(period);

      // Check if dismissed (first seen > 5 days ago)
      final seenKey = '$_seenKeyPrefix$period';
      final firstSeenMs = prefs.getInt(seenKey);
      if (firstSeenMs != null) {
        final firstSeen = DateTime.fromMillisecondsSinceEpoch(firstSeenMs);
        if (now.difference(firstSeen).inDays >= _dismissDays) continue;
      } else {
        // First time seeing this period — record it
        await prefs.setInt(seenKey, now.millisecondsSinceEpoch);
      }

      result.add(period);
    }

    return result.take(6).toList();
  }

  Future<WrappedSummary?> _computeWeekly(String period) async {
    // period = "2026-W14"
    final parts = period.split('-W');
    if (parts.length != 2) return null;
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return null;

    // Calculate week start (Monday) and end (Sunday)
    final jan1 = DateTime(year, 1, 1);
    final jan1Weekday = jan1.weekday; // 1=Mon
    final weekStart =
        jan1.add(Duration(days: (week - 1) * 7 - (jan1Weekday - 1)));
    final weekEnd = weekStart.add(const Duration(days: 7));

    final stats = await _repo.getStatsForRange(weekStart, weekEnd);
    final income = stats['income'] as double;
    final expense = stats['expense'] as double;
    final txnCount = stats['txn_count'] as int;

    if (txnCount == 0) return null;

    final topCats = _parseCategories(
        stats['top_categories'] as List<Map<String, dynamic>>, expense);

    // Previous week comparison
    final prevStart = weekStart.subtract(const Duration(days: 7));
    final prevEnd = weekStart;
    final prevStats = await _repo.getStatsForRange(prevStart, prevEnd);

    return WrappedSummary(
      period: period,
      isYearly: false,
      totalIncome: income,
      totalExpense: expense,
      savings: income - expense,
      topCategories: topCats,
      transactionCount: txnCount,
      biggestExpense: stats['biggest_expense'] as double,
      biggestCategory: topCats.isNotEmpty ? topCats.first.categoryName : null,
      prevIncome: prevStats['income'] as double?,
      prevExpense: prevStats['expense'] as double?,
    );
  }

  /// ISO 8601 week number.
  static int _isoWeekNumber(DateTime date) {
    final dayOfYear = date.difference(DateTime(date.year, 1, 1)).inDays + 1;
    final weekday = date.weekday; // 1=Mon, 7=Sun
    return ((dayOfYear - weekday + 10) / 7).floor();
  }

  Future<WrappedSummary?> _computeMonthly(String period) async {
    final parts = period.split('-');
    if (parts.length != 2) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null) return null;

    final stats = await _repo.getStatsForMonth(year, month);
    final income = stats['income'] as double;
    final expense = stats['expense'] as double;
    final txnCount = stats['txn_count'] as int;

    if (txnCount == 0) return null;

    final topCats = _parseCategories(
        stats['top_categories'] as List<Map<String, dynamic>>, expense);

    // Previous month comparison
    final prevMonth = month == 1 ? 12 : month - 1;
    final prevYear = month == 1 ? year - 1 : year;
    final prevStats = await _repo.getStatsForMonth(prevYear, prevMonth);

    return WrappedSummary(
      period: period,
      isYearly: false,
      totalIncome: income,
      totalExpense: expense,
      savings: income - expense,
      topCategories: topCats,
      transactionCount: txnCount,
      biggestExpense: stats['biggest_expense'] as double,
      biggestCategory: topCats.isNotEmpty ? topCats.first.categoryName : null,
      prevIncome: prevStats['income'] as double?,
      prevExpense: prevStats['expense'] as double?,
    );
  }

  Future<WrappedSummary?> _computeYearly(String period) async {
    final year = int.tryParse(period);
    if (year == null) return null;

    final stats = await _repo.getStatsForYear(year);
    final income = stats['income'] as double;
    final expense = stats['expense'] as double;
    final txnCount = stats['txn_count'] as int;

    if (txnCount == 0) return null;

    final topCats = _parseCategories(
        stats['top_categories'] as List<Map<String, dynamic>>, expense);

    // Previous year comparison
    final prevStats = await _repo.getStatsForYear(year - 1);

    return WrappedSummary(
      period: period,
      isYearly: true,
      totalIncome: income,
      totalExpense: expense,
      savings: income - expense,
      topCategories: topCats,
      transactionCount: txnCount,
      biggestExpense: stats['biggest_expense'] as double,
      biggestCategory: topCats.isNotEmpty ? topCats.first.categoryName : null,
      monthlyIncomeTrend: (stats['monthly_income'] as List?)?.cast<double>(),
      monthlyExpenseTrend: (stats['monthly_expense'] as List?)?.cast<double>(),
      prevIncome: prevStats['income'] as double?,
      prevExpense: prevStats['expense'] as double?,
    );
  }

  List<CategorySpendItem> _parseCategories(
      List<Map<String, dynamic>> rows, double totalExpense) {
    return rows.map((r) {
      final amount = (r['total'] as num?)?.toDouble() ?? 0;
      return CategorySpendItem(
        categoryId: r['category_id'] as String? ?? '',
        categoryName: r['name'] as String? ?? 'Unknown',
        categoryIcon: r['icon'] as String? ?? 'category',
        categoryColor: r['color'] as String? ?? 'FF9E9E9E',
        amount: amount,
        percentage: totalExpense > 0 ? (amount / totalExpense) * 100 : 0,
      );
    }).toList();
  }
}
