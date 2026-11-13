import '../../../data/core/undoable_delete.dart';
import '../../../data/core/app_database.dart';
import '../../../data/core/tables.dart';
import '../../../data/providers.dart';
import '../../../data/providers.dart' as app_data;
import '../../../models/credit_card.dart';
import '../../../models/credit_transaction.dart';
import '../../../models/credit_emi.dart';
import '../../../models/emi_installment.dart';
import '../../../models/ledger_transaction.dart';
import '../../../models/reminder_model.dart';
import '../../../models/loan.dart';
import '../../../models/lending.dart';
import '../../../services/credit_intelligence_service.dart';
import '../../../services/financial_transaction_service.dart';
import '../../../services/haptic_service.dart';
import '../../../core/services/service_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export '../../../data/providers.dart' show cardByIdProvider;

/// Provider for the list of all credit cards (synchronized with canonical cardsProvider)
final creditCardsProvider = FutureProvider<List<CreditCard>>((ref) async {
  return await ref.watch(cardsProvider.future);
});

/// Provider for a specific credit card's outstanding balance derived from canonical liability
final creditOutstandingProvider = FutureProvider.family<double, String>((
  ref,
  cardId,
) async {
  final card = await ref.watch(creditRepoProvider).getCard(cardId);
  return card?.usedAmount ?? 0.0;
});

/// Provider for a specific credit card's active EMIs
final creditActiveEmisProvider = FutureProvider.family<List<CreditEMI>, String>(
  (ref, cardId) async {
    final emis = await ref.watch(creditRepoProvider).getEmis(cardId);
    return emis.where((e) => e.remainingMonths > 0).toList();
  },
);

/// Provider for a specific credit card's recent transactions from canonical repository
final creditRecentTransactionsProvider =
    FutureProvider.family<List<CreditTransaction>, String>((ref, cardId) async {
      final txns = await ref.watch(creditRepoProvider).getTransactions(cardId);
      return txns.take(50).toList();
    });

typedef CreditStatementSummary = ({
  double statementAmount,
  double repaidAmount,
  double remainingDue,
  double minimumDue,
  DateTime? dueDate,
  bool isPaid,
});

/// Provider for a specific credit card's statement bill & repayment status
final creditStatementSummaryProvider =
    FutureProvider.family<CreditStatementSummary?, String>((ref, cardId) async {
  final card = await ref.watch(creditRepoProvider).getCard(cardId);
  if (card == null) return null;
  final statements = await ref.watch(creditRepoProvider).getStatements(cardId);
  final latestStmt = statements.firstOrNull;

  final stmtAmount = (latestStmt != null && latestStmt.statementAmount > 0)
      ? latestStmt.statementAmount
      : card.lastStatementBalance;
  if (stmtAmount <= 0) return null;

  final minDue = latestStmt?.minimumDue ?? (stmtAmount * 0.05);
  final dueDate = card.nextDueDate;

  final stmtGenDate = latestStmt?.generatedDate ??
      DateTime(DateTime.now().year, DateTime.now().month, card.billingDay);
  final windowStart = stmtGenDate.subtract(const Duration(days: 10));

  double totalRepaid = 0.0;
  final seenTxIds = <String>{};

  // 1. Check canonical transactions
  final cardTxns = await ref.watch(creditRepoProvider).getTransactions(cardId);
  for (final t in cardTxns) {
    if (t.type == 'payment' || t.type == 'credit_payment') {
      if (t.date.isAfter(windowStart) || t.date.isAtSameMomentAs(windowStart)) {
        totalRepaid += t.amount;
        seenTxIds.add(t.id);
      }
    }
  }

  // 2. Check legacy database transactions if not already counted
  final db = await AppDatabase.instance.database;
  final cardKw = card.bank.toLowerCase().contains('icici')
      ? 'icici'
      : (card.bank.toLowerCase().contains('csb')
          ? 'csb'
          : (card.bank.toLowerCase().contains('hdfc') ? 'hdfc' : ''));
  try {
    final allPayments = await db.rawQuery('''
      SELECT id, amount, date
      FROM ${Tables.transactions}
      WHERE (related_entity_id = ? OR (type = 'credit_payment' AND ? != '' AND LOWER(COALESCE(notes, '')) LIKE '%' || ? || '%'))
        AND type = 'credit_payment'
        AND is_deleted = 0;
    ''', [card.id, cardKw, cardKw]);

    for (final row in allPayments) {
      final txId = row['id'] as String?;
      if (txId != null && seenTxIds.contains(txId)) continue;
      final rawDate = row['date'] as String?;
      if (rawDate != null) {
        final txDate = DateTime.tryParse(rawDate);
        if (txDate != null &&
            (txDate.isAfter(windowStart) || txDate.isAtSameMomentAs(windowStart))) {
          totalRepaid += (row['amount'] as num?)?.toDouble() ?? 0.0;
        }
      }
    }
  } catch (_) {}

  final remainingDue = (stmtAmount - totalRepaid).clamp(0.0, stmtAmount);

  return (
    statementAmount: stmtAmount,
    repaidAmount: totalRepaid,
    remainingDue: remainingDue,
    minimumDue: minDue,
    dueDate: dueDate,
    isPaid: remainingDue <= 0.01,
  );
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
        await FinancialTransactionService().appendLedger(ledgerTransaction);
        _ref.invalidate(cardsProvider);
        _ref.invalidate(creditCardsProvider);
        _ref.invalidate(creditRecentTransactionsProvider(cardId));
        _ref.invalidate(creditOutstandingProvider(cardId));
        _ref.invalidate(liabilitiesSummaryProvider);

        // Sync upcoming card reminder
        try {
          final card = await _ref.read(creditRepoProvider).getCard(cardId);
          if (card != null) {
            final derived = await _ref.read(creditRepoProvider).getDerivedBalance(card.id);
            final outstandingRupees = derived.toRupees;
            await _ref.read(app_data.reminderRepoProvider).insertGlobalReminder(
              Reminder(
                id: 'credit_due_${card.id}',
                type: ReminderType.credit,
                title: 'Credit Card Due: ${card.name}',
                linkedEntityId: card.id,
                dueDate: card.nextDueDate,
                amount: outstandingRupees,
                isActive: outstandingRupees > 0,
                status: outstandingRupees <= 0
                    ? ReminderStatus.inactive
                    : ReminderStatus.upcoming,
                recordStatus: outstandingRupees <= 0
                    ? ReminderRecordStatus.done
                    : ReminderRecordStatus.pending,
                sourceType: ReminderSourceType.credit,
                sourceId: card.id,
              ).toMap(),
            );
            _ref.invalidate(app_data.remindersProvider);
          }
        } catch (_) {}
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

/// Provider for the list of all loans (synchronized with canonical loansProvider)
final loansProvider = FutureProvider<List<Loan>>((ref) async {
  return await ref.watch(app_data.loansProvider.future);
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

        // Operational status update only — zero rogue ledger_transactions writes.
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
