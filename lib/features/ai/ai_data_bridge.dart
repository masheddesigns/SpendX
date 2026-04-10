import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/accounts/providers/account_providers.dart';
import '../../features/automation/automation_engine.dart';
import '../../features/automation/automation_providers.dart';
import '../../features/budget/budget_providers.dart';
import '../../features/forecast/forecast_provider.dart';
import '../../features/gamification/xp_provider.dart';
import '../../features/income/income_providers.dart';
import '../../features/cashflow/runway_engine.dart';
import '../../features/cashflow/runway_provider.dart';
import '../../features/streak/streak_provider.dart';
import '../../features/anomaly/anomaly_model.dart';
import '../../features/anomaly/anomaly_provider.dart';
import '../../features/dashboard/insights_providers.dart';
import '../../features/health/health_score_provider.dart';
import '../../features/liabilities/providers/credit_health_providers.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../utils/app_format.dart';
import 'ai_intent.dart';

/// Resolves an [AIIntent] into a deterministic, data-backed response string.
///
/// Hard rule: ALL data comes from existing providers. No direct DB access.
/// This ensures the AI layer cannot diverge from what the UI shows.
class AIDataBridge {
  final Ref _ref;

  AIDataBridge(this._ref);

  /// Handle a user query: parse intent, fetch data, format response.
  /// Returns null if the intent is [AIIntent.unknown] (caller should
  /// fall through to Gemini).
  Future<String?> handle(String input) async {
    final intent = parseIntent(input);
    if (intent == AIIntent.unknown) return null;

    switch (intent) {
      case AIIntent.balance:
        return _handleBalance();
      case AIIntent.spending:
        return _handleSpending();
      case AIIntent.income:
        return _handleIncome();
      case AIIntent.categories:
        return _handleCategories();
      case AIIntent.netWorth:
        return _handleNetWorth();
      case AIIntent.trend:
        return _handleTrend();
      case AIIntent.savingsRate:
        return _handleSavingsRate();
      case AIIntent.creditCards:
        return _handleCreditCards();
      case AIIntent.creditHealth:
        return _handleCreditHealth();
      case AIIntent.emiLoad:
        return _handleEmiLoad();
      case AIIntent.upcomingDues:
        return _handleUpcomingDues();
      case AIIntent.debtPressure:
        return _handleDebtPressure();
      case AIIntent.healthScore:
        return _handleHealthScore();
      case AIIntent.anomalyCheck:
        return _handleAnomalyCheck();
      case AIIntent.streakStatus:
        return _handleStreak();
      case AIIntent.budgetStatus:
        return _handleBudget();
      case AIIntent.runwayStatus:
        return _handleRunway();
      case AIIntent.financialAdvice:
        return _handleFinancialAdvice();
      case AIIntent.forecast:
        return _handleForecast();
      case AIIntent.progressStatus:
        return _handleProgress();
      case AIIntent.canIAfford:
        return _handleCanIAfford(input);
      case AIIntent.incomeStability:
        return _handleIncomeStability();
      case AIIntent.salaryPrediction:
        return _handleSalaryPrediction();
      case AIIntent.unknown:
        return null;
    }
  }

  // ── Balance ──────────────────────────────────────────────────────────

  Future<String> _handleBalance() async {
    final accounts = await _ref.read(accountsProvider.future);
    if (accounts.isEmpty) {
      return 'You don\'t have any accounts set up yet. Add one from the Accounts screen.';
    }

    double totalAssets = 0;
    final lines = <String>[];
    for (final a in accounts) {
      if (a.isAsset) totalAssets += a.balance;
      lines.add('${a.name}: ${AppFormat.currency(a.balance)}');
    }

    final sb = StringBuffer();
    sb.writeln('Your total balance is ${AppFormat.currency(totalAssets)}');
    sb.writeln();
    for (final line in lines) {
      sb.writeln('  $line');
    }
    return sb.toString().trim();
  }

  // ── Spending ─────────────────────────────────────────────────────────

