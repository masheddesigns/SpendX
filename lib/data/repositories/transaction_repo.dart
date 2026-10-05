import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show DatabaseExecutor;
import '../../models/transaction.dart';
import '../core/app_database.dart';
import '../core/tables_v24.dart';
import 'canonical/canonical_event_repository.dart';
import 'canonical/canonical_transaction_adapter.dart';

/// Legacy-compatible transaction repository backed exclusively by
/// canonical v24 double-entry persistence ([TablesV24.economicEvents],
/// [TablesV24.postings], [TablesV24.evidence], [TablesV24.accounts]).
///
/// MIGRATION CONTRACT (Milestone C3B-1):
/// - Writes: 0 writes to legacy `transactions` table. All writes are translated
///   into atomic canonical `EconomicEvent` + `Posting` legs through
///   [CanonicalEventRepository.createAndPostEvent].
/// - Reads: 0 reads from legacy `transactions` table for financial truth.
///   All reads project from canonical events and postings.
/// - Immutability: Posted events are never mutated in place. Edits and deletes
///   emit balanced reversal/replacement events.
class TransactionRepo {
  final DatabaseExecutor? _customExecutor;

  TransactionRepo({DatabaseExecutor? executor}) : _customExecutor = executor;

  Future<DatabaseExecutor> get _db async {
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  CanonicalEventRepository _eventRepo(DatabaseExecutor executor) =>
      CanonicalEventRepository(executor: executor);

  // ---------------------------------------------------------------------------
  // CREATE
  // ---------------------------------------------------------------------------

  Future<void> create(Transaction txn) async {
    await insert(txn);
  }

  Future<String> insert(Transaction txn) async {
    final database = await _db;
    debugPrint('🧠 CANONICAL DB INSERT START: ${txn.id}');

    await CanonicalTransactionAdapter.ensureAccountsExist(database, txn);
    final event = CanonicalTransactionAdapter.toEconomicEvent(txn);
    final postings =
        CanonicalTransactionAdapter.toPostings(txn, eventId: event.id);
    final evidence =
        CanonicalTransactionAdapter.toEvidence(txn, eventId: event.id);

    final repo = _eventRepo(database);
    await repo.createAndPostEvent(
      event,
      postings: postings,
      evidence: evidence != null ? [evidence] : null,
    );

    debugPrint('🧠 CANONICAL DB INSERT DONE: ${txn.id}');
    return txn.id;
  }

  /// Bulk-insert transactions. Duplicates (by external_ref) are silently ignored.
  Future<void> insertAll(List<Transaction> txns) async {
    if (txns.isEmpty) return;
    final database = await _db;
    await insertAllReturningRefsWithTxn(database, txns);
  }

  /// Batch-insert transactions within a [DatabaseExecutor], returning the set
  /// of accepted [externalRef]s.
  Future<Set<String>> insertAllReturningRefsWithTxn(
    DatabaseExecutor txn,
    List<Transaction> txns,
  ) async {
    if (txns.isEmpty) return {};

    final insertedRefs = <String>{};
    for (final tx in txns) {
      if (tx.externalRef != null && tx.externalRef!.isNotEmpty) {
        final exists = await existsByExternalRef(tx.externalRef!, executor: txn);
        if (exists) continue; // Deduplicate
      }

      await CanonicalTransactionAdapter.ensureAccountsExist(txn, tx);
      final event = CanonicalTransactionAdapter.toEconomicEvent(tx);
      final postings =
          CanonicalTransactionAdapter.toPostings(tx, eventId: event.id);
      final evidence =
          CanonicalTransactionAdapter.toEvidence(tx, eventId: event.id);

      final repo = _eventRepo(txn);
      await repo.createAndPostEvent(
        event,
        postings: postings,
        evidence: evidence != null ? [evidence] : null,
      );

      if (tx.externalRef != null && tx.externalRef!.isNotEmpty) {
        insertedRefs.add(tx.externalRef!);
      }
    }

    return insertedRefs;
  }

  // ---------------------------------------------------------------------------
  // READ
  // ---------------------------------------------------------------------------

  Future<List<Transaction>> getAll({int? limit, int? offset}) async {
    final database = await _db;
    final repo = _eventRepo(database);

    final events = await repo.listPostedEvents(
      limit: limit,
      offset: offset,
    );

    // Collect all reversed original event IDs
    final reversedIds = <String>{};
    for (final e in events) {
      if (e.description.startsWith('REVERSAL:')) {
        final ref = e.metadata['reversal_of'] as String?;
        if (ref != null) {
          reversedIds.add(ref);
        } else {
          final parts = e.description.split(': ');
          if (parts.length > 1) {
            final origId = parts[1].split(' - ').first.trim();
            reversedIds.add(origId);
          }
        }
      }
    }

    // Filter out internal reversals and deleted/reversed events
    final list = <Transaction>[];
    for (final e in events) {
      if (e.description.startsWith('REVERSAL:') ||
          e.metadata['is_reversal'] == true ||
          reversedIds.contains(e.id)) {
        continue;
      }
      final evidenceList = await repo.getEvidenceForEvent(e.id);
      final tx = CanonicalTransactionAdapter.toTransaction(
        e,
        e.postings,
        evidence: evidenceList.isNotEmpty ? evidenceList.first : null,
      );
      list.add(tx);
    }

    return _dedupeExactTransactions(list);
  }

  Future<Transaction?> getById(String id) async {
    final database = await _db;
    final repo = _eventRepo(database);

    final event = await repo.getEvent(id);
    if (event == null) return null;
    if (event.description.startsWith('REVERSAL:') ||
        event.metadata['is_reversal'] == true) {
      return null;
    }

    // Check if this event was reversed by a subsequent deletion/edit
    final reversalCheck = await database.rawQuery(
      "SELECT id FROM ${TablesV24.economicEvents} WHERE description LIKE ? LIMIT 1;",
      ['REVERSAL: $id%'],
    );
    if (reversalCheck.isNotEmpty) {
      return null;
    }

    final evidenceList = await repo.getEvidenceForEvent(id);
    return CanonicalTransactionAdapter.toTransaction(
      event,
      event.postings,
      evidence: evidenceList.isNotEmpty ? evidenceList.first : null,
    );
  }

  Future<bool> existsByExternalRef(
    String externalRef, {
    DatabaseExecutor? executor,
  }) async {
    final database = executor ?? await _db;
    final res = await database.rawQuery(
      'SELECT id FROM ${TablesV24.evidence} WHERE external_reference = ? LIMIT 1;',
      [externalRef],
    );
    return res.isNotEmpty;
  }

  Future<Set<String>> getExistingExternalRefs(
    List<String> refs, {
    DatabaseExecutor? executor,
  }) async {
    if (refs.isEmpty) return {};
    final database = executor ?? await _db;
    final result = <String>{};

    const chunkSize = 900;
    for (var i = 0; i < refs.length; i += chunkSize) {
      final chunk = refs.sublist(i, (i + chunkSize).clamp(0, refs.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await database.rawQuery(
        'SELECT external_reference FROM ${TablesV24.evidence} '
        'WHERE external_reference IN ($placeholders);',
        chunk,
      );
      for (final row in rows) {
        final ref = row['external_reference'];
        if (ref is String) result.add(ref);
      }
    }
    return result;
  }

  Future<List<Transaction>> findByAmountAndDateRange({
    required double amount,
    required DateTime from,
    required DateTime to,
  }) async {
    final database = await _db;
    final minorUnits = CanonicalTransactionAdapter.toMinorUnits(amount);

    final rows = await database.rawQuery('''
      SELECT DISTINCT e.id
      FROM ${TablesV24.economicEvents} e
      JOIN ${TablesV24.postings} p ON e.id = p.economic_event_id
      WHERE e.lifecycle_status = 'posted'
        AND p.amount_minor_units = ?
        AND e.timestamp BETWEEN ? AND ?
      LIMIT 5;
    ''', [minorUnits, from.toIso8601String(), to.toIso8601String()]);

    final results = <Transaction>[];
    for (final r in rows) {
      final id = r['id'] as String;
      final tx = await getById(id);
      if (tx != null) results.add(tx);
    }
    return results;
  }

  // ---------------------------------------------------------------------------
  // UPDATE / CORRECTION
  // ---------------------------------------------------------------------------

  Future<int> update(Transaction txn) async {
    final database = await _db;
    final repo = _eventRepo(database);

    // 1. Locate original event
    final original = await repo.getEvent(txn.id);
    if (original == null) {
      // If not existing, insert as new
      await insert(txn);
      return 1;
    }

    // 2. Post reversal event negating the original
    final reversal = CanonicalTransactionAdapter.createReversal(
      original,
      original.postings,
      reason: 'Transaction update',
    );
    await repo.createAndPostEvent(
      reversal.event,
      postings: reversal.postings,
    );

    // 3. Post replacement event with new transaction state
    final replacementId = '${txn.id}:corr:${DateTime.now().millisecondsSinceEpoch}';
    final replacementTxn = txn.copyWith(id: replacementId);
    await CanonicalTransactionAdapter.ensureAccountsExist(database, replacementTxn);

    final replacementEvent =
        CanonicalTransactionAdapter.toEconomicEvent(replacementTxn);
    final replacementPostings = CanonicalTransactionAdapter.toPostings(
      replacementTxn,
      eventId: replacementId,
    );
    final replacementEvidence = CanonicalTransactionAdapter.toEvidence(
      replacementTxn,
      eventId: replacementId,
    );

    await repo.createAndPostEvent(
      replacementEvent,
      postings: replacementPostings,
      evidence:
          replacementEvidence != null ? [replacementEvidence] : null,
    );

    return 1;
  }

  Future<void> updateTransaction(Transaction txn) async {
    await update(txn);
  }

  // ---------------------------------------------------------------------------
  // DELETE / REVERSAL
  // ---------------------------------------------------------------------------

  Future<int> delete(String id) async {
    final database = await _db;
    final repo = _eventRepo(database);

    final original = await repo.getEvent(id);
    if (original == null) return 0;

    // Post reversal event to cancel financial impact
    final reversal = CanonicalTransactionAdapter.createReversal(
      original,
      original.postings,
      reason: 'Transaction deletion',
    );
    await repo.createAndPostEvent(
      reversal.event,
      postings: reversal.postings,
    );

    return 1;
  }

  // ---------------------------------------------------------------------------
  // DERIVED QUERIES
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getStatsForRange(
    DateTime start,
    DateTime end,
  ) async {
    final database = await _db;
    final startStr = start.toIso8601String();
    final endStr = end.toIso8601String();

    final summary = await database.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units ELSE 0 END), 0) / 100.0 AS income,
        COALESCE(SUM(CASE WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units ELSE 0 END), 0) / 100.0 AS expense,
        COUNT(DISTINCT e.id) AS txn_count,
        COALESCE(MAX(CASE WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units ELSE 0 END), 0) / 100.0 AS biggest_expense
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND e.event_type NOT LIKE 'adjustment%'
        AND e.description NOT LIKE 'REVERSAL:%'
        AND e.timestamp >= ? AND e.timestamp < ?;
    ''', [startStr, endStr]);

    final topCats = await database.rawQuery('''
      SELECT a.id AS category_id, a.name, a.icon_name AS icon, a.color_hex AS color,
             SUM(p.amount_minor_units) / 100.0 AS total
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND a.account_type = 'expense'
        AND p.direction = 'debit'
        AND e.description NOT LIKE 'REVERSAL:%'
        AND e.timestamp >= ? AND e.timestamp < ?
      GROUP BY a.id
      ORDER BY total DESC
      LIMIT 5;
    ''', [startStr, endStr]);

    return {
      'income': (summary.first['income'] as num?)?.toDouble() ?? 0.0,
      'expense': (summary.first['expense'] as num?)?.toDouble() ?? 0.0,
      'txn_count': (summary.first['txn_count'] as num?)?.toInt() ?? 0,
      'biggest_expense':
          (summary.first['biggest_expense'] as num?)?.toDouble() ?? 0.0,
      'top_categories': topCats,
    };
  }

  Future<List<Map<String, dynamic>>> getMonthlyStats(int monthsBack) async {
    final database = await _db;
    return await database.rawQuery('''
      SELECT 
        strftime('%Y-%m', e.timestamp) AS month,
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units
            WHEN a.account_type = 'income' AND p.direction = 'debit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS income,
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units
            WHEN a.account_type = 'expense' AND p.direction = 'credit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS expense
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND e.event_type != 'opening_balance'
      GROUP BY month
      ORDER BY month DESC
      LIMIT ?;
    ''', [monthsBack]);
  }

  Future<List<Map<String, dynamic>>> getCategoryBreakdown(int monthsBack) async {
    final database = await _db;
    final cutoff = DateTime.now().subtract(Duration(days: monthsBack * 30));
    return await database.rawQuery('''
      SELECT
        a.id AS category_id,
        a.name AS category_name,
        a.account_type AS type,
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units
            WHEN a.account_type = 'expense' AND p.direction = 'credit' THEN -p.amount_minor_units
            WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units
            WHEN a.account_type = 'income' AND p.direction = 'debit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS total,
        COUNT(DISTINCT e.id) AS count
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND (a.account_type = 'expense' OR a.account_type = 'income')
        AND e.event_type != 'opening_balance'
        AND e.timestamp >= ?
      GROUP BY a.id, a.account_type
      ORDER BY total DESC;
    ''', [cutoff.toIso8601String()]);
  }

  Future<List<Map<String, dynamic>>> getTopExpenseCategories(
    int monthsBack, {
    int limit = 10,
  }) async {
    final database = await _db;
    final cutoff = DateTime.now().subtract(Duration(days: monthsBack * 30));
    return await database.rawQuery('''
      SELECT
        a.name AS category_name,
        COALESCE(SUM(
          CASE
            WHEN p.direction = 'debit' THEN p.amount_minor_units
            WHEN p.direction = 'credit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS total,
        COUNT(DISTINCT e.id) AS count
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND a.account_type = 'expense'
        AND e.event_type != 'opening_balance'
        AND e.timestamp >= ?
      GROUP BY a.id
      ORDER BY total DESC
      LIMIT ?;
    ''', [cutoff.toIso8601String(), limit]);
  }

  Future<double> getAvgDailySpending(int days) async {
    final database = await _db;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final result = await database.rawQuery('''
      SELECT AVG(daily_total) AS avg_daily FROM (
        SELECT date(e.timestamp) AS day,
               COALESCE(SUM(
                 CASE
                   WHEN p.direction = 'debit' THEN p.amount_minor_units
                   WHEN p.direction = 'credit' THEN -p.amount_minor_units
                   ELSE 0
                 END
               ), 0) / 100.0 AS daily_total
        FROM ${TablesV24.postings} p
        JOIN ${TablesV24.accounts} a ON p.account_id = a.id
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE e.lifecycle_status = 'posted'
          AND a.account_type = 'expense'
          AND e.event_type != 'opening_balance'
          AND e.timestamp >= ?
        GROUP BY day
      );
    ''', [cutoff.toIso8601String()]);
    return (result.first['avg_daily'] as num?)?.toDouble() ?? 0.0;
  }

  Future<Map<String, dynamic>> getStatsForMonth(int year, int month) async {
    final database = await _db;
    final monthStr = '$year-${month.toString().padLeft(2, '0')}';

    final summary = await database.rawQuery('''
      SELECT
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units
            WHEN a.account_type = 'income' AND p.direction = 'debit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS income,
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units
            WHEN a.account_type = 'expense' AND p.direction = 'credit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS expense,
        COUNT(DISTINCT e.id) AS txn_count,
        COALESCE(MAX(CASE WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units ELSE 0 END), 0) / 100.0 AS biggest_expense
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND e.event_type != 'opening_balance'
        AND strftime('%Y-%m', e.timestamp) = ?;
    ''', [monthStr]);

    final topCats = await database.rawQuery('''
      SELECT a.id AS category_id, a.name, a.icon_name AS icon, a.color_hex AS color,
             COALESCE(SUM(
               CASE
                 WHEN p.direction = 'debit' THEN p.amount_minor_units
                 WHEN p.direction = 'credit' THEN -p.amount_minor_units
                 ELSE 0
               END
             ), 0) / 100.0 AS total
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND a.account_type = 'expense'
        AND e.event_type != 'opening_balance'
        AND strftime('%Y-%m', e.timestamp) = ?
      GROUP BY a.id
      ORDER BY total DESC
      LIMIT 5;
    ''', [monthStr]);

    return {
      'income': (summary.first['income'] as num?)?.toDouble() ?? 0.0,
      'expense': (summary.first['expense'] as num?)?.toDouble() ?? 0.0,
      'txn_count': (summary.first['txn_count'] as num?)?.toInt() ?? 0,
      'biggest_expense':
          (summary.first['biggest_expense'] as num?)?.toDouble() ?? 0.0,
      'top_categories': topCats,
    };
  }

  Future<Map<String, dynamic>> getStatsForYear(int year) async {
    final database = await _db;
    final yearStr = year.toString();

    final summary = await database.rawQuery('''
      SELECT
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units
            WHEN a.account_type = 'income' AND p.direction = 'debit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS income,
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units
            WHEN a.account_type = 'expense' AND p.direction = 'credit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS expense,
        COUNT(DISTINCT e.id) AS txn_count,
        COALESCE(MAX(CASE WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units ELSE 0 END), 0) / 100.0 AS biggest_expense
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND e.event_type != 'opening_balance'
        AND strftime('%Y', e.timestamp) = ?;
    ''', [yearStr]);

    final monthly = await database.rawQuery('''
      SELECT
        strftime('%m', e.timestamp) AS m,
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'income' AND p.direction = 'credit' THEN p.amount_minor_units
            WHEN a.account_type = 'income' AND p.direction = 'debit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS income,
        COALESCE(SUM(
          CASE
            WHEN a.account_type = 'expense' AND p.direction = 'debit' THEN p.amount_minor_units
            WHEN a.account_type = 'expense' AND p.direction = 'credit' THEN -p.amount_minor_units
            ELSE 0
          END
        ), 0) / 100.0 AS expense
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND e.event_type != 'opening_balance'
        AND strftime('%Y', e.timestamp) = ?
      GROUP BY m ORDER BY m ASC;
    ''', [yearStr]);

    final topCats = await database.rawQuery('''
      SELECT a.id AS category_id, a.name, a.icon_name AS icon, a.color_hex AS color,
             COALESCE(SUM(
               CASE
                 WHEN p.direction = 'debit' THEN p.amount_minor_units
                 WHEN p.direction = 'credit' THEN -p.amount_minor_units
                 ELSE 0
               END
             ), 0) / 100.0 AS total
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.accounts} a ON p.account_id = a.id
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
        AND a.account_type = 'expense'
        AND e.event_type != 'opening_balance'
        AND strftime('%Y', e.timestamp) = ?
      GROUP BY a.id
      ORDER BY total DESC
      LIMIT 5;
    ''', [yearStr]);

    final Map<int, double> incomeByMonth = {};
    final Map<int, double> expenseByMonth = {};
    for (final row in monthly) {
      final m = int.tryParse(row['m'] as String? ?? '0') ?? 0;
      incomeByMonth[m] = (row['income'] as num?)?.toDouble() ?? 0.0;
      expenseByMonth[m] = (row['expense'] as num?)?.toDouble() ?? 0.0;
    }

    return {
      'income': (summary.first['income'] as num?)?.toDouble() ?? 0.0,
      'expense': (summary.first['expense'] as num?)?.toDouble() ?? 0.0,
      'txn_count': (summary.first['txn_count'] as num?)?.toInt() ?? 0,
      'biggest_expense':
          (summary.first['biggest_expense'] as num?)?.toDouble() ?? 0.0,
      'top_categories': topCats,
      'monthly_income': List.generate(12, (i) => incomeByMonth[i + 1] ?? 0.0),
      'monthly_expense': List.generate(12, (i) => expenseByMonth[i + 1] ?? 0.0),
    };
  }

  Future<List<String>> getDistinctMonths({int limit = 12}) async {
    final database = await _db;
    final result = await database.rawQuery('''
      SELECT DISTINCT strftime('%Y-%m', timestamp) AS month
      FROM ${TablesV24.economicEvents}
      WHERE lifecycle_status = 'posted'
        AND description NOT LIKE 'REVERSAL:%'
      ORDER BY month DESC
      LIMIT ?;
    ''', [limit]);
    return result.map((r) => r['month'] as String).toList();
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

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
}
