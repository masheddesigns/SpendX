import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../core/app_database.dart';
import '../../core/tables_v24.dart';

/// Canonical repository for managing recurring rules and scheduled expected events
/// in [TablesV24.recurringRules] and [TablesV24.expectedEvents].
class CanonicalRecurringRepository {
  final DatabaseExecutor? _customExecutor;

  CanonicalRecurringRepository({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor(Transaction? txn) async {
    if (txn != null) return txn;
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  /// Retrieves all recurring rules, optionally filtering by active status.
  Future<List<RecurringRule>> getRules({
    bool activeOnly = true,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final where = activeOnly ? 'is_active = 1' : null;
    final rows = await db.query(
      TablesV24.recurringRules,
      where: where,
      orderBy: 'next_due_date ASC',
    );

    return rows.map((r) => RecurringRule.fromMap(r, currency: currency)).toList();
  }

  /// Retrieves a recurring rule by ID.
  Future<RecurringRule?> getRuleById(
    String id, {
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.recurringRules,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return RecurringRule.fromMap(rows.first, currency: currency);
  }

  /// Inserts a new recurring rule.
  Future<void> insertRule(RecurringRule rule, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    await db.insert(
      TablesV24.recurringRules,
      rule.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Updates an existing recurring rule.
  Future<void> updateRule(RecurringRule rule, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    await db.update(
      TablesV24.recurringRules,
      rule.toMap(),
      where: 'id = ?',
      whereArgs: [rule.id],
    );
  }

  /// Deletes a recurring rule by ID (cascades to expected_events via foreign key).
  Future<void> deleteRule(String id, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    await db.delete(
      TablesV24.recurringRules,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Retrieves expected events within a date range and optional status filter.
  Future<List<ExpectedEvent>> getExpectedEvents({
    DateTime? fromDate,
    DateTime? toDate,
    List<String>? statuses,
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (fromDate != null) {
      whereClauses.add('due_date >= ?');
      whereArgs.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      whereClauses.add('due_date <= ?');
      whereArgs.add(toDate.toIso8601String());
    }
    if (statuses != null && statuses.isNotEmpty) {
      final placeholders = List.filled(statuses.length, '?').join(', ');
      whereClauses.add('status IN ($placeholders)');
      whereArgs.addAll(statuses);
    }

    final rows = await db.query(
      TablesV24.expectedEvents,
      where: whereClauses.isEmpty ? null : whereClauses.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'due_date ASC',
    );

    return rows.map((r) => ExpectedEvent.fromMap(r, currency: currency)).toList();
  }

  /// Retrieves an expected event by ID.
  Future<ExpectedEvent?> getExpectedEventById(
    String id, {
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.expectedEvents,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return ExpectedEvent.fromMap(rows.first, currency: currency);
  }

  /// Inserts a new expected event.
  Future<void> insertExpectedEvent(ExpectedEvent event, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    await db.insert(
      TablesV24.expectedEvents,
      event.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Updates an expected event.
  Future<void> updateExpectedEvent(ExpectedEvent event, {Transaction? txn}) async {
    final db = await _getExecutor(txn);
    await db.update(
      TablesV24.expectedEvents,
      event.toMap(),
      where: 'id = ?',
      whereArgs: [event.id],
    );
  }

  /// Marks an expected event fulfilled by linking to a posted economic event.
  Future<void> markExpectedEventFulfilled(
    String expectedEventId,
    String fulfilledEventId, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await db.update(
      TablesV24.expectedEvents,
      {
        'status': 'fulfilled',
        'fulfilled_event_id': fulfilledEventId,
      },
      where: 'id = ?',
      whereArgs: [expectedEventId],
    );
  }

  /// Updates the status of an expected event (pending, overdue, dismissed).
  Future<void> markExpectedEventStatus(
    String expectedEventId,
    String status, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await db.update(
      TablesV24.expectedEvents,
      {'status': status},
      where: 'id = ?',
      whereArgs: [expectedEventId],
    );
  }

  /// Retrieves expected events joined with their underlying rules and category account details.
  Future<List<Map<String, dynamic>>> getExpectedCommitmentsWithRules({
    DateTime? fromDate,
    DateTime? toDate,
    List<String> statuses = const ['pending', 'overdue'],
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (fromDate != null) {
      whereClauses.add('e.due_date >= ?');
      whereArgs.add(fromDate.toIso8601String());
    }
    if (toDate != null) {
      whereClauses.add('e.due_date <= ?');
      whereArgs.add(toDate.toIso8601String());
    }
    if (statuses.isNotEmpty) {
      final placeholders = List.filled(statuses.length, '?').join(', ');
      whereClauses.add('e.status IN ($placeholders)');
      whereArgs.addAll(statuses);
    }

    final where = whereClauses.isEmpty ? '' : 'WHERE ${whereClauses.join(' AND ')}';

    return await db.rawQuery('''
      SELECT 
        e.id AS expected_id,
        e.due_date,
        e.amount_minor_units,
        e.status,
        e.rule_id,
        r.title,
        r.category_account_id,
        r.target_account_id,
        r.cadence,
        a.account_type AS category_account_type
      FROM ${TablesV24.expectedEvents} e
      LEFT JOIN ${TablesV24.recurringRules} r ON e.rule_id = r.id
      LEFT JOIN ${TablesV24.accounts} a ON r.category_account_id = a.id
      $where
      ORDER BY e.due_date ASC;
    ''', whereArgs.isEmpty ? null : whereArgs);
  }
}
