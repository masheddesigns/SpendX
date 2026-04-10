import '../../../data/core/undoable_delete.dart';
import '../../../data/providers.dart';
import '../../../models/credit_card.dart';
import '../../../models/credit_transaction.dart';
import '../../../models/credit_emi.dart';
import '../../../models/emi_installment.dart';
import '../../../models/ledger_transaction.dart';
import '../../../models/loan.dart';
import '../../../models/lending.dart';
import '../../../services/credit_intelligence_service.dart';
import '../../../services/haptic_service.dart';
import '../../../core/services/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider for the list of all credit cards
final creditCardsProvider = FutureProvider<List<CreditCard>>((ref) async {
  return await ref.watch(creditRepoProvider).getAll();
});

/// Provider for a specific credit card's outstanding balance
final creditOutstandingProvider = FutureProvider.family<double, String>((
  ref,
  cardId,
) async {
  final creditService = ref.watch(creditCardServiceProvider);
  return await creditService.calculateOutstanding(cardId);
});

/// Provider for a specific credit card's active EMIs
final creditActiveEmisProvider = FutureProvider.family<List<CreditEMI>, String>(
  (ref, cardId) async {
    final emis = await ref.watch(creditRepoProvider).getEmis(cardId);
    return emis.where((e) => e.remainingMonths > 0).toList();
  },
);

/// Provider for a specific credit card's recent transactions from Unified Ledger
final creditRecentTransactionsProvider =
    FutureProvider.family<List<CreditTransaction>, String>((ref, cardId) async {
      final ledgerRepo = ref.watch(ledgerRepoProvider);
      final ledgerTxns = await ledgerRepo.getAll(creditCardId: cardId);
      return ledgerTxns
          .map(
            (lt) => CreditTransaction(
              id: lt.referenceId ?? lt.id.toString(),
              cardId: cardId,
              amount: lt.amount,
              date: lt.date,
              category: lt.categoryId ?? 'uncategorized',
              type: lt.type.name,
              status: 'active',
              note: lt.note,
            ),
          )
          .take(50)
          .toList();
    });

final creditPurchaseMutationProvider =
    StateNotifierProvider<CreditPurchaseMutationNotifier, AsyncValue<void>>((
      ref,
    ) {
      return CreditPurchaseMutationNotifier(ref);
    });

class CreditPurchaseMutationNotifier extends StateNotifier<AsyncValue<void>> {
  CreditPurchaseMutationNotifier(this._ref) : super(const AsyncData(null));

  final Ref _ref;

  Future<void> addPurchase({
    required CreditTransaction transaction,
    required LedgerTransaction ledgerTransaction,
    required String cardId,
  }) async {
    state = const AsyncData(null);
    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(creditRepoProvider).insertTransaction(transaction);
        await _ref.read(ledgerRepoProvider).insert(ledgerTransaction);
        _ref.invalidate(creditRecentTransactionsProvider(cardId));
        _ref.invalidate(creditOutstandingProvider(cardId));
        _ref.invalidate(liabilitiesSummaryProvider);
      } catch (e, st) {
        state = AsyncError(e, st);
        rethrow;
      }
    });
  }
}

/// Provider for credit card intelligence
final creditIntelligenceProvider =
    FutureProvider.family<CreditIntelligenceData, CreditCard>((
      ref,
      card,
    ) async {
      // We need to ensure the card has the latest outstanding for intel calculation
      final outstanding = await ref.watch(
        creditOutstandingProvider(card.id).future,
      );
      final cardWithOutstanding = card.copyWith(outstanding: outstanding);
      return await CreditIntelligenceService.instance.getCardIntelligence(
        cardWithOutstanding,
      );
    });

/// Provider for the list of all loans
final loansProvider = FutureProvider<List<Loan>>((ref) async {
  return await ref.watch(loanRepoProvider).getLoans();
});

/// Provider for lending records
final lendingListProvider = FutureProvider.family<List<Lending>, bool>((
  ref,
  isSettled,
) async {
  return await ref.watch(lendingRepoProvider).getAll(settledFilter: isSettled);
});

/// State for the LendingNotifier
class LendingState {
  final List<Lending> activeItems;
  final List<Lending> settledItems;
  final bool isLoadingActive;
  final bool isLoadingSettled;
  final bool hasMoreActive;
  final bool hasMoreSettled;

  LendingState({
    this.activeItems = const [],
    this.settledItems = const [],
    this.isLoadingActive = false,
    this.isLoadingSettled = false,
    this.hasMoreActive = true,
    this.hasMoreSettled = true,
  });

  LendingState copyWith({
    List<Lending>? activeItems,
    List<Lending>? settledItems,
    bool? isLoadingActive,
    bool? isLoadingSettled,
    bool? hasMoreActive,
    bool? hasMoreSettled,
  }) {
    return LendingState(
      activeItems: activeItems ?? this.activeItems,
      settledItems: settledItems ?? this.settledItems,
      isLoadingActive: isLoadingActive ?? this.isLoadingActive,
      isLoadingSettled: isLoadingSettled ?? this.isLoadingSettled,
      hasMoreActive: hasMoreActive ?? this.hasMoreActive,
      hasMoreSettled: hasMoreSettled ?? this.hasMoreSettled,
    );
  }
}

