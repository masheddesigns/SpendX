import 'repositories/transaction_repo.dart';
import 'repositories/lending_repo.dart';
import 'repositories/account_repo.dart';
import '../models/reports_summary.dart';
import '../services/reports_service.dart';
import 'repositories/loan_repo.dart';
import 'repositories/credit_repo.dart';
import 'repositories/category_repo.dart';
import 'repositories/tag_repo.dart';
import 'repositories/budget_repo.dart';
import 'repositories/recurring_repo.dart';
import 'repositories/salary_repo.dart';
import 'repositories/ledger_repo.dart';
import 'repositories/reminder_repo.dart';
import 'repositories/net_worth_repo.dart';
import 'repositories/analytics_repo.dart';
import 'repositories/emi_plan_repo.dart';
import 'repositories/maintenance_repo.dart';
import '../services/net_worth_service.dart';
import '../services/ledger_service.dart';
import '../services/financial_health_service.dart';
import '../services/salary_service.dart';
import '../services/analytics_service.dart';
import '../services/insight_engine.dart';
import '../services/auto_categorization_service.dart';
import '../domain/loans/loan_service.dart';
import '../models/transaction.dart';
import '../models/bank_account.dart';
import '../models/loan.dart';
import '../models/loan_installment.dart';
import '../models/credit_card.dart';
import '../models/category.dart';
import '../models/tag.dart';
import '../models/budget.dart';
import '../models/recurring_template.dart';
import '../models/net_worth_snapshot_record.dart';
import '../models/reminder_model.dart';
import '../models/analytics_bundle.dart';
import '../models/analytics_summary.dart';
import '../models/emi_plan.dart';
import '../models/insight.dart';
import '../models/ledger_transaction.dart';
import '../models/credit_transaction.dart';
import 'core/write_queue.dart';
import 'core/app_data_sync_manager.dart';
import 'core/undoable_delete.dart';
import '../services/haptic_service.dart';
import '../services/financial_intelligence_service.dart';
import '../services/data_change_bus.dart';
import 'package:flutter/widgets.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// --- Repositories ---
final transactionRepoProvider = Provider((ref) => TransactionRepo());
final accountRepoProvider = Provider((ref) => AccountRepo());
final loanRepoProvider = Provider((ref) => LoanRepo());
final creditRepoProvider = Provider((ref) => CreditRepo());
final categoryRepoProvider = Provider((ref) => CategoryRepo());
final tagRepoProvider = Provider((ref) => TagRepo());
final netWorthRepoProvider = Provider((ref) => NetWorthRepo());
final budgetRepoProvider = Provider((ref) => BudgetRepo());
final recurringRepoProvider = Provider((ref) => RecurringRepo());
final salaryRepoProvider = Provider((ref) => SalaryRepo());
final ledgerRepoProvider = Provider((ref) => LedgerRepo());
final lendingRepoProvider = Provider((ref) => LendingRepo());
final reminderRepoProvider = Provider((ref) => ReminderRepo());
final analyticsRepoProvider = Provider((ref) => AnalyticsRepo());
final emiPlanRepoProvider = Provider((ref) => EmiPlanRepo());
final maintenanceRepoProvider = Provider((ref) => MaintenanceRepo());

// --- Infrastructure ---
final analyticsServiceProvider = Provider((ref) => AnalyticsService());
final reportsServiceProvider = Provider(
  (ref) => ReportsService(
    transactionRepo: ref.watch(transactionRepoProvider),
    creditRepo: ref.watch(creditRepoProvider),
    loanRepo: ref.watch(loanRepoProvider),
    lendingRepo: ref.watch(lendingRepoProvider),
    ledgerRepo: ref.watch(ledgerRepoProvider),
  ),
);
final insightEngineProvider = Provider<InsightEngine>((ref) => InsightEngine());
final writeQueueProvider = Provider((ref) => WriteQueue());
final appDataSyncManagerProvider = Provider((ref) => AppDataSyncManager(ref));

