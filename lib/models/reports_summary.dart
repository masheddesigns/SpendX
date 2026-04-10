
class ReportsSummary {
  final List<MonthData> monthlyTrend;
  final double totalIncome;
  final double totalExpense;
  final List<CreditCardSummary> creditSummaries;
  final List<LoanSummary> loanSummaries;
  final List<FuelMonthData> fuelMonthlyData;
  final List<LendingTrendData> lendingTrend;
  final double totalLent;
  final double totalBorrowed;

  // New: category breakdown
  final List<CategorySpending> topExpenseCategories;
  final List<CategorySpending> topIncomeCategories;

  // New: computed metrics
  final double savingsRate; // (income - expense) / income * 100
  final double avgDailySpending;
  final int totalTransactions;

  // New: salary summary
  final double totalSalaryEarned;
  final int salarySourceCount;

  ReportsSummary({
    required this.monthlyTrend,
    required this.totalIncome,
    required this.totalExpense,
    required this.creditSummaries,
    required this.loanSummaries,
    required this.fuelMonthlyData,
    required this.lendingTrend,
    required this.totalLent,
    required this.totalBorrowed,
    this.topExpenseCategories = const [],
    this.topIncomeCategories = const [],
    this.savingsRate = 0,
    this.avgDailySpending = 0,
    this.totalTransactions = 0,
    this.totalSalaryEarned = 0,
    this.salarySourceCount = 0,
  });

  double get netSavings => totalIncome - totalExpense;

  factory ReportsSummary.empty() => ReportsSummary(
    monthlyTrend: [],
    totalIncome: 0,
    totalExpense: 0,
    creditSummaries: [],
    loanSummaries: [],
    fuelMonthlyData: [],
    lendingTrend: [],
    totalLent: 0,
    totalBorrowed: 0,
  );
}

class MonthData {
  final String label;
  final double income;
  final double expense;

  MonthData({required this.label, required this.income, required this.expense});

  double get net => income - expense;
}

class CreditCardSummary {
  final String name;
  final double outstanding;
  final double limit;
  final double utilPct;
  final int daysLeft;

  CreditCardSummary({
    required this.name,
    required this.outstanding,
    required this.limit,
    required this.utilPct,
    required this.daysLeft,
  });
}

class LoanSummary {
  final String name;
  final double totalPrincipal;
  final double totalInterest;
  final double principalPaid;
  final double interestPaid;
  final double remainingPrincipal;
  final double progress;

  LoanSummary({
    required this.name,
    required this.totalPrincipal,
    required this.totalInterest,
    required this.principalPaid,
    required this.interestPaid,
    required this.remainingPrincipal,
    required this.progress,
  });
}

class FuelMonthData {
  final String label;
  final double cost;

  FuelMonthData({required this.label, required this.cost});
}

class LendingTrendData {
  final String label;
  final double net; // positive = lent more, negative = borrowed more

  LendingTrendData({required this.label, required this.net});
}

/// Category spending breakdown for reports.
class CategorySpending {
  final String categoryName;
  final double amount;
  final int transactionCount;

  const CategorySpending({
    required this.categoryName,
    required this.amount,
    required this.transactionCount,
  });
}
