import 'package:sqflite/sqflite.dart' hide Transaction;

import '../data/core/app_database.dart';
import '../data/core/tables.dart';
import '../data/repositories/credit_repo.dart';
import '../data/repositories/loan_repo.dart';
import '../data/repositories/transaction_repo.dart';
import '../models/credit_transaction.dart';
import '../models/ledger_transaction.dart';
import '../models/transaction.dart';

/// Orchestration service for financial transaction workflows in SpendX 2.0.
///
/// Under the canonical double-entry architecture (Milestone C3B-6):
///   - Authoritative financial state is governed strictly by canonical repositories:
///     [TransactionRepo], [AccountRepo], [CreditRepo], and [LoanRepo].
///   - Authoritative accounting events are persisted in `economic_events` and `postings`.
///   - Account balances are dynamically derived from canonical postings.
///   - This service orchestrates cross-domain workflows (transactions, credit side-effects,
///     and loan repayments) and delegates strictly to canonical repositories.
///   - Direct authoritative mutations to `bank_accounts.balance`, `credit_cards.used_amount`,
///     or `loans.paid_amount` are strictly prohibited.
class FinancialTransactionService {
  final Database? database;
  final TransactionRepo? _customTransactionRepo;
  final CreditRepo? _customCreditRepo;
  final LoanRepo? _customLoanRepo;

  FinancialTransactionService({
    this.database,
    TransactionRepo? transactionRepo,
    CreditRepo? creditRepo,
    LoanRepo? loanRepo,
  })  : _customTransactionRepo = transactionRepo,
        _customCreditRepo = creditRepo,
        _customLoanRepo = loanRepo;

  Future<Database> get _db async =>
      database ?? await AppDatabase.instance.database;

  TransactionRepo _getTransactionRepo(DatabaseExecutor executor) {
    if (_customTransactionRepo?.executor != null) {
      return _customTransactionRepo!;
    }
    return TransactionRepo(executor: executor);
  }

  CreditRepo _getCreditRepo(DatabaseExecutor executor) {
    if (_customCreditRepo?.executor != null) {
      return _customCreditRepo!;
    }
    return CreditRepo(executor: executor);
  }

  LoanRepo _getLoanRepo(DatabaseExecutor executor) {
    if (_customLoanRepo?.executor != null) {
      return _customLoanRepo!;
    }
    return LoanRepo(executor: executor);
  }

