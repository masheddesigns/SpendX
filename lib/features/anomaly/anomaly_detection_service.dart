import '../../models/bank_account.dart';
import '../../models/transaction.dart';
import '../../utils/app_format.dart';
import '../dashboard/insights_providers.dart';
import '../liabilities/providers/credit_health_providers.dart';
import 'anomaly_model.dart';

/// Pure, deterministic anomaly detection. No DB access, no async.
/// All inputs are pre-fetched provider data passed in.
class AnomalyDetectionService {
  List<Anomaly> detect({
    required List<MonthlyStats> monthly,
    required List<CategorySpend> categories,
    required FinancialPressure pressure,
    required CreditHealthSummary credit,
    required List<Transaction> transactions,
    required List<BankAccount> accounts,
  }) {
    final now = DateTime.now();
    final anomalies = <Anomaly>[];

    // ── 1. Spending Spike (month-over-month) ────────────────────────────
    _detectSpendingSpike(monthly, now, anomalies);

    // ── 2. Category Spike ───────────────────────────────────────────────
    _detectCategorySpike(categories, transactions, now, anomalies);

    // ── 3. Large Transaction ────────────────────────────────────────────
    _detectLargeTransaction(transactions, now, anomalies);

    // ── 4. Low Balance Risk ─────────────────────────────────────────────
    _detectLowBalanceRisk(accounts, transactions, now, anomalies);

    // ── 5. Credit Risk ──────────────────────────────────────────────────
    _detectCreditRisk(credit, now, anomalies);

    // ── 6. EMI Pressure ─────────────────────────────────────────────────
    _detectEmiPressure(pressure, now, anomalies);

    // Sort: high → medium → low
    anomalies.sort((a, b) => b.severity.index.compareTo(a.severity.index));

    return anomalies;
  }

  // ── Rule 1: Spending Spike ─────────────────────────────────────────────

  void _detectSpendingSpike(
    List<MonthlyStats> monthly,
    DateTime now,
    List<Anomaly> out,
  ) {
    if (monthly.length < 2) return;

    final current = monthly.first;
    // Average of months 2-4 (skip current)
    final previous = monthly.skip(1).take(3).toList();
    if (previous.isEmpty) return;

    final avgExpense = previous.fold<double>(0, (s, m) => s + m.expense) /
        previous.length;
    if (avgExpense <= 0) return;

    final ratio = current.expense / avgExpense;
    if (ratio < 1.3) return;

    final pct = ((ratio - 1) * 100).round();
    final AnomalySeverity severity;
    if (ratio >= 1.5) {
      severity = AnomalySeverity.high;
    } else {
      severity = AnomalySeverity.medium;
    }

    out.add(Anomaly(
      id: 'spending_spike_${now.month}',
      type: AnomalyType.spendingSpike,
      title: 'Spending up $pct% this month',
      description: 'You\'ve spent ${AppFormat.currency(current.expense)} vs '
          '${AppFormat.currency(avgExpense)} average.',
      severity: severity,
      suggestion: 'Review non-essential expenses to get back on track.',
      detectedAt: now,
    ));
  }

  // ── Rule 2: Category Spike ─────────────────────────────────────────────

  void _detectCategorySpike(
    List<CategorySpend> categories,
    List<Transaction> transactions,
    DateTime now,
    List<Anomaly> out,
  ) {
    if (categories.isEmpty || transactions.isEmpty) return;

    // Build last-3-month average per category
    final threeMonthsAgo = DateTime(now.year, now.month - 3, 1);
    final startOfMonth = DateTime(now.year, now.month, 1);
    final historicalSpend = <String, List<double>>{};

    for (final tx in transactions) {
      if (tx.type != 'expense' || tx.categoryId == null) continue;
      if (tx.date.isBefore(threeMonthsAgo) ||
          !tx.date.isBefore(startOfMonth)) {
        continue;
      }
      historicalSpend.putIfAbsent(tx.categoryId!, () => []);
    }

    // Simpler approach: compare current top-category % vs 50% threshold
    for (final cat in categories.take(3)) {
      if (cat.percentage > 0.50 && cat.amount > 1000) {
        out.add(Anomaly(
          id: 'cat_spike_${cat.categoryId}_${now.month}',
          type: AnomalyType.categorySpike,
          title: '${cat.categoryName} spending is ${(cat.percentage * 100).round()}% of total',
          description: '${AppFormat.currency(cat.amount)} spent on ${cat.categoryName} this month.',
          severity: cat.percentage > 0.60
              ? AnomalySeverity.high
              : AnomalySeverity.medium,
          suggestion: 'Consider setting a budget for ${cat.categoryName}.',
          detectedAt: now,
        ));
        break; // Only flag the top offender
      }
    }
  }

  // ── Rule 3: Large Transaction ──────────────────────────────────────────

