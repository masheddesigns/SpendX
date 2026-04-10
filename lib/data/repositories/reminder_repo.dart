import '../core/app_database.dart';
import '../core/tables.dart';
import '../../models/reminder_model.dart';
import 'package:sqflite/sqflite.dart';

class ReminderRepo {
  final db = AppDatabase.instance;

  Future<List<Reminder>> getAll() async {
    final database = await db.database;
    final results = await database.query(
      Tables.reminders,
      orderBy: 'created_at DESC',
    );
    return results.map(Reminder.fromMap).toList();
  }

  Future<Reminder?> getById(String id) async {
    final database = await db.database;
    final results = await database.query(
      Tables.reminders,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) {
      return null;
    }
    return Reminder.fromMap(results.first);
  }

  Future<void> insertGlobalReminder(Map<String, dynamic> reminder) async {
    final database = await db.database;
    await database.insert(
      Tables.reminders,
      reminder,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsert(Reminder reminder) async {
    await insertGlobalReminder(reminder.toMap());
  }

  Future<int> update(Reminder reminder) async {
    final database = await db.database;
    return database.update(
      Tables.reminders,
      reminder.toMap(),
      where: 'id = ?',
      whereArgs: [reminder.id],
    );
  }

  Future<void> deleteGlobalReminder(String id) async {
    final database = await db.database;
    await database.delete(Tables.reminders, where: 'id = ?', whereArgs: [id]);
  }
}