// --- Services ---
final salaryServiceProvider = Provider(
  (ref) => SalaryService(
    salaryRepo: ref.watch(salaryRepoProvider),
    transactionRepo: ref.watch(transactionRepoProvider),
    reminderRepo: ref.watch(reminderRepoProvider),
  ),
);

final financialHealthServiceProvider = Provider(
  (ref) => FinancialHealthService(
    transactionRepo: ref.read(transactionRepoProvider),
    accountRepo: ref.read(accountRepoProvider),
    loanRepo: ref.read(loanRepoProvider),
    salaryRepo: ref.read(salaryRepoProvider),
    lendingRepo: ref.read(lendingRepoProvider),
    categoryRepo: ref.read(categoryRepoProvider),
  ),
);

final ledgerServiceProvider = Provider(
  (ref) => LedgerService(ledgerRepo: ref.read(ledgerRepoProvider)),
);

final ledgerMutationProvider =
    StateNotifierProvider<LedgerMutationNotifier, AsyncValue<void>>((ref) {
      return LedgerMutationNotifier(ref);
    });

final netWorthServiceProvider = Provider(
  (ref) => NetWorthService(
    ref.read(accountRepoProvider),
    ref.read(loanRepoProvider),
  ),
);

final emiPlanMutationProvider =
    StateNotifierProvider<EmiPlanMutationNotifier, AsyncValue<void>>((ref) {
      return EmiPlanMutationNotifier(ref);
    });

final reportsProvider = reportsSummaryProvider;

final creditTransactionByIdProvider =
    FutureProvider.family<CreditTransaction?, String>((ref, id) async {
      return ref.watch(creditRepoProvider).getTransactionById(id);
    });

final creditTransactionsProvider =
    FutureProvider.family<List<CreditTransaction>, String?>((
      ref,
      cardId,
    ) async {
      if (cardId == null) {
        final cards = await ref.watch(cardsProvider.future);
        final all = <CreditTransaction>[];
        for (final card in cards) {
          all.addAll(
            await ref.watch(creditRepoProvider).getTransactions(card.id),
          );
        }
        all.sort((a, b) => b.date.compareTo(a.date));
        return all;
      }
      return ref.watch(creditRepoProvider).getTransactions(cardId);
    });

final expenseCategoriesProvider = Provider<List<Category>>((ref) {
  final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
  return categories.where((item) => item.type == 'expense').toList();
});

final loanByIdProvider = Provider.family<Loan?, String>((ref, loanId) {
  final loans = ref.watch(loansProvider).valueOrNull ?? const <Loan>[];
  for (final loan in loans) {
    if (loan.id == loanId) return loan;
  }
  return null;
});

final loanInstallmentsProvider =
    FutureProvider.family<List<LoanInstallment>, String>((ref, loanId) async {
      return ref.watch(loanRepoProvider).getInstallments(loanId);
    });

class LedgerMutationNotifier extends StateNotifier<AsyncValue<void>> {
  LedgerMutationNotifier(this._ref) : super(const AsyncData(null));

  final Ref _ref;

  Future<void> add(LedgerTransaction tx) async {
    state = const AsyncData(null);
    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(ledgerRepoProvider).insert(tx);
        DataChangeBus.instance.notify();
        if (tx.accountId != null && tx.accountId!.isNotEmpty) {
          unawaited(
            FinancialIntelligenceService.instance.takeSnapshot(tx.accountId!),
          );
        }
      } catch (e, st) {
        state = AsyncError(e, st);
        rethrow;
      }
    });
  }

  Future<void> addTransfer({
    required String sourceAccountId,
    required String destinationAccountId,
    required double amount,
    required DateTime date,
    String? note,
  }) async {
    final transactions = _ref
        .read(ledgerServiceProvider)
        .buildTransferTransactions(
          sourceAccountId: sourceAccountId,
          destinationAccountId: destinationAccountId,
          amount: amount,
          date: date,
          note: note,
        );

    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        for (final transaction in transactions) {
          await _ref.read(ledgerRepoProvider).insert(transaction);
        }
        DataChangeBus.instance.notify();
        unawaited(
          FinancialIntelligenceService.instance.takeSnapshot(sourceAccountId),
        );
        unawaited(
          FinancialIntelligenceService.instance.takeSnapshot(
            destinationAccountId,
          ),
        );
      } catch (e, st) {
        state = AsyncError(e, st);
        rethrow;
      }
    });
  }

  Future<void> removeById(int id) async {
    state = const AsyncData(null);
    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(ledgerRepoProvider).deleteById(id);
        DataChangeBus.instance.notify();
      } catch (e, st) {
        state = AsyncError(e, st);
        rethrow;
      }
    });
  }
}