  void _detectLargeTransaction(
    List<Transaction> transactions,
    DateTime now,
    List<Anomaly> out,
  ) {
    if (transactions.isEmpty) return;

    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    final recentExpenses = transactions
        .where((t) =>
            t.type == 'expense' &&
            !t.date.isBefore(sevenDaysAgo))
        .toList();

    if (recentExpenses.length < 5) return;

    // Average of all expenses (not just recent)
    final allExpenses = transactions.where((t) => t.type == 'expense').toList();
    if (allExpenses.isEmpty) return;
    final avgAmount =
        allExpenses.fold<double>(0, (s, t) => s + t.amount) / allExpenses.length;

    if (avgAmount <= 0) return;

    for (final tx in recentExpenses) {
      if (tx.amount > avgAmount * 3 && tx.amount > 1000) {
        out.add(Anomaly(
          id: 'large_tx_${tx.id}',
          type: AnomalyType.largeTransaction,
          title: 'Large expense: ${AppFormat.currency(tx.amount)}',
          description: tx.notes.isNotEmpty
              ? 'Recent: ${tx.notes.length > 50 ? '${tx.notes.substring(0, 50)}...' : tx.notes}'
              : 'A transaction significantly above your average.',
          severity: tx.amount > avgAmount * 5
              ? AnomalySeverity.high
              : AnomalySeverity.medium,
          detectedAt: now,
        ));
        break; // Only flag the largest
      }
    }
  }

  // ── Rule 4: Low Balance Risk ───────────────────────────────────────────

  void _detectLowBalanceRisk(
    List<BankAccount> accounts,
    List<Transaction> transactions,
    DateTime now,
    List<Anomaly> out,
  ) {
    final totalBalance = accounts
        .where((a) => a.isAsset)
        .fold<double>(0, (s, a) => s + a.balance);

    if (totalBalance <= 0) {
      out.add(Anomaly(
        id: 'zero_balance_${now.month}',
        type: AnomalyType.lowBalanceRisk,
        title: 'Balance is zero or negative',
        description: 'Your total account balance is ${AppFormat.currency(totalBalance)}.',
        severity: AnomalySeverity.high,
        suggestion: 'Reduce expenses or add income to maintain a buffer.',
        detectedAt: now,
      ));
      return;
    }

    // Calculate daily expense rate from last 30 days
    final thirtyDaysAgo = now.subtract(const Duration(days: 30));
    final recentExpenses = transactions
        .where((t) => t.type == 'expense' && !t.date.isBefore(thirtyDaysAgo))
        .fold<double>(0, (s, t) => s + t.amount);
    final dailyExpense = recentExpenses / 30;

    if (dailyExpense <= 0) return;

    final daysLeft = (totalBalance / dailyExpense).floor();
    if (daysLeft < 7) {
      out.add(Anomaly(
        id: 'low_balance_${now.month}_${now.day}',
        type: AnomalyType.lowBalanceRisk,
        title: 'Balance may last only $daysLeft days',
        description: '${AppFormat.currency(totalBalance)} left at '
            '${AppFormat.currency(dailyExpense)}/day burn rate.',
        severity: daysLeft < 3
            ? AnomalySeverity.high
            : AnomalySeverity.medium,
        suggestion: 'Cut discretionary spending or ensure income arrives soon.',
        detectedAt: now,
      ));
    }
  }

  // ── Rule 5: Credit Risk ────────────────────────────────────────────────

  void _detectCreditRisk(
    CreditHealthSummary credit,
    DateTime now,
    List<Anomaly> out,
  ) {
    if (credit.totalLimit <= 0) return;

    if (credit.utilizationPct > 80) {
      out.add(Anomaly(
        id: 'credit_risk_${now.month}',
        type: AnomalyType.creditRisk,
        title: 'Credit utilization at ${credit.utilizationPct.round()}%',
        description: '${AppFormat.currency(credit.totalOutstanding)} of '
            '${AppFormat.currency(credit.totalLimit)} used.',
        severity: credit.utilizationPct > 90
            ? AnomalySeverity.high
            : AnomalySeverity.medium,
        suggestion: 'Pay down ${AppFormat.currency(credit.totalOutstanding - credit.totalLimit * 0.3)} '
            'to reach safe 30% utilization.',
        detectedAt: now,
      ));
    }
  }

  // ── Rule 6: EMI Pressure ───────────────────────────────────────────────

  void _detectEmiPressure(
    FinancialPressure pressure,
    DateTime now,
    List<Anomaly> out,
  ) {
    if (pressure.monthlyIncome <= 0) return;

    if (pressure.pressureRatio > 0.6) {
      final pct = (pressure.pressureRatio * 100).round();
      out.add(Anomaly(
        id: 'emi_pressure_${now.month}',
        type: AnomalyType.emiPressure,
        title: 'Debt obligations at $pct% of income',
        description: '${AppFormat.currency(pressure.monthlyObligations)} monthly vs '
            '${AppFormat.currency(pressure.monthlyIncome)} income.',
        severity: pressure.pressureRatio > 0.8
            ? AnomalySeverity.high
            : AnomalySeverity.medium,
        suggestion: 'Avoid new EMIs. Focus on paying off highest-interest debt first.',
        detectedAt: now,
      ));
    }
  }
}
