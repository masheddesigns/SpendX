/// Data models for Monthly/Yearly Wrapped summaries.
/// All computation happens in WrappedService — never in UI.
library;

class CategorySpendItem {
  final String categoryId;
  final String categoryName;
  final String categoryIcon;
  final String categoryColor;
  final double amount;
  final double percentage;

  const CategorySpendItem({
    required this.categoryId,
    required this.categoryName,
    this.categoryIcon = 'category',
    this.categoryColor = 'FF9E9E9E',
    required this.amount,
    required this.percentage,
  });
}

class WrappedSummary {
  final String period; // "2026-03" (monthly) or "2025" (yearly)
  final bool isYearly;

  final double totalIncome;
  final double totalExpense;
  final double savings;

  final List<CategorySpendItem> topCategories;
  final int transactionCount;
  final double biggestExpense;
  final String? biggestCategory;

  // Month-by-month trend (yearly only — 12 entries)
  final List<double>? monthlyExpenseTrend;
  final List<double>? monthlyIncomeTrend;

  // Comparison to previous period
  final double? prevIncome;
  final double? prevExpense;

  const WrappedSummary({
    required this.period,
    required this.isYearly,
    required this.totalIncome,
    required this.totalExpense,
    required this.savings,
    required this.topCategories,
    required this.transactionCount,
    required this.biggestExpense,
    this.biggestCategory,
    this.monthlyExpenseTrend,
    this.monthlyIncomeTrend,
    this.prevIncome,
    this.prevExpense,
  });

  double get savingsRate => totalIncome == 0 ? 0 : savings / totalIncome;

  double get incomeChange =>
      prevIncome == null || prevIncome == 0
          ? 0
          : ((totalIncome - prevIncome!) / prevIncome!) * 100;

  double get expenseChange =>
      prevExpense == null || prevExpense == 0
          ? 0
          : ((totalExpense - prevExpense!) / prevExpense!) * 100;

  String get label {
    if (isYearly) return period;
    if (period.contains('-W')) return 'Week ${period.split('-W').last}';
    return _monthLabel(period);
  }

  bool get isWeekly => period.contains('-W');

  static String _monthLabel(String period) {
    final parts = period.split('-');
    if (parts.length != 2) return period;
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final m = int.tryParse(parts[1]) ?? 0;
    return '${months[m.clamp(1, 12)]} ${parts[0]}';
  }
}