  Future<String> _handleSpending() async {
    final stats = await _ref.read(currentMonthStatsProvider.future);
    if (stats == null) {
      return 'No spending data available for this month yet.';
    }

    final topCats = await _ref.read(topCategoriesProvider.future);
    final sb = StringBuffer();
    sb.writeln('You\'ve spent ${AppFormat.currency(stats.expense)} this month.');

    if (topCats.isNotEmpty) {
      sb.writeln();
      sb.writeln('Top spending:');
      for (final cat in topCats.take(3)) {
        sb.writeln('  ${cat.categoryName}: ${AppFormat.currency(cat.amount)} '
            '(${(cat.percentage * 100).round()}%)');
      }
    }

    return sb.toString().trim();
  }

  // ── Income ───────────────────────────────────────────────────────────

  Future<String> _handleIncome() async {
    final stats = await _ref.read(currentMonthStatsProvider.future);
    if (stats == null || stats.income == 0) {
      return 'No income recorded this month yet.';
    }

    final savings = stats.savings;
    final sb = StringBuffer();
    sb.writeln('Your income this month is ${AppFormat.currency(stats.income)}.');
    if (stats.expense > 0) {
      sb.writeln('After expenses of ${AppFormat.currency(stats.expense)}, '
          'you\'ve saved ${AppFormat.currency(savings)}.');
    }

    return sb.toString().trim();
  }

  // ── Categories ───────────────────────────────────────────────────────

  Future<String> _handleCategories() async {
    final topCats = await _ref.read(topCategoriesProvider.future);
    if (topCats.isEmpty) {
      return 'No categorized expenses found this month.';
    }

    final sb = StringBuffer();
    sb.writeln('Your top spending categories this month:');
    sb.writeln();
    for (var i = 0; i < topCats.length; i++) {
      final cat = topCats[i];
      sb.writeln('${i + 1}. ${cat.categoryName}: '
          '${AppFormat.currency(cat.amount)} '
          '(${(cat.percentage * 100).round()}%)');
    }

    if (topCats.isNotEmpty) {
      sb.writeln();
      sb.writeln('${topCats.first.categoryName} is your biggest expense category.');
    }

    return sb.toString().trim();
  }

  // ── Net Worth ────────────────────────────────────────────────────────

  Future<String> _handleNetWorth() async {
    final change = await _ref.read(netWorthChangeProvider.future);

    final sb = StringBuffer();
    sb.writeln('Your net worth is ${AppFormat.currency(change.current)}.');

    if (change.change != 0) {
      final direction = change.change > 0 ? 'increased' : 'decreased';
      final pct = change.changePct.abs().toStringAsFixed(1);
      sb.writeln('It has $direction by ${AppFormat.currency(change.change.abs())} '
          '($pct%) over the last 30 days.');
    }

    return sb.toString().trim();
  }

  // ── Trend ────────────────────────────────────────────────────────────

  Future<String> _handleTrend() async {
    final current = await _ref.read(currentMonthStatsProvider.future);
    final previous = await _ref.read(previousMonthStatsProvider.future);

    if (current == null) {
      return 'Not enough data to show spending trends yet.';
    }

    final sb = StringBuffer();
    sb.writeln('This month: ${AppFormat.currency(current.expense)} spent, '
        '${AppFormat.currency(current.income)} earned.');

    if (previous != null && previous.expense > 0) {
      final change = current.expense - previous.expense;
      final pct = (change / previous.expense * 100).abs().round();

      if (change > 0) {
        sb.writeln('Spending is up $pct% compared to last month '
            '(${AppFormat.currency(previous.expense)}).');
      } else if (change < 0) {
        sb.writeln('Spending is down $pct% compared to last month '
            '(${AppFormat.currency(previous.expense)}). Nice!');
      } else {
        sb.writeln('Spending is about the same as last month.');
      }
    }

    return sb.toString().trim();
  }

  // ── Savings Rate ─────────────────────────────────────────────────────

