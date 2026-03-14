import '../services/database_helper.dart';
import '../services/gamification_service.dart';

class FinancialHealthService {
  FinancialHealthService._();
  static final FinancialHealthService instance = FinancialHealthService._();

  Future<Map<String, double>> calculateMetrics() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    final accounts = await DatabaseHelper.instance.getAllBankAccounts();
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    final lendings = await DatabaseHelper.instance.getAllLendings(settledFilter: false);

    // 1. Savings Rate (30%)
    double income = 0;
    double expenses = 0;
    for (var t in txns) {
      if (t.type == 'income') income += t.amount;
      if (t.type == 'expense') expenses += t.amount;
    }
    double savingsRate = income > 0 ? (income - expenses) / income : 0;
    savingsRate = savingsRate.clamp(0.0, 1.0);

    // 2. Debt Ratio (25%) -> Assets vs Liabilities
    double assets = accounts.where((a) => a.isAsset).fold(0.0, (s, a) => s + a.balance);
    double liabilities = cards.fold(0.0, (s, c) => s + c.outstanding);
    liabilities += lendings.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + (l.originalAmount - l.paidAmount));
    
    double debtRatio = assets > 0 ? liabilities / assets : (liabilities > 0 ? 1.0 : 0.0);
    // Score is inverse of debt ratio (lower debt = higher score)
    double debtScore = (1.0 - debtRatio).clamp(0.0, 1.0);

    // 3. Expense Discipline (20%) -> Based on budget adherence
    // Simplified: Check if expenses > 80% of income (as a proxy for discipline without full budget check)
    double discipline = income > 0 ? 1.0 - (expenses / income).clamp(0.0, 1.0) : 0.5;

    // 4. Consistency (15%) -> Based on streak
    double streak = (await GamificationService.instance.getCurrentStreak()).toDouble();
    double consistencyScore = (streak / 30).clamp(0.0, 1.0); // Max consistency at 30 days

    // 5. Asset Growth (10%) -> Simple net worth check
    double assetGrowth = assets > 0 ? 1.0 : 0.0;

    return {
      'savingsRate': savingsRate,
      'debtRatio': debtScore,
      'expenseDiscipline': discipline,
      'consistency': consistencyScore,
      'assetGrowth': assetGrowth,
    };
  }

  double calculateTotalScore(Map<String, double> metrics) {
    double score = 0;
    score += (metrics['savingsRate'] ?? 0) * 30;
    score += (metrics['debtRatio'] ?? 0) * 25;
    score += (metrics['expenseDiscipline'] ?? 0) * 20;
    score += (metrics['consistency'] ?? 0) * 15;
    score += (metrics['assetGrowth'] ?? 0) * 10;
    return score;
  }

  String getScoreStatus(double score) {
    if (score < 40) return 'Needs Attention';
    if (score < 70) return 'Improving';
    if (score < 85) return 'Healthy';
    return 'Excellent';
  }

  /// Calculates the score for the current state of the app.
  Future<Map<String, dynamic>> calculateFinancialHealthScore() async {
    final metrics = await calculateMetrics();
    final score = calculateTotalScore(metrics);
    
    return {
      'score': score.round(),
      'status': getScoreStatus(score),
      'breakdown': metrics,
    };
  }

  /// Calculates summarized metrics for a specific month.
  Future<Map<String, dynamic>> getMonthlySummary(DateTime month) async {
    final startOfMonth = DateTime(month.year, month.month, 1);
    final endOfMonth = DateTime(month.year, month.month + 1, 0, 23, 59, 59);
    
    final txns = await DatabaseHelper.instance.getAllTransactions();
    final monthlyTxns = txns.where((t) => t.date.isAfter(startOfMonth.subtract(const Duration(seconds: 1))) && t.date.isBefore(endOfMonth.add(const Duration(seconds: 1)))).toList();
    
    double income = 0;
    double expenses = 0;
    Map<String, double> categorySpending = {};
    
    for (var t in monthlyTxns) {
      if (t.type == 'income') {
        income += t.amount;
      } else {
        expenses += t.amount;
        final catId = t.categoryId ?? 'Other';
        categorySpending[catId] = (categorySpending[catId] ?? 0) + t.amount;
      }
    }
    
    double savings = income - expenses;
    double savingsRate = income > 0 ? (savings / income) * 100 : 0;
    
    // Previous month for comparison
    final prevMonth = DateTime(month.year, month.month - 1, 1);
    final prevStart = DateTime(prevMonth.year, prevMonth.month, 1);
    final prevEnd = DateTime(prevMonth.year, prevMonth.month + 1, 0, 23, 59, 59);
    final prevTxns = txns.where((t) => t.date.isAfter(prevStart.subtract(const Duration(seconds: 1))) && t.date.isBefore(prevEnd.add(const Duration(seconds: 1)))).toList();
    
    double prevIncome = 0;
    double prevExpenses = 0;
    for (var t in prevTxns) {
      if (t.type == 'income') prevIncome += t.amount;
      else prevExpenses += t.amount;
    }
    double prevSavings = prevIncome - prevExpenses;
    
    return {
      'income': income,
      'expenses': expenses,
      'savings': savings,
      'savingsRate': savingsRate,
      'transactionCount': monthlyTxns.length,
      'categorySpending': categorySpending,
      'comparison': {
        'incomeChange': prevIncome > 0 ? (income - prevIncome) / prevIncome * 100 : 0,
        'expenseChange': prevExpenses > 0 ? (expenses - prevExpenses) / prevExpenses * 100 : 0,
        'savingsChange': prevSavings != 0 ? (savings - prevSavings) / prevSavings.abs() * 100 : 0,
      }
    };
  }

  /// Calculates net worth at a specific date by subtracting transaction delta 
  /// from current real-time balances.
  Future<double> getHistoricalNetWorth(DateTime targetDate) async {
    final accounts = await DatabaseHelper.instance.getAllBankAccounts();
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    final lendings = await DatabaseHelper.instance.getAllLendings(settledFilter: false);
    
    // 1. Current Net Worth
    double currentAssets = accounts.where((a) => a.isAsset).fold(0.0, (s, a) => s + a.balance);
    double currentLiabilities = cards.fold(0.0, (s, c) => s + c.outstanding);
    currentLiabilities += lendings.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + (l.originalAmount - l.paidAmount));
    
    double currentNetWorth = currentAssets - currentLiabilities;

    // 2. Calculate Transaction Delta (Income - Expense) from targetDate to Now
    final txns = await DatabaseHelper.instance.getAllTransactions();
    
    double delta = 0;
    for (var t in txns) {
      if (t.date.isAfter(targetDate)) {
        if (t.type == 'income') {
          delta += t.amount;
        } else if (t.type == 'expense') {
          delta -= t.amount;
        }
      }
    }

    // Historical NW + Delta = Current NW
    // Historical NW = Current NW - Delta
    return currentNetWorth - delta;
  }
}
