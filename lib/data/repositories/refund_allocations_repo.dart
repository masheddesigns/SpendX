import 'package:sqflite/sqflite.dart';
import '../core/app_database.dart';
import '../core/database_access_gate.dart';
import '../core/tables_v25.dart';

/// Represents a single immutable refund allocation linking a refund event
/// to an original eligible merchant purchase ('expense' or 'credit_purchase').
class RefundAllocation {
  final String id;
  final String refundEventId;
  final String originalEventId;
  final int allocatedAmountMinorUnits;
  final DateTime createdAt;

  const RefundAllocation({
    required this.id,
    required this.refundEventId,
    required this.originalEventId,
    required this.allocatedAmountMinorUnits,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'refund_event_id': refundEventId,
    'original_event_id': originalEventId,
    'allocated_amount_minor_units': allocatedAmountMinorUnits,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory RefundAllocation.fromMap(Map<String, dynamic> map) {
    return RefundAllocation(
      id: map['id'] as String,
      refundEventId: map['refund_event_id'] as String,
      originalEventId: map['original_event_id'] as String,
      allocatedAmountMinorUnits: (map['allocated_amount_minor_units'] as num).toInt(),
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefundAllocation &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          refundEventId == other.refundEventId &&
          originalEventId == other.originalEventId &&
          allocatedAmountMinorUnits == other.allocatedAmountMinorUnits;

  @override
  int get hashCode =>
      id.hashCode ^
      refundEventId.hashCode ^
      originalEventId.hashCode ^
      allocatedAmountMinorUnits.hashCode;

  @override
  String toString() =>
      'RefundAllocation(id: $id, refund: $refundEventId, original: $originalEventId, amount: $allocatedAmountMinorUnits)';
}

/// Repository for managing [RefundAllocation] entities.
///
/// Transaction Ownership Contract:
/// - All mutation operations strictly require [txn] of type [DatabaseExecutor].
///   There is NO fallback to a global database connection, ensuring that refund
///   allocations are always committed atomically alongside economic events,
///   postings, and evidence in a single transaction.
/// - In accordance with SQLite Triggers 2 & 3, refund allocations are strictly
///   immutable. Direct updates and deletes are permanently prohibited by the
///   database schema.
class RefundAllocationsRepo {
  final DatabaseExecutor? _customExecutor;

  RefundAllocationsRepo({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor([DatabaseExecutor? executor]) async {
    if (executor != null) {
      return DatabaseAccessGate.instance.wrapExecutor(executor);
    }
    if (_customExecutor != null) {
      return DatabaseAccessGate.instance.wrapExecutor(_customExecutor);
    }
    return await AppDatabase.instance.database;
  }

  /// Inserts a new [RefundAllocation] into the database.
  ///
  /// Requires an active [txn] handle. Throws if the database trigger suite
  /// aborts the insert (e.g. non-draft refund, invalid parent purchase type,
  /// ambiguous posting structure, or allocation exceeding original purchase amount).
  Future<void> insertAllocation({
    required DatabaseExecutor txn,
    required RefundAllocation allocation,
  }) async {
    final wrapped = DatabaseAccessGate.instance.wrapExecutor(txn);
    await wrapped.insert(
      TablesV25.refundAllocations,
      allocation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// Finds the refund allocation for a specific [refundEventId].
  ///
  /// Since `idx_refund_alloc_refund` enforces a UNIQUE constraint, each refund
  /// event can have at most one allocation.
  Future<RefundAllocation?> findByRefundEventId(
    String refundEventId, {
    DatabaseExecutor? executor,
  }) async {
    final db = await _getExecutor(executor);
    final results = await db.query(
      TablesV25.refundAllocations,
      where: 'refund_event_id = ?',
      whereArgs: [refundEventId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return RefundAllocation.fromMap(results.first);
  }

  /// Finds all refund allocations targeting a specific [originalEventId].
  Future<List<RefundAllocation>> findByOriginalEventId(
    String originalEventId, {
    DatabaseExecutor? executor,
  }) async {
    final db = await _getExecutor(executor);
    final results = await db.query(
      TablesV25.refundAllocations,
      where: 'original_event_id = ?',
      whereArgs: [originalEventId],
      orderBy: 'created_at ASC',
    );
    return results.map(RefundAllocation.fromMap).toList();
  }

  /// Returns the cumulative allocated minor units across all active (posted)
  /// refunds for the given [originalEventId].
  Future<int> getCumulativeAllocatedAmount(
    String originalEventId, {
    DatabaseExecutor? executor,
  }) async {
    final db = await _getExecutor(executor);
    final results = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(ra.allocated_amount_minor_units), 0) AS total_allocated
      FROM ${TablesV25.refundAllocations} ra
      JOIN economic_events ee ON ra.refund_event_id = ee.id
      WHERE ra.original_event_id = ?
        AND ee.lifecycle_status = 'posted'
      ''',
      [originalEventId],
    );
    if (results.isEmpty) return 0;
    return (results.first['total_allocated'] as num?)?.toInt() ?? 0;
  }

  /// Finds a refund allocation by its primary key [id].
  Future<RefundAllocation?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) async {
    final db = await _getExecutor(executor);
    final results = await db.query(
      TablesV25.refundAllocations,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return RefundAllocation.fromMap(results.first);
  }
}
