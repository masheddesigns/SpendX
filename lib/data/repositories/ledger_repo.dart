import 'package:sqflite/sqflite.dart';

import '../../models/ledger_transaction.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class LedgerRepo {
  final Database? database;

  LedgerRepo({this.database});

  Future<Database> get _db async =>
      database ?? await AppDatabase.instance.database;

  Future<void> deleteById(int id) async {
    final database = await _db;
    await database.delete(
      Tables.ledgerTransactions,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<String> insert(LedgerTransaction tx) async {
    final database = await _db;
    final insertedId = await database.insert(
      Tables.ledgerTransactions,
      tx.toMap(),
    );
    return tx.id?.toString() ?? insertedId.toString();
  }

  Future<void> update(LedgerTransaction tx) async {
    final database = await _db;
    await database.update(
      Tables.ledgerTransactions,
      tx.toMap(),
      where: 'id = ?',
      whereArgs: [tx.id],
    );
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
    final database = await _db;
    final List<String> whereClauses = [];
    final List<dynamic> whereArgs = [];

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
    final database = await _db;
    final result = await database.rawQuery(
      '''
      SELECT SUM(CASE 
        WHEN type IN ('income', 'lending_received', 'loan_disbursement', 'refund', 'opening_balance') THEN amount 
        WHEN type IN ('expense', 'credit_payment', 'emi_installment', 'loan_payment', 'transfer', 'lending_given', 'fuel_expense', 'processing_fee', 'interest_charge') THEN -amount 
        ELSE 0 END) as balance
      FROM ${Tables.ledgerTransactions}
      WHERE account_id = ?
    ''',
      [accountId],
    );

    return (result.first['balance'] as num?)?.toDouble() ?? 0.0;
  }

  /// Derived account balance = opening balance + ledger movements.
  /// `opening_balance` ledger entries are now counted inside
  /// [getAccountBalance]. The optional [openingBalance] argument remains for
  /// callers that want to supply an explicit opening override (e.g. legacy
  /// flows that have not yet been migrated).
  Future<double> getDerivedAccountBalance(
    String accountId, {
    double openingBalance = 0.0,
  }) async {
    final movements = await getAccountBalance(accountId);
    return openingBalance + movements;
  }

  /// Sum of all signed ledger movements for an account EXCLUDING
  /// `opening_balance` entries. Used by the Phase 1B backfill to compute the
  /// residual that the opening-balance entry must absorb.
  Future<double> getAccountMovementSumExcludingOpening(String accountId) async {
    final database = await _db;
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
    final database = await _db;
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
    final database = await _db;
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

  /// Correct loan principal remaining = principal − Σ(principal component of
  /// paid installments). Uses the amortization schedule, NOT the flat ledger
  /// payment total, so interest is not double-counted against principal.
  Future<double> getLoanPrincipalRemaining(
    String loanId,
    double principal,
  ) async {
    final database = await _db;
    final rows = await database.rawQuery(
      '''
      SELECT COALESCE(SUM(principalComponent), 0) as paid
      FROM ${Tables.loanInstallments}
      WHERE loanId = ? AND status = ?
    ''',
      [loanId, 'paid'],
    );
    final paid =
        (rows.first['paid'] as num?)?.toDouble() ?? 0.0;
    return principal - paid;
  }

  /// Net lending balance for a person/reference:
  /// positive => money receivable (asset), negative => payable (liability).
  Future<double> getLendingBalance(String referenceId) async {
    final database = await _db;
    final result = await database.rawQuery(
      '''
      SELECT SUM(CASE 
        WHEN type = 'lending_given' THEN amount 
        WHEN type = 'lending_received' THEN -amount 
        ELSE 0 END) as balance
      FROM ${Tables.ledgerTransactions}
      WHERE reference_id = ?
    ''',
      [referenceId],
    );

    return (result.first['balance'] as num?)?.toDouble() ?? 0.0;
  }

  /// Category spending aggregation from the ledger. Excludes balance-only
  /// movements (transfers, repayments) so it reflects real consumption.
  Future<Map<String, double>> getCategorySpending({
    DateTime? start,
    DateTime? end,
    String? accountId,
  }) async {
    final database = await _db;
    final List<String> whereClauses = [
      "(type = 'expense' OR type = 'credit_purchase' OR type = 'fuel_expense')",
    ];
    final List<dynamic> whereArgs = [];

    if (start != null) {
      whereClauses.add('date >= ?');
      whereArgs.add(start.toIso8601String());
    }
    if (end != null) {
      whereClauses.add('date <= ?');
      whereArgs.add(end.toIso8601String());
    }
    if (accountId != null) {
      whereClauses.add('account_id = ?');
      whereArgs.add(accountId);
    }

    final rows = await database.query(
      Tables.ledgerTransactions,
      columns: ['category_id', 'SUM(amount) as total'],
      where: whereClauses.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      groupBy: 'category_id',
    );

    final Map<String, double> result = {};
    for (final row in rows) {
      final cat = row['category_id'] as String?;
      if (cat == null) continue;
      result[cat] =
          (row['total'] as num?)?.toDouble() ?? 0.0;
    }
    return result;
  }

  Future<void> deleteByReferenceId(String referenceId) async {
    final database = await _db;
    await database.delete(
      Tables.ledgerTransactions,
      where: 'reference_id = ?',
      whereArgs: [referenceId],
    );
  }

  Future<void> deleteByReferenceAndType(
    String referenceId,
    String type,
  ) async {
    final database = await _db;
    await database.delete(
      Tables.ledgerTransactions,
      where: 'reference_id = ? AND type = ?',
      whereArgs: [referenceId, type],
    );
  }
}
