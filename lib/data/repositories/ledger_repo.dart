import '../../models/ledger_transaction.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class LedgerRepo {
  final db = AppDatabase.instance;

  Future<void> deleteById(int id) async {
    final database = await db.database;
    await database.delete(
      Tables.ledgerTransactions,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<String> insert(LedgerTransaction tx) async {
    final database = await db.database;
    final insertedId = await database.insert(
      Tables.ledgerTransactions,
      tx.toMap(),
    );
    return tx.id?.toString() ?? insertedId.toString();
  }

  Future<List<LedgerTransaction>> getAll({
    DateTime? start,
    DateTime? end,
    LedgerType? type,
    String? accountId,
    String? creditCardId,
    String? loanId,
    String? referenceId,
  }) async {
    final database = await db.database;

    List<String> whereClauses = [];
    List<dynamic> whereArgs = [];

    if (referenceId != null) {
      whereClauses.add('reference_id = ?');
      whereArgs.add(referenceId);
    }
    if (start != null) {
      whereClauses.add('date >= ?');
      whereArgs.add(start.toIso8601String());
    }
    if (end != null) {
      whereClauses.add('date <= ?');
      whereArgs.add(end.toIso8601String());
    }
    if (type != null) {
      whereClauses.add('type = ?');
      whereArgs.add(type.name);
    }
    if (accountId != null) {
      whereClauses.add('account_id = ?');
      whereArgs.add(accountId);
    }
    if (creditCardId != null) {
      whereClauses.add('credit_card_id = ?');
      whereArgs.add(creditCardId);
    }
    if (loanId != null) {
      whereClauses.add('loan_id = ?');
      whereArgs.add(loanId);
    }

    final whereString = whereClauses.isNotEmpty
        ? whereClauses.join(' AND ')
        : null;

    final List<Map<String, dynamic>> maps = await database.query(
      Tables.ledgerTransactions,
      where: whereString,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'date DESC',
    );

    return maps.map((m) => LedgerTransaction.fromMap(m)).toList();
  }

  Future<double> getAccountBalance(String accountId) async {
    final database = await db.database;
    final result = await database.rawQuery(
      '''
      SELECT SUM(CASE 
        WHEN type IN ('income', 'lending_received', 'loan_disbursement', 'refund') THEN amount 
        WHEN type IN ('expense', 'credit_payment', 'emi_installment', 'loan_payment', 'transfer', 'lending_given', 'fuel_expense', 'processing_fee', 'interest_charge') THEN -amount 
        ELSE 0 END) as balance
      FROM ${Tables.ledgerTransactions}
      WHERE account_id = ?
    ''',
      [accountId],
    );

    return (result.first['balance'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getCreditOutstanding(String cardId) async {
    final database = await db.database;
    final result = await database.rawQuery(
      '''
      SELECT SUM(CASE 
        WHEN type IN ('credit_purchase', 'emi_installment', 'processing_fee', 'interest_charge') THEN amount 
        WHEN type IN ('credit_payment', 'refund') THEN -amount 
        ELSE 0 END) as outstanding
      FROM ${Tables.ledgerTransactions}
      WHERE credit_card_id = ?
    ''',
      [cardId],
    );

    return (result.first['outstanding'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getLoanBalance(String loanId) async {
    final database = await db.database;
    final result = await database.rawQuery(
      '''
      SELECT SUM(CASE 
        WHEN type IN ('loan_disbursement', 'interest_charge') THEN amount 
        WHEN type = 'loan_payment' THEN -amount 
        ELSE 0 END) as balance
      FROM ${Tables.ledgerTransactions}
      WHERE loan_id = ?
    ''',
      [loanId],
    );

    return (result.first['balance'] as num?)?.toDouble() ?? 0.0;
  }

  Future<void> deleteByReferenceId(String referenceId) async {
    final database = await db.database;
    await database.delete(
      Tables.ledgerTransactions,
      where: 'reference_id = ?',
      whereArgs: [referenceId],
    );
  }

  Future<void> deleteByReferenceAndType(String referenceId, String type) async {
    final database = await db.database;
    await database.delete(
      Tables.ledgerTransactions,
      where: 'reference_id = ? AND type = ?',
      whereArgs: [referenceId, type],
    );
  }
}
