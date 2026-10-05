import 'money.dart';

/// Confidence classification for cashflow forecasts and commitments.
enum ForecastConfidence {
  high,
  medium,
  low;

  String get label => switch (this) {
    ForecastConfidence.high => 'High',
    ForecastConfidence.medium => 'Medium',
    ForecastConfidence.low => 'Low',
  };
}

/// Traceable confidence tier for forecast inputs according to C6 contract.
enum ForecastConfidenceTier {
  /// Tier 1: Real posted transaction in canonical ledger
  actual,
  /// Tier 2: Active loan EMI or contractual subscription with fixed due date
  contractual,
  /// Tier 3: Salary contract or recurring bill with minor timing variance
  expected,
  /// Tier 4: Statistical median daily discretionary spend
  estimated,
  /// Tier 5: Transient scenario parameter
  scenario,
}

/// Represents a single day in the forward projection horizon.
class ForecastDayPoint {
  final DateTime date;
  final Money projectedLiquidBalance;
  final Money inflows;
  final Money outflows;
  final Money commitments;
  final Money discretionary;

  const ForecastDayPoint({
    required this.date,
    required this.projectedLiquidBalance,
    required this.inflows,
    required this.outflows,
    required this.commitments,
    required this.discretionary,
  });

  Map<String, dynamic> toMap() => {
    'date': date.toIso8601String(),
    'projectedLiquidBalance': projectedLiquidBalance.minorUnits,
    'inflows': inflows.minorUnits,
    'outflows': outflows.minorUnits,
    'commitments': commitments.minorUnits,
    'discretionary': discretionary.minorUnits,
  };
}

/// Authoritative canonical cashflow forecast model for SpendX 2.0.
///
/// Pure Dart immutable entity representing forward cashflow projections
/// over 30, 60, or 90 days. Uses signed 64-bit integer paise ([Money]) throughout.
class CashflowForecast {
  final DateTime generatedAt;
  final int horizonDays;
  final Money startingLiquidBalance;
  final Money projectedIncome;
  final Money projectedCommittedExpenses;
  final Money projectedDiscretionaryExpenses;
  final Money projectedEndingBalance;
  final Money projectedSavings;
  final List<ForecastDayPoint> dailyPoints;
  final ForecastConfidence confidence;
  final String confidenceLabel;
  final DateTime? shortfallDate;
  final Money minimumProjectedBalance;
  final int runwayDays;
  final Money dailyBurnRate;

  const CashflowForecast({
    required this.generatedAt,
    required this.horizonDays,
    required this.startingLiquidBalance,
    required this.projectedIncome,
    required this.projectedCommittedExpenses,
    required this.projectedDiscretionaryExpenses,
    required this.projectedEndingBalance,
    required this.projectedSavings,
    required this.dailyPoints,
    required this.confidence,
    required this.confidenceLabel,
    this.shortfallDate,
    required this.minimumProjectedBalance,
    required this.runwayDays,
    required this.dailyBurnRate,
  });

  /// Total projected expenses = commitments + discretionary burn.
  Money get projectedTotalExpense =>
      projectedCommittedExpenses + projectedDiscretionaryExpenses;

  /// Whether the projection identifies any deficit / shortfall within horizon.
  bool get hasShortfall => shortfallDate != null;

  /// Compatibility getters for legacy callers.
  double get predictedIncome => projectedIncome.asRupees;
  double get predictedExpense => projectedTotalExpense.asRupees;
  double get predictedBalance => projectedEndingBalance.asRupees;
  double get predictedSavings => projectedSavings.asRupees;
}

/// Represents a recurring rule recorded in [TablesV24.recurringRules].
class RecurringRule {
  final String id;
  final String title;
  final String? categoryAccountId;
  final String? targetAccountId;
  final Money amount;
  final String cadence; // daily, weekly, monthly, quarterly, yearly
  final int? dayOfMonth;
  final int? dayOfWeek;
  final DateTime nextDueDate;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RecurringRule({
    required this.id,
    required this.title,
    this.categoryAccountId,
    this.targetAccountId,
    required this.amount,
    required this.cadence,
    this.dayOfMonth,
    this.dayOfWeek,
    required this.nextDueDate,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'category_account_id': categoryAccountId,
    'target_account_id': targetAccountId,
    'amount_minor_units': amount.minorUnits,
    'cadence': cadence,
    'day_of_month': dayOfMonth,
    'day_of_week': dayOfWeek,
    'next_due_date': nextDueDate.toIso8601String(),
    'is_active': isActive ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory RecurringRule.fromMap(Map<String, dynamic> map, {String currency = 'INR'}) {
    return RecurringRule(
      id: map['id'] as String,
      title: map['title'] as String,
      categoryAccountId: map['category_account_id'] as String?,
      targetAccountId: map['target_account_id'] as String?,
      amount: Money.fromMinorUnits((map['amount_minor_units'] as num).toInt(), currency: currency),
      cadence: map['cadence'] as String,
      dayOfMonth: map['day_of_month'] as int?,
      dayOfWeek: map['day_of_week'] as int?,
      nextDueDate: DateTime.parse(map['next_due_date'] as String),
      isActive: (map['is_active'] as int?) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}

/// Represents a scheduled expected event recorded in [TablesV24.expectedEvents].
class ExpectedEvent {
  final String id;
  final String? ruleId;
  final DateTime dueDate;
  final Money amount;
  final String status; // pending, fulfilled, overdue, dismissed
  final String? fulfilledEventId;
  final DateTime createdAt;

  const ExpectedEvent({
    required this.id,
    this.ruleId,
    required this.dueDate,
    required this.amount,
    this.status = 'pending',
    this.fulfilledEventId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'rule_id': ruleId,
    'due_date': dueDate.toIso8601String(),
    'amount_minor_units': amount.minorUnits,
    'status': status,
    'fulfilled_event_id': fulfilledEventId,
    'created_at': createdAt.toIso8601String(),
  };

  factory ExpectedEvent.fromMap(Map<String, dynamic> map, {String currency = 'INR'}) {
    return ExpectedEvent(
      id: map['id'] as String,
      ruleId: map['rule_id'] as String?,
      dueDate: DateTime.parse(map['due_date'] as String),
      amount: Money.fromMinorUnits((map['amount_minor_units'] as num).toInt(), currency: currency),
      status: map['status'] as String? ?? 'pending',
      fulfilledEventId: map['fulfilled_event_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
