import 'dart:math' as math;
import '../data/core/app_database.dart';
import '../data/core/tables.dart';
import '../services/gamification_service.dart';
import 'insights_activity_service.dart';

import '../data/repositories/transaction_repo.dart';
import '../data/repositories/account_repo.dart';
import '../data/repositories/loan_repo.dart';
import '../data/repositories/salary_repo.dart';

import '../data/repositories/lending_repo.dart';
import '../data/repositories/category_repo.dart';

class FinancialHealthService {
  final TransactionRepo transactionRepo;
  final AccountRepo accountRepo;
  final LoanRepo loanRepo;
  final SalaryRepo salaryRepo;
  final LendingRepo lendingRepo;
  final CategoryRepo categoryRepo;

  FinancialHealthService({
    required this.transactionRepo,
    required this.accountRepo,
    required this.loanRepo,
    required this.salaryRepo,
    required this.lendingRepo,
    required this.categoryRepo,
  });

  static final FinancialHealthService instance = FinancialHealthService(
    transactionRepo: TransactionRepo(),
    accountRepo: AccountRepo(),
    loanRepo: LoanRepo(),
    salaryRepo: SalaryRepo(),
    lendingRepo: LendingRepo(),
    categoryRepo: CategoryRepo(),
  );


  Future<Map<String, double>> calculateMetrics() async {
    final txns = await transactionRepo.getAll();
    final accounts = await accountRepo.getAccounts();
    final cards = await accountRepo.getCards();
    final salaries = await salaryRepo.getAll();
    
    // Lending usage is still direct if no repo, but I'll add a minimal check.
    // For now, I'll just keep it minimal to unblock the build.
    final lendings = await lendingRepo.getAll(settledFilter: false);



    final now = DateTime.now();

    // Helper for Exponential Decay Weighting: weight = e^(-days / 7)
    double getWeight(DateTime date) {
      final days = now.difference(date).inDays.toDouble().clamp(0.0, 90.0);
      return math.exp(-days / 7.0);
    }

    // 1. Savings Rate (30%) - Weighted by Recency
    double weightedIncome = 0;
    double weightedExpenses = 0;
    double totalWeightIncome = 0;
    double totalWeightExpenses = 0; // ignore: unused_local_variable

    // Use confirmed salary records as priority income (flat weight for salary)
    if (salaries.isNotEmpty) {
      for (var s in salaries) {
        weightedIncome += (s['net_salary'] as num?)?.toDouble() ?? 0.0;
      }
      totalWeightIncome = 1.0;
    }


    for (var t in txns) {
      final w = getWeight(t.date);
      if (t.type == 'income' && salaries.isEmpty) {
        weightedIncome += t.amount * w;
        totalWeightIncome += w;
      } else if (t.type == 'expense') {
        weightedExpenses += t.amount * w;
        totalWeightExpenses += w;
      }
    }

    double savingsRate = (weightedIncome > 0 && totalWeightIncome > 0) 
        ? (weightedIncome - weightedExpenses) / weightedIncome 
        : 0.0;
    savingsRate = savingsRate.clamp(0.0, 1.0);

    // 2. Debt Ratio (25%) -> Assets vs Liabilities (Real-time, no decay needed)
    double assets = accounts.where((a) => a.isAsset).fold(0.0, (s, a) => s + a.balance);
    double liabilities = cards.fold(0.0, (s, c) => s + c.usedAmount);

    liabilities += lendings.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + (l.originalAmount - l.paidAmount));
    
    double debtRatio = assets > 0 ? liabilities / assets : (liabilities > 0 ? 1.0 : 0.0);
    double debtScore = (1.0 - debtRatio).clamp(0.0, 1.0);

    // 3. Expense Discipline (20%) -> Weighting + Challenge Compliance
    // Proxy: How much of income is consumed?
    double rawDiscipline = weightedIncome > 0 && totalWeightIncome > 0 
        ? 1.0 - (weightedExpenses / weightedIncome).clamp(0.0, 1.0) 
        : 0.5;
    
    // IMPACT: Challenge Compliance
    // IMPACT: Challenge Compliance
    final database = await AppDatabase.instance.database;
    final complianceRecords = await database.query(Tables.insight_compliance);
    double complianceBonus = 0;
    if (complianceRecords.isNotEmpty) {
      final completed = complianceRecords.where((r) => r['status'] == 'completed').length;
      final failed = complianceRecords.where((r) => r['status'] == 'failed').length;
      complianceBonus = (completed * 0.05) - (failed * 0.02); // Small but significant impact
    }

    double discipline = (rawDiscipline + complianceBonus).clamp(0.0, 1.0);

    // 4. Consistency (15%) -> Based on streak
    double streak = (await GamificationService.instance.getCurrentStreak()).toDouble();
    double consistencyScore = (streak / 30).clamp(0.0, 1.0); 

