import '../../models/transaction.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, DatabaseExecutor;
import '../core/tables.dart';
import '../core/app_database.dart';

class TransactionRepo {
  final db = AppDatabase.instance;

  Future<void> create(Transaction txn) async {
    await insert(txn);
  }

  Future<List<Transaction>> getAll({int? limit, int? offset}) async {
    final database = await db.database;
    final res = await database.query(
      Tables.transactions,
      where: 'is_deleted = 0',
      limit: limit,
      offset: offset,
      orderBy: 'date DESC, created_at DESC, id DESC',
    );

    return _dedupeExactTransactions(res.map((e) => Transaction.fromMap(e)));
  }

  Future<Transaction?> getById(String id) async {
    final database = await db.database;
    final res = await database.query(
      Tables.transactions,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (res.isEmpty) return null;
    return Transaction.fromMap(res.first);
  }

  Future<String> insert(Transaction txn) async {
    final database = await db.database;
    debugPrint('🧠 DB INSERT START');
    await database.insert(
      Tables.transactions,
      txn.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    debugPrint('🧠 DB INSERT DONE');
    return txn.id;
  }

  /// Bulk-insert transactions. Duplicates (by external_ref) are silently ignored.
  Future<void> insertAll(List<Transaction> txns) async {
    if (txns.isEmpty) return;
    final database = await db.database;
    await insertAllReturningRefsWithTxn(database, txns);
  }

  /// Batch-insert transactions within a [DatabaseExecutor], then query back
  /// which `externalRef` values the DB actually accepted.
  ///
  /// Strategy: fast batch insert (one round-trip) + query-back confirmation.
  /// This gives batch performance with insert-confirmed correctness.
  ///
  /// Correctness contract: the returned set contains ONLY refs that exist in
  /// the DB after the batch AND were part of the input. Since we're inside
  /// a serialized SQLite transaction, no other writer can interfere.
  Future<Set<String>> insertAllReturningRefsWithTxn(
    DatabaseExecutor txn,
    List<Transaction> txns,
  ) async {
    if (txns.isEmpty) return {};

    // Collect candidate refs before insert
    final candidateRefs = <String>[];
    for (final tx in txns) {
      final ref = tx.externalRef;
      if (ref != null && ref.isNotEmpty) {
        candidateRefs.add(ref);
      }
    }

    // Fast batch insert — duplicates silently ignored by UNIQUE constraint.
    // Keep results so we can tell which rows SQLite actually inserted.
    final batch = txn.batch();
    for (final tx in txns) {
      batch.insert(
        Tables.transactions,
        tx.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    final results = await batch.commit(noResult: false);

    // Sqflite returns the inserted row id. For ignored conflicts SQLite reports
    // 0/null, so only these refs should receive balance/card side-effects.
    final insertedRefs = <String>{};
    for (var i = 0; i < txns.length && i < results.length; i++) {
      final ref = txns[i].externalRef;
      final result = results[i];
      if (ref != null && ref.isNotEmpty && result is int && result > 0) {
        insertedRefs.add(ref);
      }
    }

    final skipped = candidateRefs.length - insertedRefs.length;
    debugPrint(
      '🧠 Insert: ${txns.length} batched, ${insertedRefs.length} confirmed, '
      '$skipped skipped by DB',
    );
    return insertedRefs;
  }

  Future<bool> existsByExternalRef(String externalRef) async {
    final database = await db.database;
    final res = await database.query(
      Tables.transactions,
      columns: const ['id'],
      where: 'external_ref = ?',
      whereArgs: [externalRef],
      limit: 1,
    );
    return res.isNotEmpty;
  }

  /// Batch-check which external_refs already exist in the DB.
  /// Returns the subset of [refs] that are already stored.
  /// Handles SQLite variable limit by chunking (max 999 per query).
  Future<Set<String>> getExistingExternalRefs(List<String> refs) async {
    if (refs.isEmpty) return {};
    final database = await db.database;
    final result = <String>{};

    // SQLite has a limit of 999 variables per query
    const chunkSize = 900;
    for (var i = 0; i < refs.length; i += chunkSize) {
      final chunk = refs.sublist(i, (i + chunkSize).clamp(0, refs.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await database.rawQuery(
        'SELECT external_ref FROM ${Tables.transactions} '
        'WHERE external_ref IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        final ref = row['external_ref'];
        if (ref is String) result.add(ref);
      }
    }
    return result;
  }

  /// Find transactions matching amount within a date range (for soft dedup).
  Future<List<Transaction>> findByAmountAndDateRange({
    required double amount,
    required DateTime from,
    required DateTime to,
  }) async {
    final database = await db.database;
    final rows = await database.query(
      Tables.transactions,
      where: 'is_deleted = 0 AND amount = ? AND date BETWEEN ? AND ?',
      whereArgs: [amount, from.toIso8601String(), to.toIso8601String()],
      limit: 5,
    );
    return rows.map(Transaction.fromMap).toList();
  }

  Future<int> update(Transaction txn) async {
    final database = await db.database;
    return await database.update(
      Tables.transactions,
      txn.toMap(),
      where: 'id = ?',
      whereArgs: [txn.id],
    );
  }

  Future<void> updateTransaction(Transaction txn) async {
    await update(txn);
  }

  Future<int> delete(String id) async {
    final database = await db.database;
    return await database.delete(
      Tables.transactions,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Stats for a date range (used for weekly wrapped).
  Future<Map<String, dynamic>> getStatsForRange(
    DateTime start,
    DateTime end,
  ) async {
    final database = await db.database;
    final startStr = start.toIso8601String();
    final endStr = end.toIso8601String();

    final summary = await database.rawQuery(
      '''
      SELECT
        SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as expense,
        COUNT(*) as txn_count,
        MAX(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as biggest_expense
      FROM ${Tables.transactions}
      WHERE is_deleted = 0 AND date >= ? AND date < ?
    ''',
      [startStr, endStr],
    );

    final topCats = await database.rawQuery(
      '''
      SELECT t.category_id, c.name, c.icon, c.color,
             SUM(t.amount) as total
      FROM ${Tables.transactions} t
      LEFT JOIN ${Tables.categories} c ON t.category_id = c.id
      WHERE t.is_deleted = 0 AND t.type = 'expense'
            AND t.date >= ? AND t.date < ?
      GROUP BY t.category_id
      ORDER BY total DESC
      LIMIT 5
    ''',
      [startStr, endStr],
    );

    return {
      'income': (summary.first['income'] as num?)?.toDouble() ?? 0,
      'expense': (summary.first['expense'] as num?)?.toDouble() ?? 0,
      'txn_count': (summary.first['txn_count'] as num?)?.toInt() ?? 0,
      'biggest_expense':
          (summary.first['biggest_expense'] as num?)?.toDouble() ?? 0,
      'top_categories': topCats,
    };
  }

  Future<List<Map<String, dynamic>>> getMonthlyStats(int monthsBack) async {
    final database = await db.database;
    return await database.rawQuery(
      '''
      SELECT 
        strftime('%Y-%m', date) as month,
        SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as expense
      FROM ${Tables.transactions}
      WHERE is_deleted = 0
      GROUP BY month
      ORDER BY month DESC
      LIMIT ?
    ''',
      [monthsBack],
    );
  }

  List<Transaction> _dedupeExactTransactions(
    Iterable<Transaction> transactions,
  ) {
    final seenIds = <String>{};
    final seenFingerprints = <String>{};
    final unique = <Transaction>[];

    for (final tx in transactions) {
      final fingerprint = _exactFingerprint(tx);
      if (!seenIds.add(tx.id)) continue;
      if (!seenFingerprints.add(fingerprint)) continue;
      unique.add(tx);
    }

    return unique;
  }

  String _exactFingerprint(Transaction tx) {
    final notes = tx.notes.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return [
      tx.type,
      tx.source,
      tx.accountId ?? '',
      tx.relatedEntityId ?? '',
      tx.amount.toStringAsFixed(2),
      tx.date.toIso8601String(),
      notes,
    ].join('|');
  }

  /// Category spending breakdown for the last N months.
  Future<List<Map<String, dynamic>>> getCategoryBreakdown(
    int monthsBack,
  ) async {
    final database = await db.database;
    final cutoff = DateTime.now().subtract(Duration(days: monthsBack * 30));
    return await database.rawQuery(
      '''
      SELECT
        t.category_id,
        c.name as category_name,
        t.type,
        SUM(t.amount) as total,
        COUNT(*) as count
      FROM ${Tables.transactions} t
      LEFT JOIN ${Tables.categories} c ON t.category_id = c.id
      WHERE t.is_deleted = 0 AND t.date >= ?
      GROUP BY t.category_id, t.type
      ORDER BY total DESC
    ''',
      [cutoff.toIso8601String()],
    );
  }

  /// Top spending categories for the last N months (expense only).
  Future<List<Map<String, dynamic>>> getTopExpenseCategories(
    int monthsBack, {
    int limit = 10,
  }) async {
    final database = await db.database;
    final cutoff = DateTime.now().subtract(Duration(days: monthsBack * 30));
    return await database.rawQuery(
      '''
      SELECT
        c.name as category_name,
        SUM(t.amount) as total,
        COUNT(*) as count
      FROM ${Tables.transactions} t
      LEFT JOIN ${Tables.categories} c ON t.category_id = c.id
      WHERE t.is_deleted = 0 AND t.type = 'expense' AND t.date >= ?
      GROUP BY t.category_id
      ORDER BY total DESC
      LIMIT ?
    ''',
      [cutoff.toIso8601String(), limit],
    );
  }

  /// Average daily spending for the last N days.
  Future<double> getAvgDailySpending(int days) async {
    final database = await db.database;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final result = await database.rawQuery(
      '''
      SELECT AVG(daily_total) as avg_daily FROM (
        SELECT date(date) as day, SUM(amount) as daily_total
        FROM ${Tables.transactions}
        WHERE is_deleted = 0 AND type = 'expense' AND date >= ?
        GROUP BY day
      )
    ''',
      [cutoff.toIso8601String()],
    );
    return (result.first['avg_daily'] as num?)?.toDouble() ?? 0;
  }

  /// Stats for a single month — used by Wrapped.
  Future<Map<String, dynamic>> getStatsForMonth(int year, int month) async {
    final database = await db.database;
    final monthStr = '$year-${month.toString().padLeft(2, '0')}';

    final summary = await database.rawQuery(
      '''
      SELECT
        SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as expense,
        COUNT(*) as txn_count,
        MAX(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as biggest_expense
      FROM ${Tables.transactions}
      WHERE is_deleted = 0 AND strftime('%Y-%m', date) = ?
    ''',
      [monthStr],
    );

    final topCats = await database.rawQuery(
      '''
      SELECT t.category_id, c.name, c.icon, c.color,
             SUM(t.amount) as total
      FROM ${Tables.transactions} t
      LEFT JOIN ${Tables.categories} c ON t.category_id = c.id
      WHERE t.is_deleted = 0 AND t.type = 'expense'
            AND strftime('%Y-%m', t.date) = ?
      GROUP BY t.category_id
      ORDER BY total DESC
      LIMIT 5
    ''',
      [monthStr],
    );

    return {
      'income': (summary.first['income'] as num?)?.toDouble() ?? 0,
      'expense': (summary.first['expense'] as num?)?.toDouble() ?? 0,
      'txn_count': (summary.first['txn_count'] as num?)?.toInt() ?? 0,
      'biggest_expense':
          (summary.first['biggest_expense'] as num?)?.toDouble() ?? 0,
      'top_categories': topCats,
    };
  }

  /// Stats for a full year — used by Wrapped.
  Future<Map<String, dynamic>> getStatsForYear(int year) async {
    final database = await db.database;
    final yearStr = year.toString();

    final summary = await database.rawQuery(
      '''
      SELECT
        SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as expense,
        COUNT(*) as txn_count,
        MAX(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as biggest_expense
      FROM ${Tables.transactions}
      WHERE is_deleted = 0 AND strftime('%Y', date) = ?
    ''',
      [yearStr],
    );

    final monthly = await database.rawQuery(
      '''
      SELECT
        strftime('%m', date) as m,
        SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END) as expense
      FROM ${Tables.transactions}
      WHERE is_deleted = 0 AND strftime('%Y', date) = ?
      GROUP BY m ORDER BY m ASC
    ''',
      [yearStr],
    );

    final topCats = await database.rawQuery(
      '''
      SELECT t.category_id, c.name, c.icon, c.color,
             SUM(t.amount) as total
      FROM ${Tables.transactions} t
      LEFT JOIN ${Tables.categories} c ON t.category_id = c.id
      WHERE t.is_deleted = 0 AND t.type = 'expense'
            AND strftime('%Y', t.date) = ?
      GROUP BY t.category_id
      ORDER BY total DESC
      LIMIT 5
    ''',
      [yearStr],
    );

    // Build 12-month arrays
    final Map<int, double> incomeByMonth = {};
    final Map<int, double> expenseByMonth = {};
    for (final row in monthly) {
      final m = int.tryParse(row['m'] as String? ?? '0') ?? 0;
      incomeByMonth[m] = (row['income'] as num?)?.toDouble() ?? 0;
      expenseByMonth[m] = (row['expense'] as num?)?.toDouble() ?? 0;
    }

    return {
      'income': (summary.first['income'] as num?)?.toDouble() ?? 0,
      'expense': (summary.first['expense'] as num?)?.toDouble() ?? 0,
      'txn_count': (summary.first['txn_count'] as num?)?.toInt() ?? 0,
      'biggest_expense':
          (summary.first['biggest_expense'] as num?)?.toDouble() ?? 0,
      'top_categories': topCats,
      'monthly_income': List.generate(12, (i) => incomeByMonth[i + 1] ?? 0.0),
      'monthly_expense': List.generate(12, (i) => expenseByMonth[i + 1] ?? 0.0),
    };
  }

  /// Get distinct months that have transactions (for wrapped periods).
  Future<List<String>> getDistinctMonths({int limit = 12}) async {
    final database = await db.database;
    final result = await database.rawQuery(
      '''
      SELECT DISTINCT strftime('%Y-%m', date) as month
      FROM ${Tables.transactions}
      WHERE is_deleted = 0
      ORDER BY month DESC
      LIMIT ?
    ''',
      [limit],
    );
    return result.map((r) => r['month'] as String).toList();
  }

  Future<List<Transaction>> getVehicleLinkedExpenses() async {
    final database = await db.database;
    final res = await database.query(
      Tables.transactions,
      where:
          'vehicle_id IS NOT NULL OR (related_entity_id IS NOT NULL AND source = ?)',
      whereArgs: const ['vehicle'],
      orderBy: 'date ASC',
    );
    return res.map((e) => Transaction.fromMap(e)).toList();
  }
}
