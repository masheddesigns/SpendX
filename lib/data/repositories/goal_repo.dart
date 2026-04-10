import 'package:flutter/foundation.dart' show debugPrint;

import '../../models/goal.dart';
import '../../models/goal_log.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class GoalRepo {
  final db = AppDatabase.instance;

  Future<List<Goal>> getAll() async {
    final database = await db.database;
    final res = await database.query(
      Tables.goals,
      orderBy: 'created_at DESC',
    );
    debugPrint('🎯 Goals fetched: ${res.length}');
    return res.map((e) => Goal.fromMap(e)).toList();
  }

  Future<List<Goal>> getActive() async {
    final database = await db.database;
    final res = await database.query(
      Tables.goals,
      where: 'is_active = ?',
      whereArgs: [1],
      orderBy: 'end_date ASC',
    );
    return res.map((e) => Goal.fromMap(e)).toList();
  }

  Future<void> insert(Goal goal) async {
    final database = await db.database;
    await database.insert(Tables.goals, goal.toMap());
    debugPrint('🎯 Goal inserted: ${goal.title} (${goal.type.name}, target: ${goal.targetAmount})');
  }

  Future<void> update(Goal goal) async {
    final database = await db.database;
    await database.update(
      Tables.goals,
      goal.toMap(),
      where: 'id = ?',
      whereArgs: [goal.id],
    );
  }

  Future<void> updateProgress(String id, double currentAmount) async {
    final database = await db.database;
    await database.update(
      Tables.goals,
      {'current_amount': currentAmount},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final database = await db.database;
    // Delete logs first, then the goal
    await database.delete(Tables.goalLogs, where: 'goal_id = ?', whereArgs: [id]);
    await database.delete(Tables.goals, where: 'id = ?', whereArgs: [id]);
  }

  // ── Goal Logs ──────────────────────────────────────────────────────

  Future<List<GoalLog>> getLogs(String goalId) async {
    final database = await db.database;
    final res = await database.query(
      Tables.goalLogs,
      where: 'goal_id = ?',
      whereArgs: [goalId],
      orderBy: 'created_at DESC',
    );
    return res.map((e) => GoalLog.fromMap(e)).toList();
  }

  /// Insert a log entry and update the goal's currentAmount atomically.
  Future<void> addLog(GoalLog log) async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.insert(Tables.goalLogs, log.toMap());
      await txn.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = current_amount + ? WHERE id = ?',
        [log.amount, log.goalId],
      );
    });
    debugPrint('🎯 Goal log added: ${log.amount} to ${log.goalId}');
  }

  /// Delete a log entry and subtract its amount from the goal.
  Future<void> deleteLog(GoalLog log) async {
    final database = await db.database;
    await database.transaction((txn) async {
      await txn.delete(Tables.goalLogs, where: 'id = ?', whereArgs: [log.id]);
      await txn.rawUpdate(
        'UPDATE ${Tables.goals} SET current_amount = MAX(0, current_amount - ?) WHERE id = ?',
        [log.amount, log.goalId],
      );
    });
    debugPrint('🎯 Goal log deleted: ${log.amount} from ${log.goalId}');
  }
}
