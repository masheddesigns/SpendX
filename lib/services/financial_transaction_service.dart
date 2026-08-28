import 'package:sqflite/sqflite.dart' hide Transaction;

import '../data/core/app_database.dart';
import '../data/core/tables.dart';
import '../models/ledger_transaction.dart';
import '../models/transaction.dart';
import '../models/credit_transaction.dart';

/// CANONICAL financial mutation boundary (Phase 2A, G1–G3).
///
/// Architecture contract (locked):
///   - [Tables.ledgerTransactions] = canonical money-movement journal (source
///     of truth). The ledger is APPEND-ONLY: edits and deletes emit `reversal`
///     / `correction` events; historical rows are never mutated in place.
///   - [Tables.transactions] = canonical user-facing event/projection.
///   - [Tables.bankAccounts].balance = materialized cache whose correctness is
///     enforced transactionally: every mutation writes its journal event(s)
///     AND applies the matching balance delta inside ONE SQLite transaction,
///     then verifies that the journal-derived delta equals the applied delta.
///     Mismatch => throw => SQLite rolls back EVERYTHING.
///
/// This service is the ONLY writer of financial state. Repositories'
/// adjust/insert primitives are invoked exclusively from within these methods.
class FinancialTransactionService {
  final Database? database;

  FinancialTransactionService({this.database});

  Future<Database> get _db async =>
      database ?? await AppDatabase.instance.database;

  // ---------------------------------------------------------------------------
  // Impact + ledger helpers (single source of truth for sign policy)
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

  /// Bank-account ledger legs for a transaction (empty for card-side purchases).
  ///
  /// [referenceId] overrides the default `tx.id` anchor — used by append-only
  /// edits so the corrected event gets a distinct `tx.id:corr:N` reference
  /// (never colliding with the original `tx.id` leg or any `tx.id:rev:N`
  /// reversal), keeping the journal unambiguous for the G4 backfill.
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

  /// Bank-account balance deltas for a transaction (empty for card purchases).
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

  /// Verify that the signed sum of [legs] per account equals [expectedDeltas].
  /// This enforces G3: the journal event deltas must exactly produce the
  /// applied balance delta. Throws (=> rollback) on mismatch.
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

  /// Apply [legs] to the materialized balances and verify against [expected].
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
  // Public API (backward-compatible names)
  // ---------------------------------------------------------------------------

  Future<void> createExpense(Transaction tx, {DatabaseExecutor? txn}) =>
      createTransaction(tx, txn: txn);

  Future<void> createIncome(Transaction tx, {DatabaseExecutor? txn}) =>
      createTransaction(tx, txn: txn);

  Future<void> createTransfer(Transaction tx, {DatabaseExecutor? txn}) =>
      createTransaction(tx, txn: txn);

  /// Canonical create. Writes the source row + journal event(s) + materialized
  /// balance delta (and optional credit/loan side-effects) atomically.
  ///
  /// When [txn] is supplied the caller owns the transaction (used by bulk
  /// import). When [insertSource] is false the source row is assumed already
  /// inserted by the caller (bulk path).
  Future<void> createTransaction(
    Transaction tx, {
    CreditTransaction? creditTxn,
    String? loanId,
    double? loanPaidDelta,
    DatabaseExecutor? txn,
    bool insertSource = true,
  }) async {
    Future<void> inner(DatabaseExecutor t) async {
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

    if (txn != null) return inner(txn);
    final db = await _db;
    await db.transaction((t) => inner(t));
  }

  /// Edit = append-only: emit a `reversal` of the old event, then the corrected
  /// event. The source row is updated; no journal row is ever deleted.
  Future<void> editTransaction({
    required Transaction oldTransaction,
    required Transaction newTransaction,
    DatabaseExecutor? txn,
  }) async {
    Future<void> inner(DatabaseExecutor t) async {
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

    if (txn != null) return inner(txn);
    final db = await _db;
    await db.transaction((t) => inner(t));
  }

  /// Delete = append-only: emit a `reversal` (cancel) of the old event, then
  /// delete the source row. The journal keeps the full cancellation trail.
  Future<void> deleteTransaction(
    String transactionId, {
    Transaction? oldTransaction,
    DatabaseExecutor? txn,
  }) async {
    Future<void> inner(DatabaseExecutor t) async {
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

    if (txn != null) return inner(txn);
    final db = await _db;
    await db.transaction((t) => inner(t));
  }

  // ---------------------------------------------------------------------------
  // Choke-point for domain subsystems (credit / loan / salary / lending)
  // ---------------------------------------------------------------------------

  /// Single writer for any [LedgerTransaction] row. Domain subsystems
  /// (credit-card, loan) MUST route their journal rows through here so the
  /// canonical ledger has exactly one writer. If [leg] carries an [accountId]
  /// the matching bank balance delta is applied and verified atomically — this
  /// is what keeps the materialized cache correct for card payments and loan
  /// EMIs (previously those bank-side legs were journaled but never reflected
  /// in [Tables.bankAccounts].balance).
  Future<void> appendLedger(LedgerTransaction leg) async {
    final db = await _db;
    await db.transaction((t) async {
      await t.insert(Tables.ledgerTransactions, leg.toMap());
      if (leg.accountId == null || leg.accountId!.isEmpty) return;
      final signed = _signed(leg.type, leg.amount);
      await _applyAndVerify(t, [leg], {leg.accountId!: signed});
    });
  }

  /// Single deletion path for journal rows owned by domain subsystems
  /// (credit/loan internal transforms such as purchase→EMI conversion).
  /// Hard-deletes by reference (and optional type); kept as a service method
  /// so the ledger still has exactly one writer. Append-only purity for
  /// credit-internal transforms is tracked separately under §19 / G4.
  Future<void> removeLedger({
    required String referenceId,
    String? type,
  }) async {
    final db = await _db;
    await db.transaction((t) async {
      if (type != null) {
        await t.delete(
          Tables.ledgerTransactions,
          where: 'reference_id = ? AND type = ?',
          whereArgs: [referenceId, type],
        );
      } else {
        await t.delete(
          Tables.ledgerTransactions,
          where: 'reference_id = ?',
          whereArgs: [referenceId],
        );
      }
    });
  }
}
