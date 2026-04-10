import '../core/app_database.dart';
import '../core/tables.dart';
import '../../models/lending.dart';
import 'package:sqflite/sqflite.dart';

class LendingRepo {
  final _dbProvider = AppDatabase.instance;

  Future<List<Lending>> getAll({bool? settledFilter}) async {
    final db = await _dbProvider.database;
    String? where;
    List<dynamic>? whereArgs;
    
    if (settledFilter != null) {
      where = 'is_settled = ?';
      whereArgs = [settledFilter ? 1 : 0];
    }
    
    final maps = await db.query(
      Tables.lendings,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'date DESC',
    );
    return maps.map((m) => Lending.fromMap(m)).toList();
  }

  Future<Lending?> getById(String id) async {
    final db = await _dbProvider.database;
    final maps = await db.query(
      Tables.lendings,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return maps.isEmpty ? null : Lending.fromMap(maps.first);
  }

  Future<String> insert(Lending lending) async {
    final db = await _dbProvider.database;
    await db.insert(
      Tables.lendings,
      lending.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return lending.id;
  }

  Future<int> update(Lending lending) async {
    final db = await _dbProvider.database;
    return await db.update(
      Tables.lendings,
      lending.toMap(),
      where: 'id = ?',
      whereArgs: [lending.id],
    );
  }

  Future<int> delete(String id) async {
    final db = await _dbProvider.database;
    return await db.delete(
      Tables.lendings,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

}