/// Notifier for managing paginated lending records
class LendingNotifier extends StateNotifier<LendingState> {
  final Ref _ref;
  LendingNotifier(this._ref) : super(LendingState()) {
    refresh();
  }

  static const int _limit = 20;

  Future<void> refresh() async {
    if (!mounted) return;
    state = state.copyWith(isLoadingActive: true, isLoadingSettled: true);

    final repo = _ref.read(lendingRepoProvider);
    final active = await repo.getAll(settledFilter: false);
    final settled = await repo.getAll(settledFilter: true);

    if (!mounted) return;
    state = state.copyWith(
      activeItems: active,
      settledItems: settled,
      isLoadingActive: false,
      isLoadingSettled: false,
      hasMoreActive: active.length >= _limit,
      hasMoreSettled: settled.length >= _limit,
    );
  }

  Future<void> add(Lending lending, {bool emitHaptic = true}) async {
    final snapshot = state;
    final tempLending = lending.copyWith(
      id: 'temp_${DateTime.now().microsecondsSinceEpoch}',
    );
    final isSettled = tempLending.isSettled;
    state = isSettled
        ? state.copyWith(settledItems: [...state.settledItems, tempLending])
        : state.copyWith(activeItems: [...state.activeItems, tempLending]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await _ref.read(lendingRepoProvider).insert(lending);
        final persisted = lending.copyWith(id: realId);
        state = state.copyWith(
          activeItems: state.activeItems
              .map((item) => item.id == tempLending.id ? persisted : item)
              .toList(),
          settledItems: state.settledItems
              .map((item) => item.id == tempLending.id ? persisted : item)
              .toList(),
        );
      } catch (e) {
        state = snapshot;
        rethrow;
      }
    });
  }

  Future<void> replace(Lending lending) async {
    final snapshot = state;

    List<Lending> replaceIn(List<Lending> items) {
      return items
          .map((item) => item.id == lending.id ? lending : item)
          .toList();
    }

    final wasActive = state.activeItems.any((item) => item.id == lending.id);
    final wasSettled = state.settledItems.any((item) => item.id == lending.id);

    state = state.copyWith(
      activeItems: lending.isSettled
          ? state.activeItems.where((item) => item.id != lending.id).toList()
          : (wasActive
                ? replaceIn(state.activeItems)
                : [...state.activeItems, lending]),
      settledItems: lending.isSettled
          ? (wasSettled
                ? replaceIn(state.settledItems)
                : [...state.settledItems, lending])
          : state.settledItems.where((item) => item.id != lending.id).toList(),
    );

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(lendingRepoProvider).update(lending);
      } catch (e) {
        state = snapshot;
        rethrow;
      }
    });
  }

  Future<void> remove(Lending lending) async {
    final snapshot = state;
    final existsInState =
        state.activeItems.any((item) => item.id == lending.id) ||
        state.settledItems.any((item) => item.id == lending.id);
    if (!existsInState) {
      return;
    }

    state = state.copyWith(
      activeItems: state.activeItems
          .where((item) => item.id != lending.id)
          .toList(),
      settledItems: state.settledItems
          .where((item) => item.id != lending.id)
          .toList(),
    );

    try {
      await performUndoableDelete<Lending>(
        ref: _ref,
        label: 'Lending deleted',
        payload: lending,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => state = snapshot,
        repositoryDelete: () => _ref.read(writeQueueProvider).enqueue(() async {
          await _ref.read(lendingRepoProvider).delete(lending.id);
        }),
      );
    } catch (e) {
      state = snapshot;
      rethrow;
    }
  }

  Future<void> loadMore(bool isSettled) async {
    // Note: To be implemented in LendingRepo if cursor-based pagination is needed
    // For now, refresh() handles everything as the dataset is small
    return;
  }
}

/// Provider for the LendingNotifier
final lendingProvider = StateNotifierProvider<LendingNotifier, LendingState>((
  ref,
) {
  return LendingNotifier(ref);
});

