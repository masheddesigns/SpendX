import 'package:flutter/material.dart' show DateTimeRange;
import 'package:uuid/uuid.dart';

import '../../models/company.dart';

// ── Salary Status ────────────────────────────────────────────────────────

enum SalaryStatus { paid, partial, pending, onHold, overdue }

extension SalaryStatusX on SalaryStatus {
  String get label {
    switch (this) {
      case SalaryStatus.paid:
        return 'Paid';
      case SalaryStatus.partial:
        return 'Partial';
      case SalaryStatus.pending:
        return 'Pending';
      case SalaryStatus.onHold:
        return 'On Hold';
      case SalaryStatus.overdue:
        return 'Overdue';
    }
  }
}

// ── Salary Month ─────────────────────────────────────────────────────────

class SalaryMonth {
  final String id;
  final String companyId;
  final String month; // "2026-03"
  final double expectedAmount;
  final DateTime dueDate;
  final bool isOnHold;
  final DateTime createdAt;

  SalaryMonth({
    String? id,
    required this.companyId,
    required this.month,
    required this.expectedAmount,
    required this.dueDate,
    this.isOnHold = false,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'company_id': companyId,
        'month': month,
        'expected_amount': expectedAmount,
        'due_date': dueDate.toIso8601String(),
        'is_on_hold': isOnHold ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory SalaryMonth.fromMap(Map<String, dynamic> m) => SalaryMonth(
        id: m['id'] as String,
        companyId: m['company_id'] as String? ?? '',
        month: m['month'] as String,
        expectedAmount: (m['expected_amount'] as num).toDouble(),
        dueDate: DateTime.parse(m['due_date'] as String),
        isOnHold: (m['is_on_hold'] as int?) == 1,
        createdAt: m['created_at'] != null
            ? DateTime.parse(m['created_at'] as String)
            : DateTime.now(),
      );
}

// ── Ledger Entry (single source of truth for all payments) ──────────────

enum PaymentType { salary, bonus, adjustment }

class SalaryLedgerEntry {
  final String id;
  final String monthId;
  final double amount;
  final PaymentType type;
  final DateTime paidDate;
  final String? note;

  SalaryLedgerEntry({
    String? id,
    required this.monthId,
    required this.amount,
    required this.type,
    required this.paidDate,
    this.note,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toMap() => {
        'id': id,
        'month_id': monthId,
        'amount': amount,
        'type': type.name,
        'paid_date': paidDate.toIso8601String(),
        'note': note,
      };

  factory SalaryLedgerEntry.fromMap(Map<String, dynamic> m) =>
      SalaryLedgerEntry(
        id: m['id'] as String,
        monthId: m['month_id'] as String,
        amount: (m['amount'] as num).toDouble(),
        type: PaymentType.values.firstWhere(
          (e) => e.name == (m['type'] as String? ?? 'salary'),
          orElse: () => PaymentType.salary,
        ),
        paidDate: DateTime.parse(m['paid_date'] as String),
        note: m['note'] as String?,
      );
}

// ── Salary Contract (tracks salary structure changes / hikes) ────────────

class SalaryContract {
  final String id;
  final String companyId;
  final double baseSalary;
  final DateTime startDate; // effective from this date
  final String? defaultAccountId;
  final bool isActive;
  final DateTime createdAt;

  SalaryContract({
    String? id,
    required this.companyId,
    required this.baseSalary,
    required this.startDate,
    this.defaultAccountId,
    this.isActive = true,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'company_id': companyId,
        'base_salary': baseSalary,
        'start_date': startDate.toIso8601String(),
        'default_account_id': defaultAccountId,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory SalaryContract.fromMap(Map<String, dynamic> m) => SalaryContract(
        id: m['id'] as String,
        companyId: m['company_id'] as String,
        baseSalary: (m['base_salary'] as num).toDouble(),
        startDate: DateTime.parse(m['start_date'] as String),
        defaultAccountId: m['default_account_id'] as String?,
        isActive: (m['is_active'] as int?) == 1,
        createdAt: m['created_at'] != null
            ? DateTime.parse(m['created_at'] as String)
            : DateTime.now(),
      );
}

/// Given a list of contracts (sorted by startDate ascending),
/// return the salary amount that applies to a given month.
double salaryForMonth(List<SalaryContract> contracts, DateTime monthDate) {
  if (contracts.isEmpty) return 0;
  SalaryContract? applicable;
  for (final c in contracts) {
    if (!c.startDate.isAfter(monthDate)) {
      applicable = c;
    }
  }
  return applicable?.baseSalary ?? contracts.first.baseSalary;
}

// ── Derived View (computed from ledger, never stored) ────────────────────

class SalaryMonthView {
  final SalaryMonth month;
  final List<SalaryLedgerEntry> payments;
  final double totalPaid;
  final double salaryPaid;
  final double bonusTotal;
  final double remaining;
  final SalaryStatus status;
  final int delayDays; // 0 if on time or not yet due

  const SalaryMonthView({
    required this.month,
    required this.payments,
    required this.totalPaid,
    required this.salaryPaid,
    required this.bonusTotal,
    required this.remaining,
    required this.status,
    this.delayDays = 0,
  });
}

// ── Report (computed, never stored) ──────────────────────────────────────

class SalaryReport {
  final double totalExpected;
  final double totalPaid;
  final double totalBonus;
  final double pending;
  final double avgDelay;
  final int delayedCount;
  final int paidCount;
  final int partialCount;
  final int pendingCount;
  final int onHoldCount;
  final int overdueCount;

  const SalaryReport({
    required this.totalExpected,
    required this.totalPaid,
    required this.totalBonus,
    required this.pending,
    required this.avgDelay,
    required this.delayedCount,
    required this.paidCount,
    required this.partialCount,
    required this.pendingCount,
    this.onHoldCount = 0,
    this.overdueCount = 0,
  });

  static const empty = SalaryReport(
    totalExpected: 0,
    totalPaid: 0,
    totalBonus: 0,
    pending: 0,
    avgDelay: 0,
    delayedCount: 0,
    paidCount: 0,
    partialCount: 0,
    pendingCount: 0,
  );
}

// ── Company Health / Reliability (computed, never stored) ────────────────

class CompanyHealth {
  final double reliabilityScore; // 0-100
  final int avgDelayDays;
  final int lateMonths;
  final int onTimeMonths;
  final int totalMonths;
  final int longestDelayStreak;
  final double onTimePercent;

  const CompanyHealth({
    required this.reliabilityScore,
    required this.avgDelayDays,
    required this.lateMonths,
    required this.onTimeMonths,
    required this.totalMonths,
    required this.longestDelayStreak,
    required this.onTimePercent,
  });

  static const empty = CompanyHealth(
    reliabilityScore: 0,
    avgDelayDays: 0,
    lateMonths: 0,
    onTimeMonths: 0,
    totalMonths: 0,
    longestDelayStreak: 0,
    onTimePercent: 0,
  );
}

// ── Filter Model ─────────────────────────────────────────────────────────

class SalaryFilter {
  final SalaryStatus? status;
  final int? year;
  final FinancialYear? fy;
  final DateTimeRange? customRange;

  const SalaryFilter({this.status, this.year, this.fy, this.customRange});

  static const empty = SalaryFilter();

  bool get isActive =>
      status != null || year != null || fy != null || customRange != null;

  SalaryFilter copyWith({
    SalaryStatus? status,
    int? year,
    FinancialYear? fy,
    DateTimeRange? customRange,
    bool clearStatus = false,
    bool clearYear = false,
    bool clearFY = false,
    bool clearRange = false,
  }) {
    return SalaryFilter(
      status: clearStatus ? null : (status ?? this.status),
      year: clearYear ? null : (year ?? this.year),
      fy: clearFY ? null : (fy ?? this.fy),
      customRange: clearRange ? null : (customRange ?? this.customRange),
    );
  }
}

// ── Financial Year (Indian Apr-Mar) ──────────────────────────────────────

class FinancialYear {
  final int startYear;
  final DateTime start;
  final DateTime end;

  FinancialYear(this.startYear)
      : start = DateTime(startYear, 4, 1),
        end = DateTime(startYear + 1, 3, 31, 23, 59, 59);

  factory FinancialYear.current() {
    final now = DateTime.now();
    return FinancialYear(now.month >= 4 ? now.year : now.year - 1);
  }

  String get label => 'FY $startYear-${(startYear + 1) % 100}';

  bool contains(DateTime date) =>
      !date.isBefore(start) && !date.isAfter(end);

  static int yearFor(DateTime date) =>
      date.month >= 4 ? date.year : date.year - 1;

  @override
  bool operator ==(Object other) =>
      other is FinancialYear && other.startYear == startYear;

  @override
  int get hashCode => startYear.hashCode;
}

// =========================================================================
// PURE COMPUTATION ENGINE (no DB, no async, no state)
// =========================================================================

/// Calculate expected monthly amount from a rate and pay cycle. Pure.
double expectedAmountForMonth(double rate, PayCycle cycle, DateTime month) {
  switch (cycle) {
    case PayCycle.monthly:
      return rate;
    case PayCycle.weekly:
      return rate * _weeksInMonth(month);
    case PayCycle.biWeekly:
      return rate * (_weeksInMonth(month) / 2);
    case PayCycle.daily:
      return rate * _workingDaysInMonth(month);
    case PayCycle.perProject:
      return 0; // No fixed expectation — track as they come
  }
}

/// Number of weeks (fractional) in a given month.
double _weeksInMonth(DateTime month) {
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  return daysInMonth / 7.0;
}

/// Number of working days (Mon-Fri) in a given month.
int _workingDaysInMonth(DateTime month) {
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  int count = 0;
  for (int d = 1; d <= daysInMonth; d++) {
    final weekday = DateTime(month.year, month.month, d).weekday;
    if (weekday <= 5) count++; // Mon=1 .. Fri=5
  }
  return count;
}

/// Derives status from amounts + hold/due state. Pure.
SalaryStatus computeStatus({
  required double expectedAmount,
  required double salaryPaid,
  bool isOnHold = false,
  DateTime? dueDate,
}) {
  // On hold takes priority (user-flagged)
  if (isOnHold) return SalaryStatus.onHold;

  // Freelance/no-target: expected is 0
  if (expectedAmount <= 0) {
    return salaryPaid > 0 ? SalaryStatus.paid : SalaryStatus.pending;
  }
  if (salaryPaid >= expectedAmount) return SalaryStatus.paid;
  if (salaryPaid > 0 && salaryPaid < expectedAmount) return SalaryStatus.partial;

  // Overdue: past due date with no/insufficient payment
  if (dueDate != null && DateTime.now().isAfter(dueDate)) {
    return SalaryStatus.overdue;
  }

  return SalaryStatus.pending;
}

/// Build a SalaryMonthView from raw data. Pure.
SalaryMonthView buildMonthView(
    SalaryMonth month, List<SalaryLedgerEntry> payments) {
  double salaryPaid = 0;
  double bonusTotal = 0;

  for (final p in payments) {
    if (p.type == PaymentType.bonus) {
      bonusTotal += p.amount;
    } else {
      salaryPaid += p.amount;
    }
  }

  final status = computeStatus(
    expectedAmount: month.expectedAmount,
    salaryPaid: salaryPaid,
    isOnHold: month.isOnHold,
    dueDate: month.dueDate,
  );

  // Compute delay: days between dueDate and first salary payment (or now if pending)
  int delayDays = 0;
  final now = DateTime.now();
  if (now.isAfter(month.dueDate) && !month.isOnHold) {
    final salaryPayments =
        payments.where((p) => p.type != PaymentType.bonus).toList();
    if (salaryPayments.isEmpty) {
      delayDays = now.difference(month.dueDate).inDays;
    } else {
      salaryPayments.sort((a, b) => a.paidDate.compareTo(b.paidDate));
      final firstPaid = salaryPayments.first.paidDate;
      if (firstPaid.isAfter(month.dueDate)) {
        delayDays = firstPaid.difference(month.dueDate).inDays;
      }
    }
  }

  return SalaryMonthView(
    month: month,
    payments: payments,
    totalPaid: salaryPaid + bonusTotal,
    salaryPaid: salaryPaid,
    bonusTotal: bonusTotal,
    remaining: (month.expectedAmount - salaryPaid).clamp(0.0, double.infinity),
    status: status,
    delayDays: delayDays,
  );
}

/// Generate a report from views. Pure.
SalaryReport generateReport(List<SalaryMonthView> views) {
  double totalExpected = 0;
  double totalPaid = 0;
  double totalBonus = 0;
  double totalDelay = 0;
  int delayed = 0;
  int paid = 0;
  int partial = 0;
  int pending = 0;
  int onHold = 0;
  int overdue = 0;

  for (final v in views) {
    totalExpected += v.month.expectedAmount;
    totalPaid += v.salaryPaid;
    totalBonus += v.bonusTotal;

    if (v.delayDays > 0) {
      delayed++;
      totalDelay += v.delayDays;
    }

    switch (v.status) {
      case SalaryStatus.paid:
        paid++;
      case SalaryStatus.partial:
        partial++;
      case SalaryStatus.pending:
        pending++;
      case SalaryStatus.onHold:
        onHold++;
      case SalaryStatus.overdue:
        overdue++;
    }
  }

  return SalaryReport(
    totalExpected: totalExpected,
    totalPaid: totalPaid,
    totalBonus: totalBonus,
    pending: (totalExpected - totalPaid).clamp(0.0, double.infinity),
    avgDelay: delayed == 0 ? 0 : totalDelay / delayed,
    delayedCount: delayed,
    paidCount: paid,
    partialCount: partial,
    pendingCount: pending,
    onHoldCount: onHold,
    overdueCount: overdue,
  );
}

/// Compute employer reliability metrics. Pure.
/// On-hold months are excluded from scoring.
CompanyHealth computeCompanyHealth(List<SalaryMonthView> views) {
  // Exclude on-hold months from reliability calculation
  final scorable = views.where((v) => v.status != SalaryStatus.onHold).toList();
  if (scorable.isEmpty) return CompanyHealth.empty;

  int lateMonths = 0;
  int onTimeMonths = 0;
  double totalDelay = 0;
  int longestStreak = 0;
  int currentStreak = 0;

  final sorted = List<SalaryMonthView>.from(scorable)
    ..sort((a, b) => a.month.month.compareTo(b.month.month));

  for (final v in sorted) {
    if (v.delayDays > 0) {
      lateMonths++;
      totalDelay += v.delayDays;
      currentStreak++;
      if (currentStreak > longestStreak) {
        longestStreak = currentStreak;
      }
    } else if (v.status == SalaryStatus.paid) {
      onTimeMonths++;
      currentStreak = 0;
    }
  }

  final total = scorable.length;
  final onTimePct = total > 0 ? (onTimeMonths / total) * 100 : 0.0;

  final onTimeScore = onTimePct * 0.6;
  final avgDel = lateMonths > 0 ? totalDelay / lateMonths : 0.0;
  final delayPenalty = (1 - (avgDel / 30).clamp(0.0, 1.0)) * 20;
  final streakPenalty = (1 - (longestStreak / 6).clamp(0.0, 1.0)) * 20;
  final score = (onTimeScore + delayPenalty + streakPenalty).clamp(0.0, 100.0);

  return CompanyHealth(
    reliabilityScore: score,
    avgDelayDays: lateMonths > 0 ? (totalDelay / lateMonths).round() : 0,
    lateMonths: lateMonths,
    onTimeMonths: onTimeMonths,
    totalMonths: total,
    longestDelayStreak: longestStreak,
    onTimePercent: onTimePct,
  );
}

/// Apply filter to month views. Pure.
List<SalaryMonthView> applyFilter(
    List<SalaryMonthView> data, SalaryFilter filter) {
  return data.where((m) {
    if (filter.status != null && m.status != filter.status) return false;
    if (filter.year != null && m.month.dueDate.year != filter.year) {
      return false;
    }
    if (filter.fy != null && !filter.fy!.contains(m.month.dueDate)) {
      return false;
    }
    if (filter.customRange != null) {
      final d = m.month.dueDate;
      if (d.isBefore(filter.customRange!.start) ||
          d.isAfter(filter.customRange!.end)) {
        return false;
      }
    }
    return true;
  }).toList();
}

/// Generate CSV export string. Pure.
String generateSalaryCSV(List<SalaryMonthView> months,
    {String? companyName}) {
  final header = companyName != null ? '$companyName Salary Report\n\n' : '';
  final rows = <String>[
    'Month,Expected,Salary Paid,Bonus,Total,Remaining,Status,Delay Days',
    ...months.map((m) =>
        '${m.month.month},${m.month.expectedAmount},${m.salaryPaid},'
        '${m.bonusTotal},${m.totalPaid},${m.remaining},'
        '${m.status.label},${m.delayDays}'),
  ];
  return '$header${rows.join('\n')}';
}