  Future<String> _handleSavingsRate() async {
    final stats = await _ref.read(currentMonthStatsProvider.future);
    if (stats == null || stats.income == 0) {
      return 'Can\'t calculate savings rate without income data this month.';
    }

    final rate = (stats.savingsRate * 100).round();
    final saved = stats.savings;

    final sb = StringBuffer();
    sb.writeln('Your savings rate this month is $rate%.');
    sb.writeln('You\'ve saved ${AppFormat.currency(saved)} out of '
        '${AppFormat.currency(stats.income)} income.');

    if (rate >= 30) {
      sb.writeln('Excellent! You\'re well above the 20% recommended rate.');
    } else if (rate >= 20) {
      sb.writeln('Good — you\'re meeting the recommended 20% savings target.');
    } else if (rate >= 0) {
      sb.writeln('Aim for 20-30% to build a stronger financial cushion.');
    } else {
      sb.writeln('You\'re spending more than you earn this month. Review expenses.');
    }

    return sb.toString().trim();
  }

  // ── Credit Cards ─────────────────────────────────────────────────────

  Future<String> _handleCreditCards() async {
    final cards = await _ref.read(creditCardsProvider.future);
    if (cards.isEmpty) {
      return 'You don\'t have any credit cards tracked.';
    }

    double totalOutstanding = 0;
    final lines = <String>[];
    for (final card in cards) {
      totalOutstanding += card.usedAmount;
      if (card.usedAmount > 0) {
        lines.add('${card.name}: ${AppFormat.currency(card.usedAmount)} outstanding');
      }
    }

    if (totalOutstanding == 0) {
      return 'All your credit cards have zero outstanding. Clean slate!';
    }

    final sb = StringBuffer();
    sb.writeln('Total credit card outstanding: ${AppFormat.currency(totalOutstanding)}');
    sb.writeln();
    for (final line in lines) {
      sb.writeln('  $line');
    }

    return sb.toString().trim();
  }

  // ── Credit Health ────────────────────────────────────────────────────

  Future<String> _handleCreditHealth() async {
    final health = await _ref.read(creditHealthProvider.future);
    if (health.totalOutstanding <= 0) {
      return 'All your credit cards have zero outstanding. No payments needed!';
    }

    final sb = StringBuffer();
    sb.writeln('Credit Card Summary:');
    sb.writeln('  Outstanding: ${AppFormat.currency(health.totalOutstanding)}');
    sb.writeln('  Available: ${AppFormat.currency(health.totalAvailable)}');
    sb.writeln('  Utilization: ${health.utilizationPct.round()}%');

    if (health.upcomingDues.isNotEmpty) {
      sb.writeln();
      final nearest = health.upcomingDues.first;
      sb.writeln('Next due: ${nearest.cardName} in ${nearest.daysUntilDue} days');
      sb.writeln('Minimum due: ${AppFormat.currency(nearest.minimumDue)}');
      sb.writeln('Full amount: ${AppFormat.currency(nearest.outstanding)}');
    }

    if (health.estimatedInterest > 0) {
      sb.writeln();
      sb.writeln('If unpaid, estimated interest: ${AppFormat.currency(health.estimatedInterest)}/month.');
      sb.writeln('Pay the full amount to avoid interest charges.');
    }

    return sb.toString().trim();
  }

  // ── EMI Load ─────────────────────────────────────────────────────────

  Future<String> _handleEmiLoad() async {
    final load = await _ref.read(emiLoadProvider.future);
    if (load.activeEmis.isEmpty) {
      return 'You have no active EMIs or loan installments.';
    }

    final sb = StringBuffer();
    sb.writeln('Your total monthly EMI: ${AppFormat.currency(load.totalMonthlyEmi)}');
    sb.writeln();
    for (final emi in load.activeEmis) {
      sb.writeln('  ${emi.name}: ${AppFormat.currency(emi.monthlyAmount)} '
          '(${emi.paidMonths}/${emi.totalMonths} months)');
    }

    return sb.toString().trim();
  }

  // ── Upcoming Dues ────────────────────────────────────────────────────

  Future<String> _handleUpcomingDues() async {
    final dues = await _ref.read(upcomingDuesProvider.future);
    if (dues.isEmpty) {
      return 'No card payments due in the next 7 days.';
    }

    final sb = StringBuffer();
    sb.writeln('Upcoming card dues (next 7 days):');
    for (final due in dues) {
      final urgency = due.daysUntilDue <= 2 ? ' [URGENT]' : '';
      sb.writeln('  ${due.cardName}: ${AppFormat.currency(due.minimumDue)} min due '
          'in ${due.daysUntilDue} days$urgency');
    }

    return sb.toString().trim();
  }

