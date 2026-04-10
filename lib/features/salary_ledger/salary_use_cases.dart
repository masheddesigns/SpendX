import 'package:flutter/foundation.dart' show compute, debugPrint;

import '../../models/company.dart';
import 'salary_ledger_models.dart';
import 'salary_ledger_repo.dart';

/// Application-layer use case for loading a company's salary dashboard.
/// Sits between Notifier (presentation) and Repo (data).
/// All heavy logic lives here, keeping the notifier thin.
class GetCompanyDashboard {
  final SalaryLedgerRepo repo;

  GetCompanyDashboard(this.repo);

  Future<CompanyDashboardResult> execute(String companyId) async {
    final months = await repo.getByCompany(companyId);
    final views = <SalaryMonthView>[];

    for (final month in months) {
      final payments = await repo.getPayments(month.id);
      views.add(buildMonthView(month, payments));
    }

    // Move heavy computation off the main thread when there are many months
    if (views.length > 24) {
      return compute(_computeDashboardStats, views);
    }

    return CompanyDashboardResult(
      months: views,
      report: generateReport(views),
      health: computeCompanyHealth(views),
    );
  }
}

// Top-level function required by compute() — must not be a closure.
CompanyDashboardResult _computeDashboardStats(List<SalaryMonthView> views) {
  return CompanyDashboardResult(
    months: views,
    report: generateReport(views),
    health: computeCompanyHealth(views),
  );
}

/// Result of loading a company dashboard — pure data, no side effects.
class CompanyDashboardResult {
  final List<SalaryMonthView> months;
  final SalaryReport report;
  final CompanyHealth health;

  const CompanyDashboardResult({
    required this.months,
    required this.report,
    required this.health,
  });
}

/// Use case: load all companies.
class GetCompanies {
  final SalaryLedgerRepo repo;

  GetCompanies(this.repo);

  Future<List<Company>> execute() async {
    final maps = await repo.getCompanies();
    return maps.map(Company.fromMap).toList();
  }
}

/// Use case: update salary (hike) — creates new contract + updates future months.
class UpdateSalary {
  final SalaryLedgerRepo repo;

  UpdateSalary(this.repo);

  /// Creates a new salary contract effective from [effectiveFrom].
  /// Updates expectedAmount on all unpaid months from that date forward.
  /// Does NOT touch months that already have payments (preserves history).
  Future<void> execute({
    required String companyId,
    required double newSalary,
    required DateTime effectiveFrom,
  }) async {
    if (newSalary <= 0) throw ArgumentError('Salary must be positive');

    // Create the new contract
    await repo.insertContract(SalaryContract(
      companyId: companyId,
      baseSalary: newSalary,
      startDate: effectiveFrom,
    ));

    // Update future months that have no payments yet
    final months = await repo.getByCompany(companyId);
    for (final month in months) {
      if (month.dueDate.isBefore(effectiveFrom)) continue;
      final payments = await repo.getPayments(month.id);
      if (payments.isEmpty) {
        // Safe to update — no payments recorded yet
        await repo.updateMonthExpectedAmount(month.id, newSalary);
      }
    }
  }
}

/// Use case: setup a new company with auto-generated months.
class SetupCompany {
  final SalaryLedgerRepo repo;

  SetupCompany(this.repo);

  Future<String> execute({
    required String companyName,
    required double expectedSalary,
    required int payDay,
    required DateTime startFrom,
    EmploymentType employmentType = EmploymentType.fullTime,
    PayCycle payCycle = PayCycle.monthly,
  }) async {
    final company = Company(
      name: companyName,
      salaryCreditDay: payDay,
      employmentType: employmentType,
      payCycle: payCycle,
      createdAt: startFrom,
    );
    await repo.insertCompany(company.toMap());

    final isFlexible = company.isFlexibleCycle;

    // Create initial salary contract
    // baseSalary = rate per cycle (monthly amount, weekly rate, daily rate, etc.)
    try {
      final contract = SalaryContract(
        companyId: company.id,
        baseSalary: expectedSalary,
        startDate: startFrom,
      );
      await repo.insertContract(contract);
    } catch (e) {
      debugPrint('⚠️ Contract insert failed (non-fatal): $e');
    }

    // Generate month containers
    final now = DateTime.now();
    var cursor = DateTime(startFrom.year, startFrom.month, 1);

    // Flexible cycles (daily, perProject): only current + 1 past month
    // Fixed cycles (monthly, weekly, biWeekly): all months from start
    if (isFlexible) {
      final flexStart = DateTime(now.year, now.month - 1, 1);
      if (cursor.isBefore(flexStart)) cursor = flexStart;
    }

    while (!cursor.isAfter(DateTime(now.year, now.month, 1))) {
      final monthKey =
          '${cursor.year}-${cursor.month.toString().padLeft(2, '0')}';
      final existing =
          await repo.getMonthByKey(monthKey, companyId: company.id);

      if (existing == null) {
        final nextMonth = DateTime(cursor.year, cursor.month + 1, 1);
        final safePay = payDay.clamp(1, 28);

        // Calculate expected amount based on pay cycle
        final monthExpected = expectedAmountForMonth(
          expectedSalary, payCycle, cursor,
        );

        await repo.insertMonth(SalaryMonth(
          companyId: company.id,
          month: monthKey,
          expectedAmount: monthExpected,
          dueDate: isFlexible
              ? DateTime(nextMonth.year, nextMonth.month, 1)
              : DateTime(nextMonth.year, nextMonth.month, safePay),
        ));
      }

      cursor = DateTime(cursor.year, cursor.month + 1, 1);
    }

    return company.id;
  }
}
