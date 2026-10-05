import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';

import '../../domain/finance/finance.dart';
import '../../models/goal.dart';
import '../../models/goal_log.dart';
import '../core/app_database.dart';
import '../core/tables.dart';
import 'canonical/canonical_earmark_repository.dart';
import 'canonical/canonical_goal_adapter.dart';

/// Repository for Goal lifecycle and Asset Earmark reservations in SpendX 2.0.
///
/// CRITICAL ARCHITECTURAL INVARIANTS:
/// 1. Goals are NOT accounting entities. They produce ZERO economic events and ZERO postings.
/// 2. Asset earmarks are soft reservations on real asset accounts, NOT money movements.
/// 3. Earmark creation, modification, and removal have ZERO impact on ledger balances, net worth, income, or expense.
/// 4. Goal progress is derived dynamically from active asset earmarks (`TablesV24.assetEarmarks`).
/// 5. Legacy `goals.current_amount` is strictly a non-authoritative compatibility projection.
class GoalRepo {
  final AppDatabase db;
  final CanonicalEarmarkRepository _earmarkRepo;
  final DatabaseExecutor? _customExecutor;

  GoalRepo({
    AppDatabase? database,
    CanonicalEarmarkRepository? earmarkRepo,
    DatabaseExecutor? executor,
  })  : db = database ?? AppDatabase.instance,
        _customExecutor = executor,
        _earmarkRepo = earmarkRepo ?? CanonicalEarmarkRepository(executor: executor);

  Future<DatabaseExecutor> _getDb([Transaction? txn]) async {
    if (txn != null) return txn;
    if (_customExecutor != null) return _customExecutor;
    return await db.database;
  }

  // ── 1. Goal Queries (DERIVED) ──────────────────────────────────────────

  /// Fetches all goals with dynamically derived progress.
  Future<List<Goal>> getAll({Transaction? txn}) async {
    final database = await _getDb(txn);
    final res = await database.query(
      Tables.goals,
      orderBy: 'created_at DESC',
    );
    debugPrint('🎯 Goals fetched: ${res.length}');

    final goals = <Goal>[];
    for (final row in res) {
      goals.add(await CanonicalGoalAdapter.projectGoal(database, row));
    }
    return goals;
  }

  /// Fetches all active goals with dynamically derived progress.
  Future<List<Goal>> getActive({Transaction? txn}) async {
    final database = await _getDb(txn);
    final res = await database.query(
      Tables.goals,
      where: 'is_active = ?',
      whereArgs: [1],
      orderBy: 'end_date ASC',
    );

    final goals = <Goal>[];
    for (final row in res) {
      goals.add(await CanonicalGoalAdapter.projectGoal(database, row));
    }
    return goals;
  }