  // ── Debt Pressure ────────────────────────────────────────────────────

  Future<String> _handleDebtPressure() async {
    final pressure = await _ref.read(financialPressureProvider.future);

    if (pressure.monthlyObligations <= 0) {
      return 'You have no debt obligations. Financially healthy!';
    }

    final pct = (pressure.pressureRatio * 100).round();
    final sb = StringBuffer();

    switch (pressure.level) {
      case PressureLevel.healthy:
        sb.writeln('Your debt pressure is healthy at $pct%.');
        sb.writeln('Obligations: ${AppFormat.currency(pressure.monthlyObligations)} '
            'vs income: ${AppFormat.currency(pressure.monthlyIncome)}');
        sb.writeln('You have good room for savings and expenses.');
      case PressureLevel.moderate:
        sb.writeln('Your debt pressure is moderate at $pct%.');
        sb.writeln('Obligations: ${AppFormat.currency(pressure.monthlyObligations)} '
            'vs income: ${AppFormat.currency(pressure.monthlyIncome)}');
        sb.writeln('Consider paying off high-interest debt first.');
      case PressureLevel.high:
        sb.writeln('Your debt pressure is high at $pct%.');
        sb.writeln('Obligations: ${AppFormat.currency(pressure.monthlyObligations)} '
            'vs income: ${AppFormat.currency(pressure.monthlyIncome)}');
        sb.writeln('Prioritize debt reduction. Avoid new EMIs or credit spending.');
    }

    return sb.toString().trim();
  }

  // ── Health Score ─────────────────────────────────────────────────────

  Future<String> _handleHealthScore() async {
    final score = await _ref.read(financialHealthScoreProvider.future);

    final sb = StringBuffer();
    sb.writeln('Your financial health score is ${score.score}/100 (${score.level}).');
    sb.writeln();
    sb.writeln('Breakdown:');
    sb.writeln('  Savings: ${score.breakdown.savingsScore}/30');
    sb.writeln('  Debt: ${score.breakdown.debtScore}/25');
    sb.writeln('  Stability: ${score.breakdown.stabilityScore}/20');
    sb.writeln('  Liquidity: ${score.breakdown.liquidityScore}/15');
    sb.writeln('  Credit: ${score.breakdown.utilizationScore}/10');

    final actionable = score.insights
        .where((i) => i.type == HealthInsightType.actionable)
        .toList();
    if (actionable.isNotEmpty) {
      sb.writeln();
      sb.writeln('To improve your score:');
      for (final insight in actionable) {
        sb.writeln('  \u2022 ${insight.text}');
      }
    }

    return sb.toString().trim();
  }

  // ── Anomaly Check ────────────────────────────────────────────────────

  Future<String> _handleAnomalyCheck() async {
    final anomalies = await _ref.read(anomalyProvider.future);

    if (anomalies.isEmpty) {
      return 'No anomalies detected. Your finances look normal right now.';
    }

    final sb = StringBuffer();
    sb.writeln('I found ${anomalies.length} alert${anomalies.length > 1 ? 's' : ''}:');
    sb.writeln();

    for (var i = 0; i < anomalies.length && i < 5; i++) {
      final a = anomalies[i];
      final icon = a.severity == AnomalySeverity.high
          ? '\u26a0\ufe0f'
          : a.severity == AnomalySeverity.medium
              ? '\u26a0'
              : '\u2139\ufe0f';
      sb.writeln('$icon ${a.title}');
      if (a.suggestion != null) {
        sb.writeln('   \u2192 ${a.suggestion}');
      }
      sb.writeln();
    }

    return sb.toString().trim();
  }

  // ── Streak ───────────────────────────────────────────────────────────

  Future<String> _handleStreak() async {
    final streak = await _ref.read(streakProvider.future);

    if (streak.current == 0) {
      return streak.best > 0
          ? 'Your streak is at 0. Your best was ${streak.best} days. '
              'Log a transaction or stay within budget to start building again.'
          : 'No streak yet. Add a transaction today to start your first streak!';
    }

    final sb = StringBuffer();
    sb.writeln('You\'re on a ${streak.current}-day streak!');
    if (streak.milestoneMessage != null) {
      sb.writeln(streak.milestoneMessage);
    }
    sb.writeln('Best streak: ${streak.best} days.');

    if (streak.current < streak.best) {
      sb.writeln('${streak.best - streak.current} more days to beat your record.');
    } else {
      sb.writeln('You\'re at your all-time best!');
    }

    return sb.toString().trim();
  }

