import '../../models/tag.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class TagRepo {
  final db = AppDatabase.instance;

  Future<List<Tag>> getAll() async {
    final database = await db.database;
    final results = await database.query(Tables.tags, orderBy: 'name ASC');
    return results.map(Tag.fromMap).toList();
  }

  Future<String> insert(Tag tag) async {
    final database = await db.database;
    await database.insert(Tables.tags, tag.toMap());
    return tag.id;
  }

  Future<int> update(Tag tag) async {
    final database = await db.database;
    return database.update(
      Tables.tags,
      tag.toMap(),
      where: 'id = ?',
      whereArgs: [tag.id],
    );
  }

  Future<int> delete(String id) async {
    final database = await db.database;
    return database.delete(Tables.tags, where: 'id = ?', whereArgs: [id]);
  }
}