class EmiPlanMutationNotifier extends StateNotifier<AsyncValue<void>> {
  EmiPlanMutationNotifier(this._ref) : super(const AsyncData(null));

  final Ref _ref;

  Future<void> addPlan(EmiPlan plan) => add(plan);

  Future<void> add(EmiPlan plan) async {
    state = const AsyncData(null);
    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(emiPlanRepoProvider).insert(plan);
        DataChangeBus.instance.notify();
      } catch (e, st) {
        state = AsyncError(e, st);
        rethrow;
      }
    });
  }

  Future<void> updatePlan(EmiPlan plan) => update(plan);

  Future<void> update(EmiPlan plan) async {
    state = const AsyncData(null);
    await _ref.read(writeQueueProvider).enqueue(() async {
      try {
        await _ref.read(emiPlanRepoProvider).update(plan);
        DataChangeBus.instance.notify();
      } catch (e, st) {
        state = AsyncError(e, st);
        rethrow;
      }
    });
  }
}

// --- Core Primitive: Cached AsyncNotifier ---

abstract class CachedAsyncNotifier<T> extends AsyncNotifier<T> {
  int _version = 0;

  Future<T> load();

  @override
  Future<T> build() async {
    final v = ++_version;
    final data = await load();
    if (v == _version) {
      return data;
    }
    return state.value as T;
  }

  void setData(T value) {
    state = AsyncData(value);
  }

  void setLoading() {
    state = const AsyncLoading();
  }

  void setError(Object e, StackTrace st) {
    state = AsyncError(e, st);
  }

  String _tempId() => 'temp_${DateTime.now().microsecondsSinceEpoch}';
}

// --- Notifiers: Synchronous UI with Serialized Persistence ---

class TransactionsNotifier extends CachedAsyncNotifier<List<Transaction>> {
  @override
  Future<List<Transaction>> load() async {
    return ref.watch(transactionRepoProvider).getAll();
  }

