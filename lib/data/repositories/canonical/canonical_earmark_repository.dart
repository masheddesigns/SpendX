import 'package:sqflite/sqflite.dart';
import '../../../domain/finance/finance.dart';
import '../../core/app_database.dart';
import '../../core/tables_v24.dart';
import 'canonical_goal_adapter.dart';

/// Canonical Earmark Repository for SpendX 2.0.
///
/// Implements virtual savings goal reservation persistence in `asset_earmarks`.
///
/// CRITICAL ARCHITECTURAL INVARIANT:
/// An [AssetEarmark] is a soft reservation. It NEVER moves physical money and
/// generates ZERO double-entry postings.
class CanonicalEarmarkRepository {
  final DatabaseExecutor? _customExecutor;

  CanonicalEarmarkRepository({DatabaseExecutor? executor})
      : _customExecutor = executor;

  Future<DatabaseExecutor> _getExecutor(Transaction? txn) async {
    if (txn != null) return txn;
    if (_customExecutor != null) return _customExecutor;
    return await AppDatabase.instance.database;
  }

  /// Creates a virtual goal reservation.
  ///
  /// Rejects duplicate (goal_id, asset_account_id) or existing ID.
  /// Validates that the goal exists and is active, and account is a valid asset account.
  Future<void> createEarmark(
    AssetEarmark earmark, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await CanonicalGoalAdapter.validateEarmarkSafety(db, earmark);

    await db.insert(
      TablesV24.assetEarmarks,
      {
        'id': earmark.id,
        'goal_id': earmark.goalId,
        'asset_account_id': earmark.assetAccountId,
        'amount_minor_units': earmark.earmarkedAmount.minorUnits,
        'created_at': earmark.createdAt.toIso8601String(),
        'updated_at': earmark.updatedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );

    await CanonicalGoalAdapter.syncGoalProjection(db, earmark.goalId);
  }

  /// Updates an existing virtual goal reservation by ID.
  Future<void> updateEarmark(
    AssetEarmark earmark, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await CanonicalGoalAdapter.validateEarmarkSafety(db, earmark);

    final count = await db.update(
      TablesV24.assetEarmarks,
      {
        'amount_minor_units': earmark.earmarkedAmount.minorUnits,
        'updated_at': earmark.updatedAt.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [earmark.id],
    );

    if (count == 0) {
      throw ArgumentError.value(
        earmark.id,
        'id',
        'Cannot update non-existent earmark: ${earmark.id}',
      );
    }

    await CanonicalGoalAdapter.syncGoalProjection(db, earmark.goalId);
  }

  /// Upserts a virtual goal reservation.
  Future<void> setEarmark(
    AssetEarmark earmark, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await CanonicalGoalAdapter.validateEarmarkSafety(db, earmark);

    await db.insert(
      TablesV24.assetEarmarks,
      {
        'id': earmark.id,
        'goal_id': earmark.goalId,
        'asset_account_id': earmark.assetAccountId,
        'amount_minor_units': earmark.earmarkedAmount.minorUnits,
        'created_at': earmark.createdAt.toIso8601String(),
        'updated_at': earmark.updatedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await CanonicalGoalAdapter.syncGoalProjection(db, earmark.goalId);
  }

  /// Retrieves an earmark by its unique ID.
  Future<AssetEarmark?> getEarmark(
    String id, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.assetEarmarks,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToEarmark(rows.first);
  }

  /// Retrieves the earmark for a specific goal and account pair.
  Future<AssetEarmark?> getEarmarkForGoalAndAccount(
    String goalId,
    String assetAccountId, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.assetEarmarks,
      where: 'goal_id = ? AND asset_account_id = ?',
      whereArgs: [goalId, assetAccountId],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return _mapRowToEarmark(rows.first);
  }

  /// Lists all earmarks allocated for a specific savings goal.
  Future<List<AssetEarmark>> getEarmarksForGoal(
    String goalId, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.assetEarmarks,
      where: 'goal_id = ?',
      whereArgs: [goalId],
      orderBy: 'created_at ASC',
    );

    return rows.map(_mapRowToEarmark).toList();
  }

  /// Lists all earmarks reserving funds in a specific asset account.
  Future<List<AssetEarmark>> getEarmarksForAccount(
    String accountId, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final rows = await db.query(
      TablesV24.assetEarmarks,
      where: 'asset_account_id = ?',
      whereArgs: [accountId],
      orderBy: 'created_at ASC',
    );

    return rows.map(_mapRowToEarmark).toList();
  }

  /// Sums all virtual earmarks against an asset account.
  Future<Money> getTotalEarmarkedForAccount(
    String accountId, {
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(amount_minor_units), 0) AS total
      FROM ${TablesV24.assetEarmarks}
      WHERE asset_account_id = ?;
    ''', [accountId]);

    final amount = (result.first['total'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Sums all virtual earmarks designated for a specific goal.
  Future<Money> getTotalEarmarkedForGoal(
    String goalId, {
    Transaction? txn,
    String currency = 'INR',
  }) async {
    final db = await _getExecutor(txn);
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(amount_minor_units), 0) AS total
      FROM ${TablesV24.assetEarmarks}
      WHERE goal_id = ?;
    ''', [goalId]);

    final amount = (result.first['total'] as num?)?.toInt() ?? 0;
    return Money.fromMinorUnits(amount, currency: currency);
  }

  /// Deletes an earmark by ID.
  Future<void> deleteEarmark(
    String id, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    final earmark = await getEarmark(id, txn: txn);
    if (earmark == null) return;

    await db.delete(
      TablesV24.assetEarmarks,
      where: 'id = ?',
      whereArgs: [id],
    );

    await CanonicalGoalAdapter.syncGoalProjection(db, earmark.goalId);
  }

  /// Deletes all earmarks associated with a savings goal.
  Future<void> deleteEarmarksForGoal(
    String goalId, {
    Transaction? txn,
  }) async {
    final db = await _getExecutor(txn);
    await db.delete(
      TablesV24.assetEarmarks,
      where: 'goal_id = ?',
      whereArgs: [goalId],
    );

    await CanonicalGoalAdapter.syncGoalProjection(db, goalId);
  }

  AssetEarmark _mapRowToEarmark(Map<String, dynamic> row) {
    return AssetEarmark(
      id: row['id'] as String,
      goalId: row['goal_id'] as String,
      assetAccountId: row['asset_account_id'] as String,
      earmarkedAmount: Money.fromMinorUnits((row['amount_minor_units'] as num).toInt()),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
