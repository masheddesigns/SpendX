import '../../models/budget.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class BudgetRepo {
  final db = AppDatabase.instance;

  Future<List<Budget>> getAll() async {
    final database = await db.database;
    final res = await database.query(Tables.budgets);
    return res.map((e) => Budget.fromMap(e)).toList();
  }

  Future<String> insert(Budget budget) async {
    final database = await db.database;
    await database.insert(Tables.budgets, budget.toMap());
    return budget.id;
  }

  Future<int> update(Budget budget) async {
    final database = await db.database;
    return await database.update(
      Tables.budgets,
      budget.toMap(),
      where: 'id = ?',
      whereArgs: [budget.id],
    );
  }

  Future<int> delete(String id) async {
    final database = await db.database;
    return await database.delete(
      Tables.budgets,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<double> getSpentForCategory(
    String categoryId,
    DateTime start,
    DateTime end,
  ) async {
    final database = await db.database;
    final res = await database.rawQuery(
      '''
      SELECT SUM(amount) as total FROM ${Tables.transactions}
      WHERE category_id = ? AND date >= ? AND date <= ? AND type = 'expense'
    ''',
      [categoryId, start.toIso8601String(), end.toIso8601String()],
    );

    return (res.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  Future<Map<String, double>> getCategorySpending(
    DateTime start,
    DateTime end,
  ) async {
    final database = await db.database;
    final res = await database.rawQuery(
      '''
      SELECT category_id, SUM(amount) as total FROM ${Tables.transactions}
      WHERE date >= ? AND date <= ? AND type = 'expense'
      GROUP BY category_id
    ''',
      [start.toIso8601String(), end.toIso8601String()],
    );

    return {
      for (var row in res)
        (row['category_id'] as String? ?? 'other'):
            (row['total'] as num?)?.toDouble() ?? 0.0,
    };
  }
}