  /// Fetches a single goal by ID with dynamically derived progress.
  Future<Goal?> getGoalById(String id, {Transaction? txn}) async {
    final database = await _getDb(txn);
    final res = await database.query(
      Tables.goals,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (res.isEmpty) return null;
    return await CanonicalGoalAdapter.projectGoal(database, res.first);
  }

  /// Calculates dynamically derived progress for a goal based on active earmarks.
  Future<double> getDerivedProgress(String goalId, {Transaction? txn}) async {
    final database = await _getDb(txn);
    return await CanonicalGoalAdapter.getDerivedGoalProgress(database, goalId);
  }

  // ── 2. Goal Lifecycle (CANONICAL_METADATA) ─────────────────────────────

  /// Inserts a new savings goal.
  /// Produces ZERO economic events and ZERO postings.
  Future<void> insert(Goal goal, {Transaction? txn}) async {
    final database = await _getDb(txn);
    await database.insert(Tables.goals, goal.toMap());
    debugPrint(
      '🎯 Goal inserted: ${goal.title} (${goal.type.name}, target: ${goal.targetAmount})',
    );
  }

  /// Updates goal metadata.
  /// Produces ZERO economic events and ZERO postings.
  Future<void> update(Goal goal, {Transaction? txn}) async {
    final database = await _getDb(txn);
    await database.update(
      Tables.goals,
      goal.toMap(),
      where: 'id = ?',
      whereArgs: [goal.id],
    );
  }

  /// Atomically deletes a goal, releasing its asset earmarks and operational logs.
  /// Does NOT delete or alter any financial accounting history.
  Future<void> delete(String id, {Transaction? txn}) async {
    final database = await _getDb(txn);
    if (txn != null) {
      await _deleteInternal(txn, id);
    } else if (database is Database) {
      await database.transaction((t) async {
        await _deleteInternal(t, id);
      });
    } else {
      await _deleteInternal(database, id);
    }
    debugPrint('🎯 Goal deleted: $id and its earmarks released');
  }

  Future<void> _deleteInternal(DatabaseExecutor db, String id) async {
    // 1. Release all asset reservations for this goal
    await _earmarkRepo.deleteEarmarksForGoal(id, txn: db is Transaction ? db : null);
    // 2. Delete operational goal logs
    await db.delete(
      Tables.goalLogs,
      where: 'goal_id = ?',
      whereArgs: [id],
    );
    // 3. Delete goal projection
    await db.delete(
      Tables.goals,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── 3. Asset Earmarks / Reservations (CANONICAL_METADATA & DERIVED) ────

  /// Creates a virtual asset reservation against an asset account.
  /// Produces ZERO economic events and ZERO postings.
  Future<void> createEarmark(
    AssetEarmark earmark, {
    Transaction? txn,
  }) async {
    await _earmarkRepo.createEarmark(earmark, txn: txn);
  }

  /// Upserts a virtual asset reservation.
  /// Produces ZERO economic events and ZERO postings.
  Future<void> setEarmark(
    AssetEarmark earmark, {
    Transaction? txn,
  }) async {
    await _earmarkRepo.setEarmark(earmark, txn: txn);
  }

  /// Deletes a specific asset reservation.
  /// Produces ZERO economic events and ZERO postings.
  Future<void> deleteEarmark(
    String id, {
    Transaction? txn,
  }) async {
    await _earmarkRepo.deleteEarmark(id, txn: txn);
  }

  /// Lists all active earmarks allocated for a specific goal.
  Future<List<AssetEarmark>> getEarmarks(
    String goalId, {
    Transaction? txn,
  }) async {
    return await _earmarkRepo.getEarmarksForGoal(goalId, txn: txn);
  }

  /// Alias for [getEarmarks].
  Future<List<AssetEarmark>> getEarmarksForGoal(
    String goalId, {
    Transaction? txn,
  }) async => getEarmarks(goalId, txn: txn);

  /// Sums all virtual earmarks reserving funds in a specific asset account.
  Future<Money> getTotalEarmarkedForAccount(
    String accountId, {
    Transaction? txn,
  }) async {
    return await _earmarkRepo.getTotalEarmarkedForAccount(accountId, txn: txn);
  }

  // ── 4. Transitional Compatibility Layer ────────────────────────────────

  /// Updates the cached progress in `goals.current_amount`.
  /// Strictly non-authoritative compatibility projection.
  Future<void> updateProgress(String id, double currentAmount, {Transaction? txn}) async {
    final database = await _getDb(txn);
    await database.update(
      Tables.goals,
      {'current_amount': currentAmount},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Fetches legacy operational logs for a goal.
  Future<List<GoalLog>> getLogs(String goalId, {Transaction? txn}) async {
    final database = await _getDb(txn);
    final res = await database.query(
      Tables.goalLogs,
      where: 'goal_id = ?',
      whereArgs: [goalId],
      orderBy: 'created_at DESC',
    );
    return res.map((e) => GoalLog.fromMap(e)).toList();
  }

  /// Inserts a log entry and updates the goal's projected currentAmount atomically.
  /// Produces ZERO economic events and ZERO postings.
  Future<void> addLog(GoalLog log, {Transaction? txn}) async {
    final database = await _getDb(txn);
    if (txn != null) {
      await txn.insert(Tables.goalLogs, log.toMap());
      await txn.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = current_amount + ? WHERE id = ?',
        [log.amount, log.goalId],
      );
    } else if (database is Database) {
      await database.transaction((t) async {
        await t.insert(Tables.goalLogs, log.toMap());
        await t.rawUpdate(
          'UPDATE ${Tables.goals} SET current_amount = current_amount + ? WHERE id = ?',
          [log.amount, log.goalId],
        );
      });
    } else {
      await database.insert(Tables.goalLogs, log.toMap());
      await database.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = current_amount + ? WHERE id = ?',
        [log.amount, log.goalId],
      );
    }
    debugPrint('🎯 Goal log added: ${log.amount} to ${log.goalId}');
  }

  /// Deletes a log entry and subtracts its amount from the goal's projected currentAmount.
  /// Produces ZERO economic events and ZERO postings.
  Future<void> deleteLog(GoalLog log, {Transaction? txn}) async {
    final database = await _getDb(txn);
    if (txn != null) {
      await txn.delete(
        Tables.goalLogs,
        where: 'id = ?',
        whereArgs: [log.id],
      );
      await txn.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = MAX(0, current_amount - ?) WHERE id = ?',
        [log.amount, log.goalId],
      );
    } else if (database is Database) {
      await database.transaction((t) async {
        await t.delete(
          Tables.goalLogs,
          where: 'id = ?',
          whereArgs: [log.id],
        );
        await t.rawUpdate(
          'UPDATE ${Tables.goals} SET current_amount = MAX(0, current_amount - ?) WHERE id = ?',
          [log.amount, log.goalId],
        );
      });
    } else {
      await database.delete(
        Tables.goalLogs,
        where: 'id = ?',
        whereArgs: [log.id],
      );
      await database.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = MAX(0, current_amount - ?) WHERE id = ?',
        [log.amount, log.goalId],
      );
    }
    debugPrint('🎯 Goal log deleted: ${log.amount} from ${log.goalId}');
  }
}