  Future<bool> _hasCanonicalSchema(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='${TablesV24.economicEvents}'",
    );
    return rows.isNotEmpty;
  }

  Future<bool> _hasTable(DatabaseExecutor db, String tableName) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [tableName],
    );
    return rows.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Impact + ledger helpers (preserved for transitional compatibility)
  // ---------------------------------------------------------------------------

  static const Set<LedgerType> _negative = {
    LedgerType.expense,
    LedgerType.credit_payment,
    LedgerType.emi_installment,
    LedgerType.loan_payment,
    LedgerType.transfer,
    LedgerType.lending_given,
    LedgerType.fuel_expense,
    LedgerType.processing_fee,
    LedgerType.interest_charge,
  };

  /// Signed contribution of a normal ledger event to its account.
  static double _signed(LedgerType type, double amount) =>
      _negative.contains(type) ? -amount : amount;

  static LedgerType _typeFor(String type) {
    switch (type) {
      case 'income':
        return LedgerType.income;
      case 'expense':
        return LedgerType.expense;
      case 'transfer':
        return LedgerType.transfer;
      case 'fuel_expense':
        return LedgerType.fuel_expense;
      case 'processing_fee':
        return LedgerType.processing_fee;
      case 'interest_charge':
        return LedgerType.interest_charge;
      case 'refund':
        return LedgerType.refund;
      default:
        return LedgerType.expense;
    }
  }

  /// Bank-account ledger legs for a transaction.
  List<LedgerTransaction> _bankLegs(Transaction tx, {String? referenceId}) {
    final ref = referenceId ?? tx.id;
    if (tx.source == 'credit_card_purchase') return const [];

    switch (tx.type) {
      case 'transfer':
        final legs = <LedgerTransaction>[];
        if (tx.accountId != null && tx.accountId!.isNotEmpty) {
          legs.add(
            LedgerTransaction(
              type: LedgerType.transfer,
              amount: tx.amount,
              date: tx.date,
              accountId: tx.accountId,
              categoryId: tx.categoryId,
              note: tx.notes,
              referenceId: ref,
            ),
          );
        }
        if (tx.relatedEntityId != null && tx.relatedEntityId!.isNotEmpty) {
          legs.add(
            LedgerTransaction(
              type: LedgerType.income,
              amount: tx.amount,
              date: tx.date,
              accountId: tx.relatedEntityId,
              categoryId: tx.categoryId,
              note: tx.notes,
              referenceId: ref,
            ),
          );
        }
        return legs;

      case 'income':
      case 'expense':
      case 'fuel_expense':
      case 'processing_fee':
      case 'interest_charge':
      case 'refund':
        if (tx.accountId == null || tx.accountId!.isEmpty) return const [];
        return [
          LedgerTransaction(
            type: _typeFor(tx.type),
            amount: tx.amount,
            date: tx.date,
            accountId: tx.accountId,
            categoryId: tx.categoryId,
            note: tx.notes,
            referenceId: ref,
          ),
        ];

      default:
        return [
          LedgerTransaction(
            type: LedgerType.expense,
            amount: tx.amount,
            date: tx.date,
            accountId: tx.accountId,
            categoryId: tx.categoryId,
            note: tx.notes,
            referenceId: ref,
          ),
        ];
    }
  }

  /// Bank-account balance deltas for a transaction.
  Map<String, double> _bankDeltas(Transaction tx) {
    final deltas = <String, double>{};
    if (tx.source == 'credit_card_purchase') return deltas;

    if (tx.type == 'transfer') {
      final from = tx.accountId;
      final to = tx.relatedEntityId;
      if (from != null && to != null && from == to) return deltas;
      if (from != null && from.isNotEmpty) {
        deltas[from] = (deltas[from] ?? 0) - tx.amount;
      }
      if (to != null && to.isNotEmpty) {
        deltas[to] = (deltas[to] ?? 0) + tx.amount;
      }
      return deltas;
    }

    final a = tx.accountId;
    if (a == null || a.isEmpty) return deltas;

    const negatives = {
      'expense',
      'fuel_expense',
      'processing_fee',
      'interest_charge',
    };
    deltas[a] = (deltas[a] ?? 0) + (negatives.contains(tx.type) ? -tx.amount : tx.amount);
    return deltas;
  }

  Map<String, double> _subtractDeltas(
    Map<String, double> a,
    Map<String, double> b,
  ) {
    final out = <String, double>{...a};
    for (final e in b.entries) {
      out[e.key] = (out[e.key] ?? 0) - e.value;
    }
    return out;
  }

  void _verifyLegsMatchDeltas(
    List<LedgerTransaction> legs,
    Map<String, double> expectedDeltas,
  ) {
    final sum = <String, double>{};
    for (final leg in legs) {
      if (leg.accountId == null || leg.accountId!.isEmpty) continue;
      final signed = (leg.type == LedgerType.reversal ||
              leg.type == LedgerType.correction)
          ? leg.amount
          : _signed(leg.type, leg.amount);
      sum[leg.accountId!] = (sum[leg.accountId!] ?? 0) + signed;
    }
    for (final e in expectedDeltas.entries) {
      if ((sum[e.key] ?? 0) != e.value) {
        throw StateError(
          'Phase2 invariant violated for account ${e.key}: '
          'ledger delta ${sum[e.key] ?? 0} != applied delta ${e.value}',
        );
      }
    }
  }

  Future<void> _applyAndVerify(
    DatabaseExecutor t,
    List<LedgerTransaction> legs,
    Map<String, double> expectedDeltas,
  ) async {
    _verifyLegsMatchDeltas(legs, expectedDeltas);
    final now = DateTime.now().toIso8601String();
    for (final e in expectedDeltas.entries) {
      if (e.value == 0) continue;
      await t.rawUpdate(
        'UPDATE ${Tables.bankAccounts} '
        'SET balance = balance + ?, updated_at = ? WHERE id = ?',
        [e.value, now, e.key],
      );
    }
  }

  Future<int> _revSeq(DatabaseExecutor t, String id) async {
    final rows = await t.query(
      Tables.ledgerTransactions,
      where: 'reference_id LIKE ?',
      whereArgs: ['$id:rev:%'],
    );
    return rows.length + 1;
  }

  // ---------------------------------------------------------------------------
  // Public API (CANONICAL_FINANCIAL & TRANSITIONAL_COMPATIBILITY)
  // ---------------------------------------------------------------------------

  /// Creates an expense transaction. Delegates to [createTransaction].
  Future<void> createExpense(Transaction tx, {DatabaseExecutor? txn}) =>
      createTransaction(tx, txn: txn);

  /// Creates an income transaction. Delegates to [createTransaction].
  Future<void> createIncome(Transaction tx, {DatabaseExecutor? txn}) =>
      createTransaction(tx, txn: txn);

  /// Creates a transfer transaction. Delegates to [createTransaction].
  Future<void> createTransfer(Transaction tx, {DatabaseExecutor? txn}) =>
      createTransaction(tx, txn: txn);

  /// Orchestrates the creation of a financial transaction.
  ///
  /// Under canonical v24 schema:
  /// - Delegates primary financial creation to [TransactionRepo.insert].
  /// - Delegates credit card purchase side-effects to [CreditRepo.insertTransaction].
  /// - Delegates loan repayment side-effects to [LoanRepo.recordRepayment].
  /// - ZERO direct authoritative writes to `bank_accounts.balance`.
  /// - Enclosed in an atomic transaction boundary.
  Future<void> createTransaction(
    Transaction tx, {
    CreditTransaction? creditTxn,
    String? loanId,
    double? loanPaidDelta,
    DatabaseExecutor? txn,
    bool insertSource = true,
  }) async {
    final db = txn ?? await _db;
    final isCanonical = await _hasCanonicalSchema(db);

    if (isCanonical) {
      Future<void> canonicalFlow(DatabaseExecutor t) async {
        if (creditTxn != null) {
          // 1. Credit-card financial mutation routed exclusively through CreditRepo
          final crRepo = _getCreditRepo(t);
          await crRepo.insertTransaction(creditTxn);
        } else if (loanId != null && loanPaidDelta != null && loanPaidDelta > 0) {
          // 2. Loan repayment financial mutation routed exclusively through LoanRepo
          final lnRepo = _getLoanRepo(t);
          final assetAcc = tx.accountId ?? 'bank_default';
          final principal = loanPaidDelta;
          final interest = (tx.amount - loanPaidDelta).clamp(0.0, double.infinity);
          if (interest > 0) {
            await lnRepo.recordCombinedPayment(
              loanId: loanId,
              assetAccountId: assetAcc,
              principalAmount: principal,
              interestAmount: interest,
              timestamp: tx.date,
              description: tx.notes,
            );
          } else {
            await lnRepo.recordRepayment(
              loanId: loanId,
              assetAccountId: assetAcc,
              principalAmount: principal,
              timestamp: tx.date,
              description: tx.notes,
            );
          }
        } else {
          // 3. Standard transaction routed through TransactionRepo
          final txRepo = _getTransactionRepo(t);
          await txRepo.insert(tx);
        }
      }

      if (txn != null) {
        await canonicalFlow(txn);
      } else if (db is Database) {
        await db.transaction((t) => canonicalFlow(t));
      } else {
        await canonicalFlow(db);
      }
      return;
    }

    // Pre-v24 legacy transitional implementation
    Future<void> legacyFlow(DatabaseExecutor t) async {
      if (insertSource) {
        await t.insert(Tables.transactions, tx.toMap());
      }

      final legs = _bankLegs(tx);
      for (final leg in legs) {
        await t.insert(Tables.ledgerTransactions, leg.toMap());
      }

      if (creditTxn != null) {
        await t.insert(Tables.creditTransactions, creditTxn.toMap());
        await t.insert(
          Tables.ledgerTransactions,
          LedgerTransaction(
            type: LedgerType.credit_purchase,
            amount: creditTxn.amount,
            date: creditTxn.date,
            creditCardId: creditTxn.cardId,
            categoryId: creditTxn.categoryId,
            note: creditTxn.note,
            referenceId: creditTxn.id,
          ).toMap(),
        );
        await t.rawUpdate(
          'UPDATE ${Tables.creditCards} '
          'SET used_amount = MAX(0, used_amount + ?) WHERE id = ?',
          [creditTxn.amount, creditTxn.cardId],
        );
      }

      if (loanId != null && loanPaidDelta != null && loanPaidDelta != 0) {
        await t.rawUpdate(
          'UPDATE ${Tables.loans} SET paid_amount = paid_amount + ? WHERE id = ?',
          [loanPaidDelta, loanId],
        );
      }

      await _applyAndVerify(t, legs, _bankDeltas(tx));
    }

    if (txn != null) return legacyFlow(txn);
    final database = await _db;
    await database.transaction((t) => legacyFlow(t));
  }

  /// Edits an existing transaction.
  ///
  /// Under canonical v24 schema:
  /// - Delegates to [TransactionRepo.update] which enforces posted immutability
  ///   via append-only reversal and replacement events.
  Future<void> editTransaction({
    required Transaction oldTransaction,
    required Transaction newTransaction,
    DatabaseExecutor? txn,
  }) async {
    final db = txn ?? await _db;
    final isCanonical = await _hasCanonicalSchema(db);

    if (isCanonical) {
      Future<void> canonicalEdit(DatabaseExecutor t) async {
        final txRepo = _getTransactionRepo(t);
        await txRepo.update(newTransaction);
      }

      if (txn != null) {
        await canonicalEdit(txn);
      } else if (db is Database) {
        await db.transaction((t) => canonicalEdit(t));
      } else {
        await canonicalEdit(db);
      }
      return;
    }

    // Pre-v24 legacy flow
    Future<void> legacyEdit(DatabaseExecutor t) async {
      final oldLegs = _bankLegs(oldTransaction);
      final seq = await _revSeq(t, oldTransaction.id);
      final newLegs = _bankLegs(
        newTransaction,
        referenceId: '${oldTransaction.id}:corr:$seq',
      );

      final revLegs = oldLegs.map((l) {
        return LedgerTransaction(
          type: LedgerType.reversal,
          amount: -_signed(l.type, l.amount),
          date: newTransaction.date,
          accountId: l.accountId,
          categoryId: l.categoryId,
          note: 'reversal:${l.referenceId}',
          referenceId: '${oldTransaction.id}:rev:$seq',
        );
      }).toList();

      for (final r in revLegs) {
        await t.insert(Tables.ledgerTransactions, r.toMap());
      }
      for (final n in newLegs) {
        await t.insert(Tables.ledgerTransactions, n.toMap());
      }

      await t.update(
        Tables.transactions,
        newTransaction.toMap(),
        where: 'id = ?',
        whereArgs: [newTransaction.id],
      );

      final expected = _subtractDeltas(
        _bankDeltas(newTransaction),
        _bankDeltas(oldTransaction),
      );
      await _applyAndVerify(t, [...revLegs, ...newLegs], expected);
    }

    if (txn != null) return legacyEdit(txn);
    final database = await _db;
    await database.transaction((t) => legacyEdit(t));
  }

  /// Deletes an existing transaction.
  ///
  /// Under canonical v24 schema:
  /// - Delegates to [TransactionRepo.delete] which enforces posted immutability
  ///   via a balanced reversal event and soft-archival.
  Future<void> deleteTransaction(
    String transactionId, {
    Transaction? oldTransaction,
    DatabaseExecutor? txn,
  }) async {
    final db = txn ?? await _db;
    final isCanonical = await _hasCanonicalSchema(db);

    if (isCanonical) {
      Future<void> canonicalDelete(DatabaseExecutor t) async {
        final txRepo = _getTransactionRepo(t);
        await txRepo.delete(transactionId);
      }

      if (txn != null) {
        await canonicalDelete(txn);
      } else if (db is Database) {
        await db.transaction((t) => canonicalDelete(t));
      } else {
        await canonicalDelete(db);
      }
      return;
    }

    // Pre-v24 legacy flow
    Future<void> legacyDelete(DatabaseExecutor t) async {
      final old = oldTransaction ??
          Transaction.fromMap(
            (await t.query(
              Tables.transactions,
              where: 'id = ?',
              whereArgs: [transactionId],
              limit: 1,
            ))
                .first,
          );

      final oldLegs = _bankLegs(old);
      final seq = await _revSeq(t, old.id);
      final revLegs = oldLegs.map((l) {
        return LedgerTransaction(
          type: LedgerType.reversal,
          amount: -_signed(l.type, l.amount),
          date: old.date,
          accountId: l.accountId,
          categoryId: l.categoryId,
          note: 'cancel:${l.referenceId}',
          referenceId: '${old.id}:rev:$seq',
        );
      }).toList();

      for (final r in revLegs) {
        await t.insert(Tables.ledgerTransactions, r.toMap());
      }
      await t.delete(
        Tables.transactions,
        where: 'id = ?',
        whereArgs: [transactionId],
      );

      final expected = <String, double>{};
      for (final e in _bankDeltas(old).entries) {
        expected[e.key] = -e.value;
      }
      await _applyAndVerify(t, revLegs, expected);
    }

    if (txn != null) return legacyDelete(txn);
    final database = await _db;
    await database.transaction((t) => legacyDelete(t));
  }

  /// Appends a transitional compatibility ledger row.
  ///
  /// This method exists strictly for legacy domain callers (e.g. CreditCardService,
  /// LoanService) during the transition. It writes to the compatibility
  /// [Tables.ledgerTransactions] table and updates the legacy [Tables.bankAccounts]
  /// balance cache as a non-authoritative projection.
  /// Financial authority resides solely in canonical postings.
  Future<void> appendLedger(LedgerTransaction leg) async {
    final db = await _db;
    await db.transaction((t) async {
      final hasLedgerTable = await _hasTable(t, Tables.ledgerTransactions);
      if (hasLedgerTable) {
        await t.insert(Tables.ledgerTransactions, leg.toMap());
      }
      if (leg.accountId == null || leg.accountId!.isEmpty) return;
      final hasBankTable = await _hasTable(t, Tables.bankAccounts);
      if (hasBankTable) {
        final signed = _signed(leg.type, leg.amount);
        await _applyAndVerify(t, [leg], {leg.accountId!: signed});
      }
    });
  }

  /// Removes a transitional compatibility ledger row.
  Future<void> removeLedger({
    required String referenceId,
    String? type,
  }) async {
    final db = await _db;
    final hasLedgerTable = await _hasTable(db, Tables.ledgerTransactions);
    if (!hasLedgerTable) return;

    if (type != null) {
      await db.delete(
        Tables.ledgerTransactions,
        where: 'reference_id = ? AND type = ?',
        whereArgs: [referenceId, type],
      );
    } else {
      await db.delete(
        Tables.ledgerTransactions,
        where: 'reference_id = ?',
        whereArgs: [referenceId],
      );
    }
  }
}
