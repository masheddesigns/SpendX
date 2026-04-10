import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../../models/streak.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class StreakRepo {
  final db = AppDatabase.instance;

  Future<Streak> get() async {
    final database = await db.database;
    final res = await database.query(
      Tables.streaks,
      where: 'id = ?',
      whereArgs: ['user_streak'],
      limit: 1,
    );
    if (res.isEmpty) return const Streak();
    return Streak.fromMap(res.first);
  }

  Future<void> save(Streak streak) async {
    final database = await db.database;
    await database.insert(
      Tables.streaks,
      streak.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