class EmiInstallmentsNotifier
    extends StateNotifier<AsyncValue<List<EMIInstallment>>> {
  EmiInstallmentsNotifier(this._ref, this._emiId)
    : super(const AsyncLoading()) {
    refresh();
  }

  final Ref _ref;
  final String _emiId;

  Future<void> refresh() async {
    try {
      final items = await _ref.read(creditRepoProvider).getInstallments(_emiId);
      state = AsyncData(items);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> add(EMIInstallment installment) async {
    final snapshot = List<EMIInstallment>.from(state.valueOrNull ?? const []);
    state = AsyncData(
      [...snapshot, installment]
        ..sort((a, b) => a.dueDate.compareTo(b.dueDate)),
    );

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(creditRepoProvider).insertInstallment(installment);
      } catch (e, st) {
        state = AsyncError(e, st);
        state = AsyncData(snapshot);
        rethrow;
      }
    });
  }

  Future<void> replace(EMIInstallment installment) async {
    final snapshot = List<EMIInstallment>.from(state.valueOrNull ?? const []);
    state = AsyncData(
      snapshot
          .map((item) => item.id == installment.id ? installment : item)
          .toList()
        ..sort((a, b) => a.dueDate.compareTo(b.dueDate)),
    );

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(creditRepoProvider).updateInstallment(installment);
      } catch (e, st) {
        state = AsyncError(e, st);
        state = AsyncData(snapshot);
        rethrow;
      }
    });
  }

  Future<void> remove(EMIInstallment installment) async {
    final snapshot = List<EMIInstallment>.from(state.valueOrNull ?? const []);
    state = AsyncData(
      snapshot.where((item) => item.id != installment.id).toList(),
    );

    try {
      await performUndoableDelete<EMIInstallment>(
        ref: _ref,
        label: 'Installment deleted',
        payload: installment,
        undo: (item) => add(item),
        rollback: () => state = AsyncData(snapshot),
        repositoryDelete: () => _ref.read(writeQueueProvider).enqueue(() async {
          await _ref.read(creditRepoProvider).deleteInstallment(installment.id);
        }),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
      state = AsyncData(snapshot);
      rethrow;
    }
  }

  Future<void> togglePaymentStatus({
    required EMIInstallment installment,
    required CreditEMI emi,
  }) async {
    final snapshot = List<EMIInstallment>.from(state.valueOrNull ?? const []);
    final newStatus = installment.status == 'paid' ? 'pending' : 'paid';
    final updatedInstallment = installment.copyWith(status: newStatus);
    final updatedItems =
        snapshot
            .map(
              (item) => item.id == installment.id ? updatedInstallment : item,
            )
            .toList()
          ..sort((a, b) => a.dueDate.compareTo(b.dueDate));

    state = AsyncData(updatedItems);

    final newPaidCount = newStatus == 'paid'
        ? emi.paidMonths + 1
        : emi.paidMonths - 1;
    final updatedEmi = emi.copyWith(
      paidMonths: newPaidCount,
      remainingMonths: emi.tenureMonths - newPaidCount,
    );

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref
            .read(creditRepoProvider)
            .updateInstallment(updatedInstallment);
        await _ref.read(creditRepoProvider).updateEMI(updatedEmi);

        if (newStatus == 'paid') {
          await _ref
              .read(ledgerRepoProvider)
              .insert(
                LedgerTransaction(
                  type: LedgerType.emi_installment,
                  amount: installment.amount,
                  date: DateTime.now(),
                  referenceId: installment.id,
                  creditCardId: emi.cardId,
                  note: 'EMI Installment Paid',
                ),
              );
        } else {
          final txns = await _ref
              .read(ledgerRepoProvider)
              .getAll(referenceId: installment.id);
          for (final txn in txns) {
            if (txn.id != null) {
              await _ref.read(ledgerRepoProvider).deleteById(txn.id!);
            }
          }
        }

        _ref.invalidate(creditActiveEmisProvider(emi.cardId));
        _ref.invalidate(creditOutstandingProvider(emi.cardId));
        _ref.invalidate(liabilitiesSummaryProvider);
      } catch (e, st) {
        state = AsyncError(e, st);
        state = AsyncData(snapshot);
        rethrow;
      }
    });
  }
}

final emiInstallmentsProvider =
    StateNotifierProvider.family<
      EmiInstallmentsNotifier,
      AsyncValue<List<EMIInstallment>>,
      String
    >((ref, emiId) {
      return EmiInstallmentsNotifier(ref, emiId);
    });

/// Summary data for the Liabilities Hub
class LiabilitiesSummary {
  final double totalCreditOutstanding;
  final double totalLoanOutstanding;
  final double totalLiabilities;

  LiabilitiesSummary({
    required this.totalCreditOutstanding,
    required this.totalLoanOutstanding,
    required this.totalLiabilities,
  });
}

/// Provider for the Liabilities Hub summary
final liabilitiesSummaryProvider = FutureProvider<LiabilitiesSummary>((
  ref,
) async {
  final cards = await ref.watch(creditCardsProvider.future);
  final loans = await ref.watch(loansProvider.future);
  final creditService = ref.watch(creditCardServiceProvider);
  final loanService = ref.watch(loanServiceProvider);

  double cardTotal = 0;
  for (var card in cards) {
    cardTotal += await creditService.calculateOutstanding(card.id);
  }

  double loanTotal = 0;
  for (var loan in loans) {
    loanTotal += await loanService.getRemainingBalance(loan.id);
  }

  return LiabilitiesSummary(
    totalCreditOutstanding: cardTotal,
    totalLoanOutstanding: loanTotal,
    totalLiabilities: cardTotal + loanTotal,
  );
});
