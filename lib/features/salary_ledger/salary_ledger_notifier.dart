import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/company.dart';
import 'salary_ledger_models.dart';
import 'salary_ledger_repo.dart';
import 'salary_use_cases.dart';

// ── Input DTO ────────────────────────────────────────────────────────────

class SetupSalaryInput {
  final String companyName;
  final double salary;
  final int payDay;
  final String startMonth; // "2026-01"
  final EmploymentType employmentType;
  final PayCycle payCycle;

  SetupSalaryInput({
    required this.companyName,
    required this.salary,
    required this.payDay,
    required this.startMonth,
    this.employmentType = EmploymentType.fullTime,
    this.payCycle = PayCycle.monthly,
  });
}

// ── State ────────────────────────────────────────────────────────────────

class SalaryLedgerState {
  final List<Company> companies;
  final String? selectedCompanyId;
  final List<SalaryMonthView> months;
  final SalaryReport report;
  final CompanyHealth health;

  const SalaryLedgerState({
    this.companies = const [],
    this.selectedCompanyId,
    this.months = const [],
    this.report = SalaryReport.empty,
    this.health = CompanyHealth.empty,
  });

  bool get hasCompanies => companies.isNotEmpty;
  bool get hasMonths => months.isNotEmpty;

  Company? get selectedCompany =>
      companies.where((c) => c.id == selectedCompanyId).firstOrNull;

  SalaryMonthView? get currentMonth {
    final now = DateTime.now();
    final key = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    return months.where((m) => m.month.month == key).firstOrNull;
  }
}

// ── Providers ────────────────────────────────────────────────────────────

final salaryLedgerRepoProvider = Provider<SalaryLedgerRepo>(
  (ref) => SalaryLedgerRepo(),
);

final salaryLedgerProvider =
    AsyncNotifierProvider<SalaryLedgerNotifier, SalaryLedgerState>(
  SalaryLedgerNotifier.new,
);

/// Active filter state.
final salaryFilterProvider =
    StateProvider<SalaryFilter>((ref) => const SalaryFilter());

/// Derived: filtered months.
final filteredSalaryMonthsProvider = Provider<List<SalaryMonthView>>((ref) {
  final state = ref.watch(salaryLedgerProvider).valueOrNull;
  if (state == null) return [];
  final filter = ref.watch(salaryFilterProvider);
  if (!filter.isActive) return state.months;
  return applyFilter(state.months, filter);
});

/// Derived: report from filtered months.
final salaryReportProvider = Provider<SalaryReport>((ref) {
  final months = ref.watch(filteredSalaryMonthsProvider);
  return generateReport(months);
});

/// Derived: company health from ALL months (not filtered).
final companyHealthProvider = Provider<CompanyHealth>((ref) {
  final state = ref.watch(salaryLedgerProvider).valueOrNull;
  if (state == null) return CompanyHealth.empty;
  return state.health;
});

/// Status filter shortcut (for backward compat).
final salaryStatusFilterProvider =
    StateProvider<SalaryStatus?>((ref) => null);

/// FY filter shortcut (for backward compat).
final selectedFYProvider =
    StateProvider<FinancialYear>((ref) => FinancialYear.current());

// ── Notifier (thin — delegates to use-cases) ────────────────────────────

class SalaryLedgerNotifier extends AsyncNotifier<SalaryLedgerState> {
  @override
  Future<SalaryLedgerState> build() async {
    try {
      return await _load(null);
    } catch (e, st) {
      Error.throwWithStackTrace(e, st);
    }
  }

  SalaryLedgerRepo get _repo => ref.read(salaryLedgerRepoProvider);

  // ── Core Load (via use-case) ────────────────────────────────