  // ── Budget ───────────────────────────────────────────────────────────

  Future<String> _handleBudget() async {
    final budgets = await _ref.read(smartBudgetProvider.future);
    if (budgets.isEmpty) {
      return 'Not enough spending history to generate budgets yet. '
          'Keep tracking for a few weeks.';
    }

    final over = budgets.where((b) => b.isOverBudget).toList();
    final sb = StringBuffer();

    if (over.isEmpty) {
      sb.writeln('All categories are within budget this month.');
    } else {
      sb.writeln('${over.length} categor${over.length == 1 ? 'y' : 'ies'} over budget:');
      for (final b in over) {
        final overBy = b.spent - b.limit;
        sb.writeln('  ${b.categoryName}: over by ${AppFormat.currency(overBy)}');
      }
    }

    sb.writeln();
    sb.writeln('Top budgets:');
    for (final b in budgets.take(3)) {
      sb.writeln('  ${b.categoryName}: ${AppFormat.currency(b.spent)} / ${AppFormat.currency(b.limit)}');
    }

    return sb.toString().trim();
  }

  // ── Runway ───────────────────────────────────────────────────────────

  Future<String> _handleRunway() async {
    final runway = await _ref.read(runwayProvider.future);

    final sb = StringBuffer();
    sb.writeln('You have ${runway.daysLeft} days of runway.');
    sb.writeln('Balance: ${AppFormat.currency(runway.totalBalance)}');
    sb.writeln('Daily burn: ${AppFormat.currency(runway.dailyBurn)}/day');

    switch (runway.status) {
      case RunwayStatus.critical:
        sb.writeln();
        sb.writeln('This is critical. Reduce spending immediately or ensure income arrives soon.');
      case RunwayStatus.warning:
        sb.writeln();
        sb.writeln('Getting tight. Consider cutting non-essential expenses.');
      case RunwayStatus.safe:
        sb.writeln();
        sb.writeln('You\'re in a comfortable position.');
    }

    return sb.toString().trim();
  }

  // ── Financial Advice (combined) ──────────────────────────────────────

  Future<String> _handleFinancialAdvice() async {
    final nudges = await _ref.read(smartNudgesProvider.future);
    final saveSug = await _ref.read(saveSuggestionProvider.future);

    if (nudges.isEmpty && saveSug == null) {
      return 'Everything looks good right now. Keep up your current habits!';
    }

    final sb = StringBuffer();
    sb.writeln('Here\'s what I recommend:');
    sb.writeln();

    if (saveSug != null) {
      sb.writeln('\u2022 Save ${AppFormat.currency(saveSug.amount)} this month');
    }

    for (final nudge in nudges) {
      final icon = nudge.priority == NudgePriority.critical
          ? '\u26a0\ufe0f'
          : '\u2022';
      sb.writeln('$icon ${nudge.title}: ${nudge.message}');
    }

    return sb.toString().trim();
  }

  // ── Forecast ─────────────────────────────────────────────────────────

  Future<String> _handleForecast() async {
    final f = await _ref.read(forecastProvider.future);

    final sb = StringBuffer();
    sb.writeln('Next month forecast (${f.confidenceLabel} confidence):');
    sb.writeln('  Income: ${AppFormat.currency(f.predictedIncome)}');
    sb.writeln('  Expenses: ${AppFormat.currency(f.predictedExpense)}');
    sb.writeln('  Savings: ${AppFormat.currency(f.predictedSavings)}');
    sb.writeln('  End balance: ${AppFormat.currency(f.predictedBalance)}');

    return sb.toString().trim();
  }

  // ── Progress / XP ────────────────────────────────────────────────────

