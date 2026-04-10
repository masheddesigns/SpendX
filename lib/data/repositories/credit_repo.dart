import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import '../../models/credit_card.dart';
import '../../models/credit_transaction.dart';
import '../../models/credit_emi.dart';
import '../../models/emi_installment.dart';
import '../../models/card_statement.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class CreditRepo {
  final db = AppDatabase.instance;

  Future<List<CreditCard>> getAll() async {
    final database = await db.database;
    final res = await database.query(Tables.creditCards, orderBy: 'name ASC');

    return res.map((e) => CreditCard.fromMap(e)).toList();
  }

  Future<CreditCard?> getCard(String id) async {
    final database = await db.database;
    final res = await database.query(
      Tables.creditCards,
      where: 'id = ?',
      whereArgs: [id],
    );
    return res.isNotEmpty ? CreditCard.fromMap(res.first) : null;
  }

  Future<String> insert(CreditCard card) async {
    final database = await db.database;
    await database.insert(Tables.creditCards, card.toMap());
    return card.id;
  }

  Future<int> update(CreditCard card) async {
    final database = await db.database;
    return await database.update(
      Tables.creditCards,
      card.toMap(),
      where: 'id = ?',
      whereArgs: [card.id],
    );
  }

  Future<int> delete(String id) async {
    final database = await db.database;
    return await database.delete(
      Tables.creditCards,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Batch-adjust outstanding (used_amount) for multiple cards.
  Future<void> adjustOutstandings(Map<String, double> deltas) async {
    if (deltas.isEmpty) return;
    final database = await db.database;
    await adjustOutstandingsWithTxn(database, deltas);
  }

  /// Batch-adjust within an existing [DatabaseExecutor] (DB transaction).
  Future<void> adjustOutstandingsWithTxn(
    DatabaseExecutor txn,
    Map<String, double> deltas,
  ) async {
    if (deltas.isEmpty) return;
    final batch = txn.batch();
    for (final entry in deltas.entries) {
      if (entry.value == 0) continue;
      batch.rawUpdate(
        'UPDATE ${Tables.creditCards} SET used_amount = MAX(0, used_amount + ?) WHERE id = ?',
        [entry.value, entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Bulk-insert credit transactions in a single batch.
  Future<void> insertTransactions(List<CreditTransaction> txns) async {
    if (txns.isEmpty) return;
    final database = await db.database;
    await insertTransactionsWithTxn(database, txns);
  }

  /// Bulk-insert credit transactions within an existing [DatabaseExecutor].
  Future<void> insertTransactionsWithTxn(
    DatabaseExecutor txn,
    List<CreditTransaction> txns,
  ) async {
    if (txns.isEmpty) return;
    final batch = txn.batch();
    for (final tx in txns) {
      batch.insert(Tables.creditTransactions, tx.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<List<CreditTransaction>> getTransactions(String cardId) async {
    final database = await db.database;
    final res = await database.query(
      Tables.creditTransactions,
      where: 'cardId = ?',
      whereArgs: [cardId],
      orderBy: 'date DESC',
    );
    return res.map((e) => CreditTransaction.fromMap(e)).toList();
  }

  Future<CreditTransaction?> getTransactionById(String id) async {
    final database = await db.database;
    final res = await database.query(
      Tables.creditTransactions,
      where: 'id = ?',
      whereArgs: [id],
    );
    return res.isNotEmpty ? CreditTransaction.fromMap(res.first) : null;
  }

  Future<void> insertTransaction(CreditTransaction tx) async {
    final database = await db.database;
    await database.insert(Tables.creditTransactions, tx.toMap());
  }

  Future<void> updateTransactionStatus(String id, String status) async {
    final database = await db.database;
    await database.update(
      Tables.creditTransactions,
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteTransaction(String id) async {
    final database = await db.database;
    await database.delete(
      Tables.creditTransactions,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<CreditEMI>> getEmis(String cardId) async {
    final database = await db.database;
    final res = await database.query(
      Tables.creditEmis,
      where: 'cardId = ?',
      whereArgs: [cardId],
      orderBy: 'startDate DESC',
    );
    return res.map((e) => CreditEMI.fromMap(e)).toList();
  }

  Future<CreditEMI?> getEMIById(String id) async {
    final database = await db.database;
    final res = await database.query(
      Tables.creditEmis,
      where: 'id = ?',
      whereArgs: [id],
    );
    return res.isNotEmpty ? CreditEMI.fromMap(res.first) : null;
  }

  Future<void> insertEMI(CreditEMI emi) async {
    final database = await db.database;
    await database.insert(Tables.creditEmis, emi.toMap());
  }

  Future<void> updateEMI(CreditEMI emi) async {
    final database = await db.database;
    await database.update(
      Tables.creditEmis,
      emi.toMap(),
      where: 'id = ?',
      whereArgs: [emi.id],
    );
  }

  Future<void> deleteEMI(String id) async {
    final database = await db.database;
    await database.delete(Tables.creditEmis, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<EMIInstallment>> getInstallments(String emiId) async {
    final database = await db.database;
    final res = await database.query(
      Tables.emiInstallments,
      where: 'emiId = ?',
      whereArgs: [emiId],
      orderBy: 'dueDate ASC',
    );
    return res.map((e) => EMIInstallment.fromMap(e)).toList();
  }

  Future<void> insertInstallment(EMIInstallment inst) async {
    final database = await db.database;
    await database.insert(Tables.emiInstallments, inst.toMap());
  }

  Future<int> updateInstallment(EMIInstallment installment) async {
    final database = await db.database;
    return database.update(
      Tables.emiInstallments,
      installment.toMap(),
      where: 'id = ?',
      whereArgs: [installment.id],
    );
  }

  Future<int> deleteInstallment(String id) async {
    final database = await db.database;
    return database.delete(
      Tables.emiInstallments,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteInstallments(String emiId) async {
    final database = await db.database;
    await database.delete(
      Tables.emiInstallments,
      where: 'emiId = ?',
      whereArgs: [emiId],
    );
  }

  Future<void> insertStatement(CardStatement statement) async {
    final database = await db.database;
    await database.insert(Tables.cardStatements, statement.toMap());
  }

  Future<void> assignTransactionsToStatement({
    required String statementId,
    required List<String> transactionIds,
  }) async {
    if (transactionIds.isEmpty) return;

    final database = await db.database;
    final batch = database.batch();
    for (final id in transactionIds) {
      batch.update(
        Tables.creditTransactions,
        {'statementId': statementId},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }
}
