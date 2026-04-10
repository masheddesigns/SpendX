import 'package:flutter/widgets.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/core/app_database.dart';
import '../../../data/providers.dart' as app_data;
import '../../../data/repositories/credit_repo.dart';
import '../../../data/repositories/transaction_repo.dart';
import '../../../models/category.dart';
import '../../../models/credit_transaction.dart';
import '../../../models/transaction.dart';
import '../../../services/gamification_service.dart';
import '../../../services/data_audit_service.dart';
import '../../accounts/providers/account_providers.dart';
import '../../categories/providers/category_providers.dart';

final transactionRepoProvider = Provider<TransactionRepo>((ref) {
  return TransactionRepo();
});

/// Single source of truth — re-exported from data/providers.dart.
/// All invalidation and watches go through this one provider.
final transactionsProvider = app_data.transactionsProvider;

final transactionCategoryMapProvider = FutureProvider<Map<String, Category>>((
  ref,
) async {
  final categories = await ref.watch(categoriesProvider.future);
  return {for (final item in categories) item.id: item};
});

// ---------------------------------------------------------------------------
// Paginated transactions — loads 30 at a time for performance
// ---------------------------------------------------------------------------

class PaginatedTransactionsState {
  final List<Transaction> items;
  final bool hasMore;
  final bool isLoadingMore;

  const PaginatedTransactionsState({
    this.items = const [],
    this.hasMore = true,
    this.isLoadingMore = false,
  });

  PaginatedTransactionsState copyWith({
    List<Transaction>? items,
    bool? hasMore,
    bool? isLoadingMore,
  }) =>
      PaginatedTransactionsState(
        items: items ?? this.items,
        hasMore: hasMore ?? this.hasMore,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      );
}

class PaginatedTransactionsNotifier
    extends StateNotifier<PaginatedTransactionsState> {
  final TransactionRepo _repo;
  static const _pageSize = 30;
  int _offset = 0;
  bool _loading = false;

  PaginatedTransactionsNotifier(this._repo)
      : super(const PaginatedTransactionsState()) {
    loadInitial();
  }

  Future<void> loadInitial() async {
    if (_loading) return;
    _loading = true;
    _offset = 0;
    final data = await _repo.getAll(limit: _pageSize, offset: 0);
    _offset = data.length;
    state = PaginatedTransactionsState(
      items: data,
      hasMore: data.length >= _pageSize,
    );
    _loading = false;
    debugPrint('📦 Transactions: loaded ${data.length} (paginated)');
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoadingMore) return;
    state = state.copyWith(isLoadingMore: true);

    final data = await _repo.getAll(limit: _pageSize, offset: _offset);
    _offset += data.length;
    state = state.copyWith(
      items: [...state.items, ...data],
      hasMore: data.length >= _pageSize,
      isLoadingMore: false,
    );
  }

  Future<void> refresh() async {
    _loading = false; // allow reload
    await loadInitial();
  }
}

final paginatedTransactionsProvider = StateNotifierProvider<
    PaginatedTransactionsNotifier, PaginatedTransactionsState>(
  (ref) => PaginatedTransactionsNotifier(ref.read(transactionRepoProvider)),
);

// ---------------------------------------------------------------------------
// Shared impact logic — SINGLE SOURCE OF TRUTH
// ---------------------------------------------------------------------------

/// Compute the bank-account balance delta for a single transaction.
/// Accumulates into [accountDeltas] map (accountId -> delta).
///
/// Rules (matching the original _applyTransactionImpact exactly):
///   1. credit_card_purchase → NO bank balance change
///   2. transfer → deduct from source, add to destination (skip self-transfers)
///   3. expense → subtract from account
///   4. income → add to account
void computeAccountImpact(
  Transaction tx,
  Map<String, double> accountDeltas,
) {
  // Credit card purchases don't touch bank balances
  if (tx.source == 'credit_card_purchase') return;

  // Transfers: deduct from source, add to destination
  if (tx.type == 'transfer') {
    final fromId = tx.accountId;
    final toId = tx.relatedEntityId;

    // Self-transfer guard
    if (fromId != null && toId != null && fromId == toId) return;

    if (fromId != null && fromId.isNotEmpty) {
      accountDeltas[fromId] = (accountDeltas[fromId] ?? 0) - tx.amount;
    }
    if (toId != null && toId.isNotEmpty) {
      accountDeltas[toId] = (accountDeltas[toId] ?? 0) + tx.amount;
    }
    return;
  }

  // Income/expense on a bank account
  final accountId = tx.accountId;
  if (accountId == null || accountId.isEmpty) return;

  if (tx.type == 'expense') {
    accountDeltas[accountId] = (accountDeltas[accountId] ?? 0) - tx.amount;
  } else {
    // income
    accountDeltas[accountId] = (accountDeltas[accountId] ?? 0) + tx.amount;
  }
}