  Future<String> _handleProgress() async {
    final xp = await _ref.read(xpProvider.future);

    final sb = StringBuffer();
    sb.writeln('You\'re Level ${xp.level} (${xp.levelName})');
    sb.writeln('XP: ${xp.xp} / ${xp.xpForNextLevel}');
    sb.writeln('${xp.xpForNextLevel - xp.xp} XP to reach Level ${xp.level + 1}.');

    return sb.toString().trim();
  }

  // ── Can I Afford / Scenario ──────────────────────────────────────────

  Future<String> _handleCanIAfford(String input) async {
    // Try to extract amount from the query
    final amountMatch = RegExp(r'(\d[\d,]*(?:\.\d{1,2})?)').firstMatch(input);
    final amount = amountMatch != null
        ? double.tryParse(amountMatch.group(1)!.replaceAll(',', ''))
        : null;

    final runway = await _ref.read(runwayProvider.future);
    final accounts = await _ref.read(accountsProvider.future);
    final balance = accounts
        .where((a) => a.isAsset)
        .fold<double>(0, (sum, a) => sum + a.balance);

    if (amount == null) {
      return 'Tell me the amount — e.g., "Can I afford 50000?"'
          '\n\nYour current balance is ${AppFormat.currency(balance)} '
          'with ${runway.daysLeft} days of runway.';
    }

    final afterBalance = balance - amount;
    final afterRunway = runway.dailyBurn > 0
        ? (afterBalance / runway.dailyBurn).floor().clamp(0, 365)
        : 0;

    final sb = StringBuffer();
    sb.writeln('If you spend ${AppFormat.currency(amount)}:');
    sb.writeln();
    sb.writeln('Balance: ${AppFormat.currency(balance)} → ${AppFormat.currency(afterBalance)}');
    sb.writeln('Runway: ${runway.daysLeft} days → $afterRunway days');

    if (afterBalance < 0) {
      sb.writeln();
      sb.writeln('You don\'t have enough funds for this purchase.');
    } else if (afterRunway < 7) {
      sb.writeln();
      sb.writeln('This would leave you with dangerously low runway. '
          'Consider waiting or saving more first.');
    } else if (afterRunway < 15) {
      sb.writeln();
      sb.writeln('Possible but tight. You\'d have less than 2 weeks of buffer.');
    } else {
      sb.writeln();
      sb.writeln('You can afford this comfortably.');
    }

    // Monthly savings check
    final stats = await _ref.read(currentMonthStatsProvider.future);
    if (stats != null && stats.income > 0 && amount > stats.income * 0.5) {
      final monthsToSave = (amount / (stats.savings > 0 ? stats.savings : stats.income * 0.2)).ceil();
      sb.writeln();
      sb.writeln('Alternative: save for $monthsToSave months to buy without impacting runway.');
    }

    return sb.toString().trim();
  }

  // ── Income Stability ─────────────────────────────────────────────────

  Future<String> _handleIncomeStability() async {
    final intel = await _ref.read(incomeStabilityProvider.future);
    final sb = StringBuffer();
    sb.writeln('Income Stability: ${intel.stabilityScore.round()}/100 (${intel.level.name})');
    sb.writeln('Average monthly income: ${AppFormat.currency(intel.avgIncome)}');
    if (intel.level == IncomeStabilityLevel.stable) {
      sb.writeln('Your income is consistent — great for planning.');
    } else if (intel.level == IncomeStabilityLevel.unstable) {
      sb.writeln('Your income varies significantly. Build a larger emergency fund.');
    }
    return sb.toString().trim();
  }

  // ── Salary Prediction ────────────────────────────────────────────────

  Future<String> _handleSalaryPrediction() async {
    final pred = await _ref.read(salaryPredictionProvider.future);
    if (pred.expectedAmount <= 0) {
      return 'Not enough salary data to make a prediction yet.';
    }
    final sb = StringBuffer();
    sb.writeln('Next salary prediction:');
    sb.writeln('Amount: ${AppFormat.currency(pred.expectedAmount)}');
    sb.writeln('Expected around: ${AppFormat.date(pred.expectedDate)}');
    sb.writeln('Confidence: ${pred.confidenceLabel}');
    return sb.toString().trim();
  }
}

/// Provider for the AI data bridge.
final aiDataBridgeProvider = Provider<AIDataBridge>((ref) {
  return AIDataBridge(ref);
});
