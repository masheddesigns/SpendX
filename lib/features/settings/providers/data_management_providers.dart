import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../features/liabilities/providers/liabilities_providers.dart'
    show lendingProvider, liabilitiesSummaryProvider;

class DataManagementNotifier extends StateNotifier<AsyncValue<void>> {
  DataManagementNotifier(this.ref) : super(const AsyncData(null));

  final Ref ref;

  Future<void> clearExpenses() =>
      _run(ref.read(maintenanceRepoProvider).clearExpenses);
  Future<void> clearIncome() =>
      _run(ref.read(maintenanceRepoProvider).clearIncome);
  Future<void> clearLending() =>
      _run(ref.read(maintenanceRepoProvider).clearLending);
  Future<void> clearCreditData() =>
      _run(ref.read(maintenanceRepoProvider).clearCreditData);
  Future<void> clearLoans() =>
      _run(ref.read(maintenanceRepoProvider).clearLoans);
  Future<void> clearSalaryData() =>
      _run(ref.read(maintenanceRepoProvider).clearSalaryData);
  Future<void> clearGoals() =>
      _run(ref.read(maintenanceRepoProvider).clearGoals);
  Future<void> clearAccounts() =>
      _run(ref.read(maintenanceRepoProvider).clearAccounts);
  Future<void> clearAllData() =>
      _run(ref.read(maintenanceRepoProvider).clearAllData);

  Future<void> _run(Future<void> Function() action) async {
    state = const AsyncLoading();
    try {
      await action();
      _invalidateCaches();
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  void _invalidateCaches() {
    ref.invalidate(transactionsProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(cardsProvider);
    ref.invalidate(loansProvider);
    ref.invalidate(categoriesProvider);
    ref.invalidate(tagsProvider);
    ref.invalidate(budgetsProvider);
    ref.invalidate(recurringProvider);
    ref.invalidate(remindersProvider);
    ref.invalidate(netWorthHistoryProvider);
    ref.invalidate(lendingProvider);
    ref.invalidate(liabilitiesSummaryProvider);
  }
}

final dataManagementProvider =
    StateNotifierProvider<DataManagementNotifier, AsyncValue<void>>((ref) {
      return DataManagementNotifier(ref);
    });