  Future<SalaryLedgerState> _load(String? companyId) async {
    final companies = await GetCompanies(_repo).execute();

    if (companies.isEmpty) {
      return const SalaryLedgerState();
    }

    final effectiveId = companyId ??
        state.valueOrNull?.selectedCompanyId ??
        companies.first.id;

    final dashboard =
        await GetCompanyDashboard(_repo).execute(effectiveId);

    debugPrint(
        '💰 Salary: ${companies.length} co, ${dashboard.months.length} months');

    return SalaryLedgerState(
      companies: companies,
      selectedCompanyId: effectiveId,
      months: dashboard.months,
      report: dashboard.report,
      health: dashboard.health,
    );
  }

  Future<void> _reload() async {
    try {
      state = AsyncData(
          await _load(state.valueOrNull?.selectedCompanyId));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  // ── Company ─────────────────────────────────────────────────

  Future<void> selectCompany(String companyId) async {
    state = const AsyncLoading();
    try {
      state = AsyncData(await _load(companyId));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> setupCompanyAndSalary(SetupSalaryInput input) async {
    state = const AsyncLoading();
    try {
      debugPrint('💰 Setup: ${input.companyName}, ₹${input.salary}, '
          'day=${input.payDay}, start=${input.startMonth}');

      final parts = input.startMonth.split('-');
      final startYear = int.tryParse(parts[0]) ?? DateTime.now().year;
      final startMo =
          int.tryParse(parts.length > 1 ? parts[1] : '1') ?? 1;

      final companyId = await SetupCompany(_repo).execute(
        companyName: input.companyName,
        expectedSalary: input.salary,
        payDay: input.payDay,
        startFrom: DateTime(startYear, startMo, 1),
        employmentType: input.employmentType,
        payCycle: input.payCycle,
      );

      debugPrint('💰 Company created: $companyId');
      state = AsyncData(await _load(companyId));
      debugPrint('💰 Dashboard loaded successfully');
    } catch (e, st) {
      debugPrint('❌ setupCompanyAndSalary failed: $e\n$st');
      state = AsyncError(e, st);
    }
  }

  Future<void> addCompany(Company company) async {
    try {
      await _repo.insertCompany(company.toMap());
      await _reload();
    } catch (e, st) {
      debugPrint('❌ addCompany failed: $e\n$st');
      state = AsyncError(e, st);
    }
  }

  Future<void> deleteCompany(String companyId) async {
    state = const AsyncLoading();
    try {
      await _repo.deleteCompany(companyId);
      state = AsyncData(await _load(null));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> updateCompany(Company company) async {
    await _repo.updateCompany(company.toMap());
    await _reload();
  }

  /// Creates a new salary contract (hike) and updates future unpaid months.
  Future<void> updateSalary({
    required String companyId,
    required double newSalary,
    required DateTime effectiveFrom,
  }) async {
    await UpdateSalary(_repo).execute(
      companyId: companyId,
      newSalary: newSalary,
      effectiveFrom: effectiveFrom,
    );
    await _reload();
  }

  // ── Month ───────────────────────────────────────────────────

  Future<void> deleteMonth(String monthId) async {
    await _repo.deleteMonth(monthId);
    await _reload();
  }

  // ── Payment ─────────────────────────────────────────────────

  Future<void> addPayment(SalaryLedgerEntry entry) async {
    await _repo.insertPayment(entry);
    debugPrint('💰 Payment: ₹${entry.amount} (${entry.type.name})');
    await _reload();
  }

  Future<void> deletePayment(String id) async {
    await _repo.deletePayment(id);
    await _reload();
  }

  Future<void> updateMonthExpectedAmount(
      String monthId, double amount) async {
    await _repo.updateMonthExpectedAmount(monthId, amount);
    await _reload();
  }

  // ── Hold ────────────────────────────────────────────────────

  Future<void> putMonthOnHold(String monthId) async {
    await _repo.setMonthHoldStatus(monthId, true);
    debugPrint('⏸️ Month $monthId put on hold');
    await _reload();
  }

  Future<void> removeMonthHold(String monthId) async {
    await _repo.setMonthHoldStatus(monthId, false);
    debugPrint('▶️ Month $monthId hold released');
    await _reload();
  }

  Future<void> refresh() async {
    await _reload();
  }
}