    // 5. Asset Growth (10%)
    double assetGrowth = assets > 1000 ? 1.0 : 0.0;

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
  Future<Map<String, dynamic>> calculateFinancialHealthScore({
    bool saveSnapshot = false,
  }) async {
    final metrics = await calculateMetrics();
    final score = calculateTotalScore(metrics);

    if (saveSnapshot) {
      await _saveScoreSnapshot(score, metrics);
    }

    return {
      'score': score.round(),
      'status': getScoreStatus(score),
      'breakdown': metrics,
    };
  }

  Future<void> _saveScoreSnapshot(double score, Map<String, double> metrics) async {
    final db = await AppDatabase.instance.database;
    await db.insert(Tables.health_score_history, {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'timestamp': DateTime.now().toIso8601String(),
      'total_score': score,
      'savings_rate': metrics['savingsRate'] ?? 0,
      'debt_ratio': metrics['debtRatio'] ?? 0,
      'discipline': metrics['expenseDiscipline'] ?? 0,
      'consistency': metrics['consistency'] ?? 0,
      'asset_growth': metrics['assetGrowth'] ?? 0,
    });
  }



  Future<Map<String, dynamic>> getScoreChangeExplanation() async {
    final db = await AppDatabase.instance.database;
    final snapshots = await db.query(
      Tables.health_score_history,
      orderBy: 'timestamp DESC',
      limit: 2,
    );


    if (snapshots.length < 2) {
      return {'change': 0.0, 'reason': 'Initial calculation complete.'};
    }

    final latest = snapshots[0];
    final previous = snapshots[1];

    final scoreDiff =
        (latest['total_score'] as num).toDouble() -
        (previous['total_score'] as num).toDouble();

    // Find the metric with the largest impact on the change
    final metrics = [
      'savings_rate',
      'debt_ratio',
      'discipline',
      'consistency',
      'asset_growth',
    ];
    final labels = {
      'savings_rate': 'Savings Rate',
      'debt_ratio': 'Debt Ratio',
      'discipline': 'Discipline',
      'consistency': 'Consistency',
      'asset_growth': 'Asset Growth',
    };

    String topReason = 'Stable behavior';
    double maxMetricDiff = 0;

    for (var m in metrics) {
      final diff =
          (latest[m] as num).toDouble() - (previous[m] as num).toDouble();
      if (diff.abs() > maxMetricDiff.abs()) {
        maxMetricDiff = diff;
        topReason = labels[m]!;
      }
    }

    final direction = maxMetricDiff >= 0 ? '↑' : '↓';
    return {
      'change': scoreDiff,
      'reason':
          scoreDiff.abs() < 1
              ? 'No significant change'
              : '${scoreDiff > 0 ? 'Improvement' : 'Drop'} in $topReason $direction',
    };
  }

  /// Calculates summarized metrics for a specific month.
  Future<Map<String, dynamic>> getMonthlySummary(DateTime month) async {
    final startOfMonth = DateTime(month.year, month.month, 1);
    final endOfMonth = DateTime(month.year, month.month + 1, 0, 23, 59, 59);
    
    final txns = await transactionRepo.getAll();

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
      if (t.type == 'income') {
        prevIncome += t.amount;
      } else {
        prevExpenses += t.amount;
      }
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
    final accounts = await accountRepo.getAccounts();
    final cards = await accountRepo.getCards();
    final lendings = await lendingRepo.getAll(settledFilter: false);

    
    // 1. Current Net Worth
    double currentAssets = accounts.where((a) => a.isAsset).fold(0.0, (s, a) => s + a.balance);
    double currentLiabilities = cards.fold(0.0, (s, c) => s + c.usedAmount);

    currentLiabilities += lendings.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + (l.originalAmount - l.paidAmount));
    
    double currentNetWorth = currentAssets - currentLiabilities;

    // 2. Calculate Transaction Delta (Income - Expense) from targetDate to Now
    final txns = await transactionRepo.getAll();

    
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

  /// Calculates a hypothetical health score for the end of the month based on projections.
  Future<double> getProjectedMonthEndScore() async {
    try {
      final metrics = await calculateMetrics();
      final forecast = await InsightsActivityService.instance.getMonthlyForecast();

      // Use null-safe reads from the new stable forecast contract.
      final monthlySpend = (forecast['monthlySpend'] as num?)?.toDouble() ?? 0.0;

      final salaryList = await salaryRepo.getAll();

      final totalIncome = salaryList.fold(
        0.0,
        (double sum, s) => sum + ((s['netSalary'] ?? s['net_salary'] ?? 0) as num).toDouble(),
      );

      if (totalIncome > 0 && monthlySpend > 0) {
        metrics['savingsRate'] = ((totalIncome - monthlySpend) / totalIncome).clamp(0.0, 1.0);
        metrics['expenseDiscipline'] = (1.0 - (monthlySpend / totalIncome)).clamp(0.0, 1.0);
      }

      return calculateTotalScore(metrics);
    } catch (_) {
      return 0.0;
    }
  }
}
