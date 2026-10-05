import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../core/app_database.dart';
import '../../core/tables_v24.dart';

/// Canonical Opening Balance Reconciliation Repository for SpendX 2.0.
///
/// Implements audit and provenance persistence for opening balance reconciliation.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// An opening balance adjustment can NEVER be an opaque balancing figure.
/// It must preserve the exact delta between legacy reported balance and
/// reconstructed history, accompanied by mandatory provenance and reasoning.
class CanonicalOpeningBalanceRepository {
  final DatabaseExecutor? _customExecutor;

  CanonicalOpeningBalanceRepository({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor(Transaction? txn) async {
    if (txn != null) return txn;
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  /// Inserts a new opening balance reconciliation record.
  Future<void> saveReconciliation(
    OpeningBalanceReconciliation record, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await db.insert(
      TablesV24.openingBalanceReconciliations,
      {
        'id': record.id,
        'account_id': record.accountId,
        'legacy_reported_balance_minor_units':
            record.legacyReportedBalance.minorUnits,
        'reconstructed_balance_minor_units':
            record.reconstructedBalanceFromTxns.minorUnits,
        'adjustment_delta_minor_units': record.adjustmentDelta.minorUnits,
        'reconciliation_reason': record.reconciliationReason,
        'provenance_source': record.provenanceSource,
        'status': record.status.name,
        'generated_event_id': record.generatedEventId,
        'created_at': record.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Retrieves a reconciliation record by ID.
  Future<OpeningBalanceReconciliation?> getReconciliation(
    String id, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.openingBalanceReconciliations,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToReconciliation(rows.first);
  }

  /// Retrieves the reconciliation record for an account.
  Future<OpeningBalanceReconciliation?> getReconciliationForAccount(
    String accountId, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.openingBalanceReconciliations,
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToReconciliation(rows.first);
  }

  /// Lists all reconciliation records.
  Future<List<OpeningBalanceReconciliation>> listReconciliations({
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.openingBalanceReconciliations,
      orderBy: 'created_at DESC',
    );

    return rows.map(_mapRowToReconciliation).toList();
  }

  OpeningBalanceReconciliation _mapRowToReconciliation(
    Map<String, dynamic> row,
  ) {
    final statusStr = row['status'] as String;
    final status = ReconciliationStatus.values.firstWhere(
      (s) => s.name == statusStr,
      orElse: () => ReconciliationStatus.quarantined,
    );

    return OpeningBalanceReconciliation(
      id: row['id'] as String,
      accountId: row['account_id'] as String,
      legacyReportedBalance: Money.fromMinorUnits(
        (row['legacy_reported_balance_minor_units'] as num).toInt(),
      ),
      reconstructedBalanceFromTxns: Money.fromMinorUnits(
        (row['reconstructed_balance_minor_units'] as num).toInt(),
      ),
      reconciliationReason: row['reconciliation_reason'] as String,
      provenanceSource: row['provenance_source'] as String,
      status: status,
      generatedEventId: row['generated_event_id'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}
