import 'package:sqflite/sqflite.dart' hide Transaction;

import '../data/core/app_database.dart';
import '../data/core/tables.dart';
import '../models/ledger_transaction.dart';
import '../models/transaction.dart';

/// CANONICAL financial mutation boundary.
///
/// Architecture contract (locked in Phase 1A):
///   - ledger_transactions = canonical money-movement journal (source of truth)
///   - transactions        = canonical user-facing event/projection
///   - bank_accounts.balance / credit_cards.outstanding / used_amount =
///       DERIVED, never mutated as financial truth by this service.
///
/// Every money mutation writes its `transactions` row AND its
/// `ledger_transactions` row inside a single [db.transaction]. If any write
/// throws, SQLite rolls back BOTH, so the two stores can never diverge.
///
/// This skeleton implements expense / income / transfer / edit / delete only.
/// Credit, loan, lending, salary and goal flows migrate to this service in
/// later phases; they must NOT be added here yet.
class FinancialTransactionService {
  final Database? database;

  FinancialTransactionService({this.database});

  Future<Database> get _db async =>
      database ?? await AppDatabase.instance.database;

  /// Build the authoritative ledger entry/entries for a single transaction.
  /// Reference id is the transaction id so edits/deletes can locate them.
  List<LedgerTransaction> _ledgerEntriesFor(Transaction tx) {
    switch (tx.type) {
      case 'transfer':
        final source = tx.accountId;
        final dest = tx.relatedEntityId;
        final legs = <LedgerTransaction>[];
        if (source != null && source.isNotEmpty) {
          legs.add(
            LedgerTransaction(
              type: LedgerType.transfer,
              amount: tx.amount,
              date: tx.date,
              accountId: source,
              categoryId: tx.categoryId,
              note: tx.notes,
              referenceId: tx.id,
            ),
          );
        }
        if (dest != null && dest.isNotEmpty) {
          legs.add(
            LedgerTransaction(
              type: LedgerType.income,
              amount: tx.amount,
              date: tx.date,
              accountId: dest,
              categoryId: tx.categoryId,
              note: tx.notes,
              referenceId: tx.id,
            ),
          );
        }
        return legs;

      case 'income':
        return [
          LedgerTransaction(
            type: LedgerType.income,
            amount: tx.amount,
            date: tx.date,
            accountId: tx.accountId,
            categoryId: tx.categoryId,
            note: tx.notes,
            referenceId: tx.id,
          ),
        ];

      case 'expense':
      default:
        return [
          LedgerTransaction(
            type: LedgerType.expense,
            amount: tx.amount,
            date: tx.date,
            accountId: tx.accountId,
            categoryId: tx.categoryId,
            note: tx.notes,
            referenceId: tx.id,
          ),
        ];
    }
  }

  Future<void> createExpense(Transaction tx) => _create(tx);

  Future<void> createIncome(Transaction tx) => _create(tx);

  Future<void> createTransfer(Transaction tx) => _create(tx);

  Future<void> _create(Transaction tx) async {
    if (tx.type != 'expense' &&
        tx.type != 'income' &&
        tx.type != 'transfer') {
      throw ArgumentError(
        'FinancialTransactionService supports expense/income/transfer only',
      );
    }
    final db = await _db;
    await db.transaction((txn) async {
      await txn.insert(Tables.transactions, tx.toMap());
      for (final leg in _ledgerEntriesFor(tx)) {
        await txn.insert(Tables.ledgerTransactions, leg.toMap());
      }
    });
  }

  Future<void> editTransaction({
    required Transaction oldTransaction,
    required Transaction newTransaction,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      // Revert old ledger legs.
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'reference_id = ?',
        whereArgs: [oldTransaction.id],
      );
      // Replace the event row.
      await txn.update(
        Tables.transactions,
        newTransaction.toMap(),
        where: 'id = ?',
        whereArgs: [newTransaction.id],
      );
      // Write the new ledger legs.
      for (final leg in _ledgerEntriesFor(newTransaction)) {
        await txn.insert(Tables.ledgerTransactions, leg.toMap());
      }
    });
  }

  Future<void> deleteTransaction(String transactionId) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete(
        Tables.ledgerTransactions,
        where: 'reference_id = ?',
        whereArgs: [transactionId],
      );
      await txn.delete(
        Tables.transactions,
        where: 'id = ?',
        whereArgs: [transactionId],
      );
    });
  }
}
