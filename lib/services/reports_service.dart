import 'package:intl/intl.dart';
import '../models/reports_summary.dart';
import '../data/repositories/transaction_repo.dart';
import '../data/repositories/credit_repo.dart';
import '../data/repositories/loan_repo.dart';
import '../data/repositories/lending_repo.dart';
import '../data/repositories/ledger_repo.dart';
import 'salary_service.dart';

class ReportsService {
  final TransactionRepo transactionRepo;
  final CreditRepo creditRepo;
  final LoanRepo loanRepo;
  final LendingRepo lendingRepo;
  final LedgerRepo ledgerRepo;

  ReportsService({
    required this.transactionRepo,
    required this.creditRepo,
    required this.loanRepo,
    required this.lendingRepo,
    required this.ledgerRepo,
  });

  Future<ReportsSummary> computeSummary(int monthsBack) async {
    // 1. Fetch data in parallel
    final results = await Future.wait([
      transactionRepo.getMonthlyStats(monthsBack),
      creditRepo.getAll(),
      loanRepo.getLoans(),
      lendingRepo.getAll(),
      transactionRepo.getTopExpenseCategories(monthsBack, limit: 10),
      transactionRepo.getAvgDailySpending(monthsBack * 30),
      _getSalarySummary(),
    ]);

    final List<Map<String, dynamic>> stats =
        results[0] as List<Map<String, dynamic>>;
    final creditCards = results[1] as List;
    final loans = results[2] as List;
    final lendings = results[3] as List;
    final categoryRows = results[4] as List<Map<String, dynamic>>;
    final avgDaily = results[5] as double;
    final salaryData = results[6] as _SalarySummary;

    // 2. Process Monthly Trends
    double totalIncome = 0;
    double totalExpense = 0;
    final List<MonthData> monthlyTrend = [];

    for (var s in stats) {
      final monthStr = s['month'] as String;
      final income = (s['income'] as num).toDouble();
      final expense = (s['expense'] as num).toDouble();

      final dateTime = DateTime.parse('$monthStr-01');
      monthlyTrend.add(
        MonthData(
          label: DateFormat('MMM yy').format(dateTime),
          income: income,
          expense: expense,
        ),
      );
      totalIncome += income;
      totalExpense += expense;
    }

    // 3. Process Credit Summaries
    final List<CreditCardSummary> creditSummaries = [];
    for (var card in creditCards) {
      final outstanding = await ledgerRepo.getCreditOutstanding(card.id);
      final utilPct = card.creditLimit > 0
          ? (outstanding / card.creditLimit) * 100
          : 0.0;

      creditSummaries.add(
        CreditCardSummary(
          name: '${card.bank} ${card.last4}',
          outstanding: outstanding,
          limit: card.creditLimit,
          utilPct: utilPct,
          daysLeft: _calculateDaysUntilDue(card.dueDay),
        ),
      );
    }

    // 4. Process Loan Summaries
    final List<LoanSummary> loanSummaries = [];
    for (var loan in loans) {
      final balance = await ledgerRepo.getLoanBalance(loan.id);
      final paid = loan.total - balance;
      final progress = loan.total > 0 ? (paid / loan.total) : 0.0;

      loanSummaries.add(
        LoanSummary(
          name: loan.name,
          totalPrincipal: loan.total,
          totalInterest: 0,
          principalPaid: paid,
          interestPaid: 0,
          remainingPrincipal: balance,
          progress: progress,
        ),
      );
    }

    // 5. Process Lending Trends
    final lendingTrendMap = <String, double>{};
    double totalLent = 0;
    double totalBorrowed = 0;
    for (final lending in lendings) {
      final amount = lending.remainingAmount;
      final key = DateFormat('MMM yy').format(lending.date);
      if (lending.type == 'lent') {
        totalLent += amount;
        lendingTrendMap[key] = (lendingTrendMap[key] ?? 0) + amount;
      } else {
        totalBorrowed += amount;
        lendingTrendMap[key] = (lendingTrendMap[key] ?? 0) - amount;
      }
    }

    // 6. Process Category Breakdown
    final topExpenseCategories = categoryRows.map((r) => CategorySpending(
      categoryName: (r['category_name'] as String?) ?? 'Uncategorized',
      amount: (r['total'] as num).toDouble(),
      transactionCount: (r['count'] as num).toInt(),
    )).toList();

    // 7. Compute Savings Rate
    final savingsRate = totalIncome > 0
        ? ((totalIncome - totalExpense) / totalIncome) * 100
        : 0.0;

    return ReportsSummary(
      monthlyTrend: monthlyTrend,
      totalIncome: totalIncome,
      totalExpense: totalExpense,
      creditSummaries: creditSummaries,
      loanSummaries: loanSummaries,
      fuelMonthlyData: const [],
      lendingTrend: lendingTrendMap.entries
          .map((e) => LendingTrendData(label: e.key, net: e.value))
          .toList(),
      totalLent: totalLent,
      totalBorrowed: totalBorrowed,
      topExpenseCategories: topExpenseCategories,
      savingsRate: savingsRate,
      avgDailySpending: avgDaily,
      totalSalaryEarned: salaryData.totalEarned,
      salarySourceCount: salaryData.sourceCount,
    );
  }

  int _calculateDaysUntilDue(int dueDay) {
    final now = DateTime.now();
    var dueDate = DateTime(now.year, now.month, dueDay);
    if (dueDate.isBefore(now)) {
      dueDate = DateTime(now.year, now.month + 1, dueDay);
    }
    return dueDate.difference(now).inDays;
  }

  Future<_SalarySummary> _getSalarySummary() async {
    try {
      final companies = await SalaryService.instance.getCompanies();
      double totalEarned = 0;
      for (final company in companies) {
        final payments = await SalaryService.instance.getPaymentsForCompany(company.id);
        for (final p in payments) {
          totalEarned += p.amountReceived;
        }
      }
      return _SalarySummary(totalEarned: totalEarned, sourceCount: companies.length);
    } catch (_) {
      return const _SalarySummary(totalEarned: 0, sourceCount: 0);
    }
  }
}

class _SalarySummary {
  final double totalEarned;
  final int sourceCount;
  const _SalarySummary({required this.totalEarned, required this.sourceCount});
}
