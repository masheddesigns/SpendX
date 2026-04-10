import '../../models/recurring_template.dart';
import '../core/app_database.dart';
import '../core/tables.dart';
import 'package:sqflite/sqflite.dart';

class RecurringRepo {
  final db = AppDatabase.instance;

  Future<List<RecurringTemplate>> getAll() async {
    final database = await db.database;
    final results = await database.query(
      Tables.recurring_templates,
      orderBy: 'next_generation DESC, created_at DESC',
    );
    return results.map(RecurringTemplate.fromMap).toList();
  }

  Future<String> insert(RecurringTemplate template) async {
    final database = await db.database;
    await database.insert(
      Tables.recurring_templates,
      _toRow(template),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return template.id;
  }

  Future<int> update(RecurringTemplate template) async {
    final database = await db.database;
    return database.update(
      Tables.recurring_templates,
      _toRow(template),
      where: 'id = ?',
      whereArgs: [template.id],
    );
  }

  Future<int> delete(String id) async {
    final database = await db.database;
    return database.delete(
      Tables.recurring_templates,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Maps to actual DB columns: id, name, amount, type, category_id,
  /// frequency, interval, day_of_month, day_of_week, last_generated,
  /// next_generation, is_active, created_at
  Map<String, dynamic> _toRow(RecurringTemplate template) {
    return {
      'id': template.id,
      'name': template.name,
      'amount': template.amount,
      'type': template.type,
      'category_id': template.categoryId,
      'frequency': template.frequency,
      'interval': 1,
      'last_generated': template.lastGeneratedDate?.toIso8601String(),
      'next_generation': template.startDate.toIso8601String(),
      'is_active': template.isActive ? 1 : 0,
      'created_at': template.createdAt.toIso8601String(),
    };
  }
}
