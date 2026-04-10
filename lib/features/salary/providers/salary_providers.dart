import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/service_providers.dart';
import '../../../data/providers.dart' show accountsProvider;
import '../../../data/repositories/salary_repo.dart';
import '../../../models/bank_account.dart';
import '../../../models/company.dart';
import '../../../models/salary_contract.dart';
import '../../../models/salary_model.dart';
import '../../../models/salary_payment.dart';
import '../../../services/salary_service.dart';
import '../../home/providers/home_providers.dart';

final bankAccountsProvider = FutureProvider<List<BankAccount>>((ref) {
  return ref.watch(accountsProvider.future);
});

final salaryCompaniesProvider = FutureProvider<List<Company>>((ref) async {
  // Direct DB query — bypasses SalaryService._ensureInitialized() cache
  final repo = SalaryRepo();
  final maps = await repo.getCompanies();
  return maps.map(Company.fromMap).toList();
});

final activeSalaryCompanyProvider = FutureProvider<Company?>((ref) {
  return ref.watch(salaryServiceProvider).getActiveCompany();
});

final activeCompanyIdProvider = FutureProvider<String?>((ref) {
  return ref.watch(salaryServiceProvider).getActiveCompanyId();
});

final salaryDashboardProvider = FutureProvider.autoDispose
    .family<SalaryDashboardData, String?>((ref, companyId) {
      final link = ref.keepAlive();
      final timer = Timer(const Duration(minutes: 10), link.close);
      ref.onDispose(timer.cancel);
      return ref
          .watch(salaryServiceProvider)
          .getDashboardData(companyId: companyId);
    });

final salaryNotifierProvider =
    StateNotifierProvider<SalaryNotifier, AsyncValue<void>>((ref) {
      return SalaryNotifier(ref.watch(salaryServiceProvider), ref);
    });

class SalaryNotifier extends StateNotifier<AsyncValue<void>> {
  final SalaryService _service;
  final Ref _ref;

  SalaryNotifier(this._service, this._ref) : super(const AsyncData(null));

  Future<void> markFullyReceived(SalaryPayment payment) async {
    state = const AsyncLoading();
    try {
      await _service.markFullyReceived(payment);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> addPartialPayment(SalaryPayment payment, double amount) async {
    state = const AsyncLoading();
    try {
      await _service.addPartialPayment(payment, amount);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> markDelayed(SalaryPayment payment) async {
    state = const AsyncLoading();
    try {
      await _service.markDelayed(payment);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> putOnHold(SalaryPayment payment) async {
    state = const AsyncLoading();
    try {
      await _service.putOnHold(payment);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> addBonus(SalaryPayment payment, double amount) async {
    state = const AsyncLoading();
    try {
      await _service.addBonus(payment, amount);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> updatePayment(SalaryPayment payment) async {
    state = const AsyncLoading();
    try {
      await _service.updatePayment(payment);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> saveSalary(Salary salary) async {
    state = const AsyncLoading();
    try {
      await _service.saveSalary(salary);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> setupSalary({
    required String companyId,
    required double baseSalary,
    required DateTime startDate,
    String? defaultAccountId,
  }) async {
    state = const AsyncLoading();
    try {
      await _service.setupSalary(
        companyId: companyId,
        baseSalary: baseSalary,
        startDate: startDate,
        defaultAccountId: defaultAccountId,
      );
      state = const AsyncData(null);
      _invalidateDashboard();
      _ref.invalidate(salaryCompaniesProvider);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> updateContract(SalaryContract contract) async {
    state = const AsyncLoading();
    try {
      await _service.updateContract(contract);
      state = const AsyncData(null);
      _invalidateDashboard();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> saveCompany(Company company) async {
    state = const AsyncLoading();
    try {
      // Direct DB insert to avoid service layer caching
      final repo = SalaryRepo();
      await repo.insertCompany(company.toMap());
      // Also register in service for active company tracking
      await _service.setActiveCompany(company.id);
      state = const AsyncData(null);
      _invalidateDashboard();
      _ref.invalidate(salaryCompaniesProvider);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> updateCompany(Company company) async {
    state = const AsyncLoading();
    try {
      await _service.updateCompany(company);
      state = const AsyncData(null);
      _invalidateDashboard();
      _ref.invalidate(salaryCompaniesProvider);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> deleteCompany(String companyId) async {
    state = const AsyncLoading();
    try {
      await _service.deleteCompany(companyId);
      state = const AsyncData(null);
      _invalidateDashboard();
      _ref.invalidate(salaryCompaniesProvider);
      _ref.invalidate(activeCompanyIdProvider);
      _ref.invalidate(activeSalaryCompanyProvider);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> setActiveCompany(String companyId) async {
    state = const AsyncLoading();
    try {
      await _service.setActiveCompany(companyId);
      state = const AsyncData(null);
      _invalidateDashboard();
      _ref.invalidate(activeCompanyIdProvider);
      _ref.invalidate(activeSalaryCompanyProvider);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  void _invalidateDashboard() {
    _ref.invalidate(salaryDashboardProvider);
    _ref.invalidate(homeSummaryProvider);
  }
}