/// Reverse of [computeAccountImpact] — used when updating/deleting.
void revertAccountImpact(
  Transaction tx,
  Map<String, double> accountDeltas,
) {
  if (tx.source == 'credit_card_purchase') return;

  if (tx.type == 'transfer') {
    final fromId = tx.accountId;
    final toId = tx.relatedEntityId;

    if (fromId != null && toId != null && fromId == toId) return;

    if (fromId != null && fromId.isNotEmpty) {
      accountDeltas[fromId] = (accountDeltas[fromId] ?? 0) + tx.amount;
    }
    if (toId != null && toId.isNotEmpty) {
      accountDeltas[toId] = (accountDeltas[toId] ?? 0) - tx.amount;
    }
    return;
  }

  final accountId = tx.accountId;
  if (accountId == null || accountId.isEmpty) return;

  if (tx.type == 'expense') {
    accountDeltas[accountId] = (accountDeltas[accountId] ?? 0) + tx.amount;
  } else {
    accountDeltas[accountId] = (accountDeltas[accountId] ?? 0) - tx.amount;
  }
}

// ---------------------------------------------------------------------------
// Single transaction providers (manual add / edit / delete)
// ---------------------------------------------------------------------------

final addTransactionProvider = Provider((ref) {
  return (Transaction transaction) async {
    final txRepo = ref.read(transactionRepoProvider);
    final accRepo = ref.read(accountRepoProvider);

    debugPrint('➡️ Adding transaction: ${transaction.amount}');
    await txRepo.create(transaction);
    debugPrint('✅ Transaction inserted');

    // Use shared impact logic
    final deltas = <String, double>{};
    computeAccountImpact(transaction, deltas);
    for (final entry in deltas.entries) {
      await accRepo.adjustBalance(entry.key, entry.value);
    }

    final allTransactions = await txRepo.getAll();
    debugPrint('📊 Total transactions: ${allTransactions.length}');

    // Award XP for adding a transaction
    try {
      await GamificationService.instance.addXP(10, isTransaction: true);
    } catch (_) {}

    ref.invalidate(transactionsProvider);
    ref.invalidate(accountsProvider);
    DataAuditService.instance.invalidateCache();
  };
});

final updateTransactionProvider = Provider((ref) {
  return ({
    required Transaction oldTransaction,
    required Transaction newTransaction,
  }) async {
    final accRepo = ref.read(accountRepoProvider);
    final txRepo = ref.read(transactionRepoProvider);

    // Use shared impact logic: revert old, apply new
    final deltas = <String, double>{};
    revertAccountImpact(oldTransaction, deltas);
    computeAccountImpact(newTransaction, deltas);
    for (final entry in deltas.entries) {
      await accRepo.adjustBalance(entry.key, entry.value);
    }

    await txRepo.updateTransaction(newTransaction);
    ref.invalidate(accountsProvider);
    ref.invalidate(transactionsProvider);
    DataAuditService.instance.invalidateCache();
  };
});

final deleteTransactionProvider = Provider((ref) {
  return (String transactionId) async {
    final txRepo = ref.read(transactionRepoProvider);
    final accRepo = ref.read(accountRepoProvider);

    // Fetch transaction BEFORE deleting to revert its balance impact
    final tx = await txRepo.getById(transactionId);
    if (tx != null) {
      final deltas = <String, double>{};
      revertAccountImpact(tx, deltas);
      for (final entry in deltas.entries) {
        await accRepo.adjustBalance(entry.key, entry.value);
      }
    }

    await txRepo.delete(transactionId);
    ref.invalidate(transactionsProvider);
    ref.invalidate(accountsProvider);
    DataAuditService.instance.invalidateCache();
  };
});

// ---------------------------------------------------------------------------
// Bulk transaction pipeline — used by SMS import
// ---------------------------------------------------------------------------

/// Data class holding a parsed transaction + its related liability side-effects.
class BulkTransactionEntry {
  final Transaction transaction;

  /// If non-null, a credit card purchase/payment. cardId -> delta to outstanding.
  final String? cardId;
  final double cardOutstandingDelta;

  /// If non-null, a credit transaction to insert for the card ledger.
  final CreditTransaction? creditTransaction;

  /// If non-null, a loan payment. loanId -> delta to paidAmount.
  final String? loanId;
  final double loanPaidDelta;

  /// SMS parser confidence score (0.0-1.0) for routing decisions.
  final double smsConfidence;

  const BulkTransactionEntry({
    required this.transaction,
    this.cardId,
    this.cardOutstandingDelta = 0,
    this.creditTransaction,
    this.loanId,
    this.loanPaidDelta = 0,
    this.smsConfidence = 1.0,
  });
}