  Future<void> add(Transaction txn, {bool emitHaptic = true}) async {
    final snapshot = List<Transaction>.from(state.value ?? []);
    final tempTxn = txn.copyWith(id: _tempId());

    setData([tempTxn, ...snapshot]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        var persistedTxn = txn;
        if (persistedTxn.categoryId == null ||
            persistedTxn.categoryId!.isEmpty) {
          final detectedId = await AutoCategorizationService.detectCategoryId(
            persistedTxn.notes,
            type: persistedTxn.type,
          );
          if (detectedId != null) {
            persistedTxn = persistedTxn.copyWith(categoryId: detectedId);
          }
        }

        final realId = await ref
            .read(transactionRepoProvider)
            .insert(persistedTxn);
        final current = state.value ?? [];
        setData(
          current
              .map(
                (t) =>
                    t.id == tempTxn.id ? persistedTxn.copyWith(id: realId) : t,
              )
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Transaction insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(Transaction txn) async {
    final snapshot = List<Transaction>.from(state.value ?? []);
    setData(snapshot.map((t) => t.id == txn.id ? txn : t).toList());

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(transactionRepoProvider).update(txn);
      } catch (e, st) {
        debugPrint('Transaction update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> remove(String id) async {
    final snapshot = List<Transaction>.from(state.value ?? []);
    final txn = snapshot.firstWhere((t) => t.id == id);

    setData(snapshot.where((t) => t.id != id).toList());

    try {
      await performUndoableDelete<Transaction>(
        ref: ref,
        label: 'Transaction deleted',
        payload: txn,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(transactionRepoProvider).delete(id);
        }),
      );
    } catch (e, st) {
      debugPrint('Transaction delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(transactionRepoProvider).getAll();
    setData(fresh);
  }
}

final transactionsProvider =
    AsyncNotifierProvider<TransactionsNotifier, List<Transaction>>(
      TransactionsNotifier.new,
    );

class AccountsNotifier extends CachedAsyncNotifier<List<BankAccount>> {
  @override
  Future<List<BankAccount>> load() async {
    return ref.watch(accountRepoProvider).getAccounts();
  }

  Future<void> add(BankAccount account, {bool emitHaptic = true}) async {
    final snapshot = List<BankAccount>.from(state.value ?? []);
    final tempAccount = account.copyWith(id: _tempId());
    setData([...snapshot, tempAccount]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref
            .read(accountRepoProvider)
            .insertAccount(account);
        final current = state.value ?? [];
        setData(
          current
              .map((a) => a.id == tempAccount.id ? a.copyWith(id: realId) : a)
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Account insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(BankAccount account) async {
    final snapshot = List<BankAccount>.from(state.value ?? []);
    setData(snapshot.map((a) => a.id == account.id ? account : a).toList());

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(accountRepoProvider).updateAccount(account);
      } catch (e, st) {
        debugPrint('Account update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> remove(String id) async {
    final snapshot = List<BankAccount>.from(state.value ?? []);
    final account = snapshot.firstWhere((a) => a.id == id);

    setData(snapshot.where((a) => a.id != id).toList());

    try {
      await performUndoableDelete<BankAccount>(
        ref: ref,
        label: 'Account deleted',
        payload: account,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(accountRepoProvider).deleteAccount(id);
        }),
      );
    } catch (e, st) {
      debugPrint('Account delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(accountRepoProvider).getAccounts();
    setData(fresh);
  }
}

final accountsProvider =
    AsyncNotifierProvider<AccountsNotifier, List<BankAccount>>(
      AccountsNotifier.new,
    );

class LoansNotifier extends CachedAsyncNotifier<List<Loan>> {
  @override
  Future<List<Loan>> load() async {
    return ref.watch(loanRepoProvider).getLoans();
  }

  Future<void> add(Loan loan, {bool emitHaptic = true}) async {
    final snapshot = List<Loan>.from(state.value ?? []);
    final tempLoan = loan.copyWith(id: _tempId());
    setData([...snapshot, tempLoan]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref.read(loanRepoProvider).insertLoan(loan);
        final current = state.value ?? [];
        setData(
          current
              .map((l) => l.id == tempLoan.id ? l.copyWith(id: realId) : l)
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Loan insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> createDetailedLoan(Loan loan, {bool emitHaptic = true}) async {
    final snapshot = List<Loan>.from(state.value ?? []);
    final tempLoan = loan.copyWith(id: _tempId());
    setData([...snapshot, tempLoan]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await LoanService().createLoan(loan: loan);
        final fresh = await ref.read(loanRepoProvider).getLoans();
        setData(fresh);
      } catch (e, st) {
        debugPrint('Loan create failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(Loan loan) async {
    final snapshot = List<Loan>.from(state.value ?? []);
    setData(snapshot.map((l) => l.id == loan.id ? loan : l).toList());

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(loanRepoProvider).updateLoan(loan);
      } catch (e, st) {
        debugPrint('Loan update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> remove(Loan loan) async {
    final snapshot = List<Loan>.from(state.value ?? []);
    if (!snapshot.any((item) => item.id == loan.id)) {
      return;
    }

    setData(snapshot.where((l) => l.id != loan.id).toList());

    try {
      await performUndoableDelete<Loan>(
        ref: ref,
        label: 'Loan deleted',
        payload: loan,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(loanRepoProvider).deleteLoan(loan.id);
        }),
      );
    } catch (e, st) {
      debugPrint('Loan delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(loanRepoProvider).getLoans();
    setData(fresh);
  }
}

final loansProvider = AsyncNotifierProvider<LoansNotifier, List<Loan>>(
  LoansNotifier.new,
);

class CardsNotifier extends CachedAsyncNotifier<List<CreditCard>> {
  @override
  Future<List<CreditCard>> load() async {
    return ref.watch(creditRepoProvider).getAll();
  }

  Future<void> add(CreditCard card, {bool emitHaptic = true}) async {
    final snapshot = List<CreditCard>.from(state.value ?? []);
    final tempCard = card.copyWith(id: _tempId());
    setData([...snapshot, tempCard]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref.read(creditRepoProvider).insert(card);
        final current = state.value ?? [];
        setData(
          current
              .map((c) => c.id == tempCard.id ? c.copyWith(id: realId) : c)
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Card insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(CreditCard card) async {
    final snapshot = List<CreditCard>.from(state.value ?? []);
    setData(snapshot.map((c) => c.id == card.id ? card : c).toList());

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(creditRepoProvider).update(card);
      } catch (e, st) {
        debugPrint('Card update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> remove(String id) async {
    final snapshot = List<CreditCard>.from(state.value ?? []);
    final card = snapshot.firstWhere((c) => c.id == id);

    setData(snapshot.where((c) => c.id != id).toList());

    try {
      await performUndoableDelete<CreditCard>(
        ref: ref,
        label: 'Card deleted',
        payload: card,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(creditRepoProvider).delete(id);
        }),
      );
    } catch (e, st) {
      debugPrint('Card delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(creditRepoProvider).getAll();
    setData(fresh);
  }
}

final cardsProvider = AsyncNotifierProvider<CardsNotifier, List<CreditCard>>(
  CardsNotifier.new,
);

class CategoriesNotifier extends CachedAsyncNotifier<List<Category>> {
  @override
  Future<List<Category>> load() async {
    return ref.watch(categoryRepoProvider).getAll();
  }

  Future<void> add(Category category, {bool emitHaptic = true}) async {
    final snapshot = List<Category>.from(state.value ?? []);
    final tempCategory = category.copyWith(id: _tempId());
    setData([...snapshot, tempCategory]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref.read(categoryRepoProvider).insert(category);
        final current = state.value ?? [];
        setData(
          current
              .map(
                (item) => item.id == tempCategory.id
                    ? item.copyWith(id: realId)
                    : item,
              )
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Category insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(Category category) async {
    final snapshot = List<Category>.from(state.value ?? []);
    setData(
      snapshot.map((item) => item.id == category.id ? category : item).toList(),
    );

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(categoryRepoProvider).update(category);
      } catch (e, st) {
        debugPrint('Category update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> remove(Category category) async {
    final snapshot = List<Category>.from(state.value ?? []);
    if (!snapshot.any((item) => item.id == category.id)) {
      return;
    }

    setData(snapshot.where((item) => item.id != category.id).toList());

    try {
      await performUndoableDelete<Category>(
        ref: ref,
        label: 'Category deleted',
        payload: category,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(categoryRepoProvider).delete(category.id);
        }),
      );
    } catch (e, st) {
      debugPrint('Category delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(categoryRepoProvider).getAll();
    setData(fresh);
  }
}

final categoriesProvider =
    AsyncNotifierProvider<CategoriesNotifier, List<Category>>(
      CategoriesNotifier.new,
    );

class TagsNotifier extends CachedAsyncNotifier<List<Tag>> {
  @override
  Future<List<Tag>> load() async {
    return ref.watch(tagRepoProvider).getAll();
  }

  Future<void> add(Tag tag, {bool emitHaptic = true}) async {
    final snapshot = List<Tag>.from(state.value ?? []);
    final tempTag = tag.copyWith(id: _tempId());
    setData([...snapshot, tempTag]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref.read(tagRepoProvider).insert(tag);
        final current = state.value ?? [];
        setData(
          current
              .map(
                (item) =>
                    item.id == tempTag.id ? item.copyWith(id: realId) : item,
              )
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Tag insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(Tag tag) async {
    final snapshot = List<Tag>.from(state.value ?? []);
    setData(snapshot.map((item) => item.id == tag.id ? tag : item).toList());

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(tagRepoProvider).update(tag);
      } catch (e, st) {
        debugPrint('Tag update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> remove(Tag tag) async {
    final snapshot = List<Tag>.from(state.value ?? []);
    if (!snapshot.any((item) => item.id == tag.id)) {
      return;
    }

    setData(snapshot.where((item) => item.id != tag.id).toList());

    try {
      await performUndoableDelete<Tag>(
        ref: ref,
        label: 'Tag deleted',
        payload: tag,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(tagRepoProvider).delete(tag.id);
        }),
      );
    } catch (e, st) {
      debugPrint('Tag delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(tagRepoProvider).getAll();
    setData(fresh);
  }
}

final tagsProvider = AsyncNotifierProvider<TagsNotifier, List<Tag>>(
  TagsNotifier.new,
);

class BudgetsNotifier extends CachedAsyncNotifier<List<Budget>> {
  @override
  Future<List<Budget>> load() async {
    return ref.watch(budgetRepoProvider).getAll();
  }

  Future<void> add(Budget budget, {bool emitHaptic = true}) async {
    final snapshot = List<Budget>.from(state.value ?? []);
    final tempBudget = budget.copyWith(id: _tempId());
    setData([...snapshot, tempBudget]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref.read(budgetRepoProvider).insert(budget);
        final current = state.value ?? [];
        setData(
          current
              .map((b) => b.id == tempBudget.id ? b.copyWith(id: realId) : b)
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Budget insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(Budget budget) async {
    final snapshot = List<Budget>.from(state.value ?? []);
    setData(snapshot.map((b) => b.id == budget.id ? budget : b).toList());

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(budgetRepoProvider).update(budget);
      } catch (e, st) {
        debugPrint('Budget update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> updateLimit(String budgetId, double newLimit) async {
    final snapshot = List<Budget>.from(state.value ?? []);
    final existing = snapshot.firstWhere((budget) => budget.id == budgetId);
    await replace(existing.copyWith(limit: newLimit));
  }

  Future<void> remove(Budget budget) async {
    final snapshot = List<Budget>.from(state.value ?? []);
    if (!snapshot.any((item) => item.id == budget.id)) {
      return;
    }

    setData(snapshot.where((item) => item.id != budget.id).toList());

    try {
      await performUndoableDelete<Budget>(
        ref: ref,
        label: 'Budget deleted',
        payload: budget,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(budgetRepoProvider).delete(budget.id);
        }),
      );
    } catch (e, st) {
      debugPrint('Budget delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(budgetRepoProvider).getAll();
    setData(fresh);
  }
}

final budgetsProvider = AsyncNotifierProvider<BudgetsNotifier, List<Budget>>(
  BudgetsNotifier.new,
);

class RecurringNotifier extends CachedAsyncNotifier<List<RecurringTemplate>> {
  @override
  Future<List<RecurringTemplate>> load() async {
    return ref.watch(recurringRepoProvider).getAll();
  }

  Future<void> add(RecurringTemplate template, {bool emitHaptic = true}) async {
    final snapshot = List<RecurringTemplate>.from(state.value ?? []);
    final tempTemplate = template.copyWith(id: _tempId());
    setData([...snapshot, tempTemplate]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        final realId = await ref.read(recurringRepoProvider).insert(template);
        final current = state.value ?? [];
        setData(
          current
              .map(
                (item) => item.id == tempTemplate.id
                    ? item.copyWith(id: realId)
                    : item,
              )
              .toList(),
        );
      } catch (e, st) {
        debugPrint('Recurring template insert failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> replace(RecurringTemplate template) async {
    final snapshot = List<RecurringTemplate>.from(state.value ?? []);
    setData(
      snapshot.map((item) => item.id == template.id ? template : item).toList(),
    );

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(recurringRepoProvider).update(template);
      } catch (e, st) {
        debugPrint('Recurring template update failed: $e');
        setData(snapshot);
        setError(e, st);
      }
    });
  }

  Future<void> remove(RecurringTemplate template) async {
    final snapshot = List<RecurringTemplate>.from(state.value ?? []);
    if (!snapshot.any((item) => item.id == template.id)) {
      return;
    }

    setData(snapshot.where((item) => item.id != template.id).toList());

    try {
      await performUndoableDelete<RecurringTemplate>(
        ref: ref,
        label: 'Recurring payment deleted',
        payload: template,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(snapshot),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(recurringRepoProvider).delete(template.id);
        }),
      );
    } catch (e, st) {
      debugPrint('Recurring template delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(recurringRepoProvider).getAll();
    setData(fresh);
  }
}

final recurringProvider =
    AsyncNotifierProvider<RecurringNotifier, List<RecurringTemplate>>(
      RecurringNotifier.new,
    );

class NetWorthHistoryNotifier
    extends CachedAsyncNotifier<List<NetWorthSnapshotRecord>> {
  @override
  Future<List<NetWorthSnapshotRecord>> load() async {
    return ref.watch(netWorthRepoProvider).getSnapshotRecords(limit: 500);
  }

  Future<void> add(NetWorthSnapshotRecord snapshot) async {
    final current = List<NetWorthSnapshotRecord>.from(state.value ?? []);
    final optimistic = [...current, snapshot]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    setData(optimistic);

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref
            .read(netWorthRepoProvider)
            .insertSnapshot(
              id: snapshot.id,
              netWorth: snapshot.netWorth,
              assets: snapshot.assets,
              liabilities: snapshot.liabilities,
              timestamp: snapshot.timestamp,
            );
      } catch (e, st) {
        debugPrint('Net worth snapshot restore failed: $e');
        setData(current);
        setError(e, st);
      }
    });
  }

  Future<void> remove(NetWorthSnapshotRecord snapshot) async {
    final current = List<NetWorthSnapshotRecord>.from(state.value ?? []);
    if (!current.any((item) => item.id == snapshot.id)) {
      return;
    }

    setData(current.where((item) => item.id != snapshot.id).toList());

    try {
      await performUndoableDelete<NetWorthSnapshotRecord>(
        ref: ref,
        label: 'Snapshot deleted',
        payload: snapshot,
        undo: (item) => add(item),
        rollback: () => setData(current),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref.read(netWorthRepoProvider).deleteSnapshot(snapshot.id);
        }),
      );
    } catch (e, st) {
      debugPrint('Net worth snapshot delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref
        .read(netWorthRepoProvider)
        .getSnapshotRecords(limit: 500);
    setData(fresh);
  }
}

final netWorthHistoryProvider =
    AsyncNotifierProvider<
      NetWorthHistoryNotifier,
      List<NetWorthSnapshotRecord>
    >(NetWorthHistoryNotifier.new);

class ReminderNotifier extends CachedAsyncNotifier<List<Reminder>> {
  @override
  Future<List<Reminder>> load() async {
    return ref.watch(reminderRepoProvider).getAll();
  }

  Future<void> add(Reminder reminder, {bool emitHaptic = true}) async {
    final current = List<Reminder>.from(state.value ?? []);
    final tempReminder = reminder.copyWith(id: _tempId());
    setData([...current, tempReminder]);
    if (emitHaptic) {
      HapticService.instance.tap();
    }

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(reminderRepoProvider).upsert(reminder);
        final fresh =
            current.where((item) => item.id != tempReminder.id).toList()
              ..add(reminder);
        setData(fresh);
      } catch (e, st) {
        debugPrint('Reminder insert failed: $e');
        setData(current);
        setError(e, st);
      }
    });
  }

  Future<void> replace(Reminder reminder) async {
    final current = List<Reminder>.from(state.value ?? []);
    setData(
      current.map((item) => item.id == reminder.id ? reminder : item).toList(),
    );

    await ref.read(writeQueueProvider).enqueue(() async {
      try {
        await ref.read(reminderRepoProvider).update(reminder);
      } catch (e, st) {
        debugPrint('Reminder update failed: $e');
        setData(current);
        setError(e, st);
      }
    });
  }

  Future<void> remove(Reminder reminder) async {
    final current = List<Reminder>.from(state.value ?? []);
    if (!current.any((item) => item.id == reminder.id)) {
      return;
    }

    setData(current.where((item) => item.id != reminder.id).toList());

    try {
      await performUndoableDelete<Reminder>(
        ref: ref,
        label: 'Reminder deleted',
        payload: reminder,
        undo: (item) => add(item, emitHaptic: false),
        rollback: () => setData(current),
        repositoryDelete: () => ref.read(writeQueueProvider).enqueue(() async {
          await ref
              .read(reminderRepoProvider)
              .deleteGlobalReminder(reminder.id);
        }),
      );
    } catch (e, st) {
      debugPrint('Reminder delete failed: $e');
      setError(e, st);
    }
  }

  Future<void> refresh() async {
    final fresh = await ref.read(reminderRepoProvider).getAll();
    setData(fresh);
  }
}

final remindersProvider =
    AsyncNotifierProvider<ReminderNotifier, List<Reminder>>(
      ReminderNotifier.new,
    );

// --- Analytics: Batched Summary Computation ---

final analyticsSummaryProvider = Provider<AnalyticsSummary>((ref) {
  // Watch all core data sources
  final txns = ref.watch(transactionsProvider).valueOrNull ?? [];
  final accounts = ref.watch(accountsProvider).valueOrNull ?? [];
  final loans = ref.watch(loansProvider).valueOrNull ?? [];
  final cards = ref.watch(cardsProvider).valueOrNull ?? [];
  final categories = ref.watch(categoriesProvider).valueOrNull ?? [];
  final budgets = ref.watch(budgetsProvider).valueOrNull ?? [];

  debugPrint('\u{1F4CA} Analytics provider: txns=${txns.length}, '
      'accounts=${accounts.length}, loans=${loans.length}, cards=${cards.length}');

  // Create bundle for service processing
  final bundle = AnalyticsBundle(
    transactions: txns,
    accounts: accounts,
    loans: loans,
    cards: cards,
    categories: categories,
    budgets: budgets,
  );

  return ref.read(analyticsServiceProvider).computeSummary(bundle);
});

// Memoized Selectors to prevent over-building widgets
final netWorthProvider = Provider<double>(
  (ref) => ref.watch(analyticsSummaryProvider.select((s) => s.netWorth)),
);
final netWorthSummaryProvider =
    FutureProvider<({double assets, double liabilities, double netWorth})>((
      ref,
    ) async {
      return ref.read(netWorthServiceProvider).calculate();
    });
final categorySpendingProvider = Provider<Map<String, double>>(
  (ref) =>
      ref.watch(analyticsSummaryProvider.select((s) => s.categorySpending)),
);
final budgetSummaryProvider =
    Provider<List<({Budget budget, Category category, double spent})>>(
      (ref) =>
          ref.watch(analyticsSummaryProvider.select((s) => s.budgetProgress)),
    );
final dashboardTransactionsProvider = Provider<List<Transaction>>(
  (ref) =>
      ref.watch(analyticsSummaryProvider.select((s) => s.recentTransactions)),
);

final insightsProvider = Provider<List<Insight>>((ref) {
  final summary = ref.watch(analyticsSummaryProvider);
  return ref.read(insightEngineProvider).generate(summary);
});

// --- Reports: Unified Dashboard Data ---

final reportsPeriodProvider = StateProvider<int>(
  (ref) => 6,
); // Default 6 months

final reportsSummaryProvider = FutureProvider<ReportsSummary>((ref) async {
  final service = ref.watch(reportsServiceProvider);
  final monthsBack = ref.watch(reportsPeriodProvider);
  return await service.computeSummary(monthsBack);
});

// --- Lifecycle & Sync Orchestration ---

final lifecycleProvider = StreamProvider<AppLifecycleState>((ref) {
  final observer = _LifecycleObserver();
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  return observer.stream;
});

class _LifecycleObserver extends WidgetsBindingObserver {
  final _controller = StreamController<AppLifecycleState>();
  Stream<AppLifecycleState> get stream => _controller.stream;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.add(state);
  }
}

final silenceSyncProvider = Provider<void>((ref) {
  ref.listen(lifecycleProvider, (previous, next) {
    if (next.value == AppLifecycleState.resumed) {
      ref.read(appDataSyncManagerProvider).syncAll();
    }
  });
});