/// Bulk-insert transactions, apply balance impacts ONLY for DB-confirmed inserts.
///
/// Correctness guarantees:
///   1. Application-level dedup (prefetch + in-batch) filters obvious duplicates
///   2. DB-level dedup (UNIQUE + ignore) is the final authority
///   3. Deltas are computed ONLY for rows the DB actually inserted
///   4. ALL writes happen in ONE SQLite transaction (atomic)
///   5. Provider invalidation happens AFTER commit
final addTransactionsBulkProvider = Provider((ref) {
  return (List<BulkTransactionEntry> entries) async {
    if (entries.isEmpty) return;

    final txRepo = ref.read(transactionRepoProvider);
    final accRepo = ref.read(accountRepoProvider);
    final creditRepo = CreditRepo();

    // ── 1. APP-LEVEL DEDUP (read-only, outside transaction) ──────────────
    final allRefs = <String>[];
    for (final e in entries) {
      final eRef = e.transaction.externalRef;
      if (eRef != null && eRef.isNotEmpty) {
        allRefs.add(eRef);
      }
    }

    final existingRefs = await txRepo.getExistingExternalRefs(allRefs);

    // Dedup within the batch itself (first occurrence wins)
    final seenInBatch = <String>{};
    final candidateEntries = <BulkTransactionEntry>[];
    for (final entry in entries) {
      final eRef = entry.transaction.externalRef;
      if (eRef != null && eRef.isNotEmpty) {
        if (existingRefs.contains(eRef)) continue;
        if (seenInBatch.contains(eRef)) continue;
        seenInBatch.add(eRef);
      }
      candidateEntries.add(entry);
    }

    if (candidateEntries.isEmpty) {
      debugPrint('📦 Bulk: all entries deduplicated, nothing to insert');
      return;
    }

    final appDedupSkipped = entries.length - candidateEntries.length;
    debugPrint('📦 Bulk: ${entries.length} entries → ${candidateEntries.length} '
        'candidates ($appDedupSkipped filtered by app dedup)');

    // ── 2. ATOMIC DB TRANSACTION — insert, confirm, then apply deltas ────
    int dbSkipped = 0;

    final database = await AppDatabase.instance.database;
    await database.transaction((dbTxn) async {
      // 2a. Insert and get back which refs the DB actually accepted
      final candidateTxns = candidateEntries.map((e) => e.transaction).toList();
      final insertedRefs = await txRepo.insertAllReturningRefsWithTxn(
        dbTxn,
        candidateTxns,
      );

      // 2b. Filter entries to ONLY those the DB confirmed inserted
      final confirmedEntries = candidateEntries.where((e) {
        final eRef = e.transaction.externalRef;
        return eRef != null && insertedRefs.contains(eRef);
      }).toList();

      dbSkipped = candidateEntries.length - confirmedEntries.length;
      if (dbSkipped > 0) {
        debugPrint('⚠️ DB-level dedup: $dbSkipped additional duplicates '
            'caught by UNIQUE constraint');
      }

      if (confirmedEntries.isEmpty) {
        debugPrint('📦 Bulk: no rows survived DB-level dedup');
        return; // transaction commits empty — no harm
      }

      // 2c. Compute deltas ONLY for confirmed inserts
      final accountDeltas = <String, double>{};
      final cardDeltas = <String, double>{};
      final creditTxns = <CreditTransaction>[];
      final loanDeltas = <String, double>{};

      for (final entry in confirmedEntries) {
        computeAccountImpact(entry.transaction, accountDeltas);

        if (entry.cardId != null && entry.cardOutstandingDelta != 0) {
          cardDeltas[entry.cardId!] =
              (cardDeltas[entry.cardId!] ?? 0) + entry.cardOutstandingDelta;
        }
        if (entry.creditTransaction != null) {
          creditTxns.add(entry.creditTransaction!);
        }

        if (entry.loanId != null && entry.loanPaidDelta != 0) {
          loanDeltas[entry.loanId!] =
              (loanDeltas[entry.loanId!] ?? 0) + entry.loanPaidDelta;
        }
      }

      // 2d. Apply all balance adjustments within same transaction
      await accRepo.adjustBalancesWithTxn(dbTxn, accountDeltas);

      if (cardDeltas.isNotEmpty) {
        await creditRepo.adjustOutstandingsWithTxn(dbTxn, cardDeltas);
      }
      if (creditTxns.isNotEmpty) {
        await creditRepo.insertTransactionsWithTxn(dbTxn, creditTxns);
      }

      if (loanDeltas.isNotEmpty) {
        final loanBatch = dbTxn.batch();
        for (final entry in loanDeltas.entries) {
          loanBatch.rawUpdate(
            'UPDATE loans SET paid_amount = paid_amount + ? WHERE id = ?',
            [entry.value, entry.key],
          );
        }
        await loanBatch.commit(noResult: true);
      }

      // 2e. Audit log (inside txn scope for accurate counts)
      debugPrint('📦 BULK COMMITTED:');
      debugPrint('   Input: ${entries.length}');
      debugPrint('   App-dedup skipped: $appDedupSkipped');
      debugPrint('   DB-dedup skipped: $dbSkipped');
      debugPrint('   Inserted: ${confirmedEntries.length}');
      debugPrint('   Accounts adjusted: ${accountDeltas.length}');
      debugPrint('   Cards adjusted: ${cardDeltas.length}');
      debugPrint('   Credit txns: ${creditTxns.length}');
      debugPrint('   Loans adjusted: ${loanDeltas.length}');
    });

    // ── 3. INVALIDATE ONCE (after commit) ────────────────────────────────
    ref.invalidate(transactionsProvider);
    ref.invalidate(accountsProvider);
    DataAuditService.instance.invalidateCache();
    debugPrint('🔄 Providers invalidated (bulk)');
  };
});
