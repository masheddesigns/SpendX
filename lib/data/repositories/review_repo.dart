import '../../models/review_item.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class ReviewRepo {
  final db = AppDatabase.instance;

  Future<List<ReviewItem>> getPending() async {
    final database = await db.database;
    final res = await database.query(
      Tables.reviewQueue,
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at DESC',
    );
    return res.map((e) => ReviewItem.fromMap(e)).toList();
  }

  Future<int> getPendingCount() async {
    final database = await db.database;
    final res = await database.rawQuery(
      'SELECT COUNT(*) as cnt FROM ${Tables.reviewQueue} WHERE status = ?',
      ['pending'],
    );
    return (res.first['cnt'] as int?) ?? 0;
  }

  Future<void> insert(ReviewItem item) async {
    final database = await db.database;
    await database.insert(Tables.reviewQueue, item.toMap());
  }

  Future<void> insertAll(List<ReviewItem> items) async {
    if (items.isEmpty) return;
    final database = await db.database;
    final batch = database.batch();
    for (final item in items) {
      batch.insert(Tables.reviewQueue, item.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<void> approve(String id) async {
    final database = await db.database;
    await database.update(
      Tables.reviewQueue,
      {'status': 'approved'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> reject(String id) async {
    final database = await db.database;
    await database.delete(
      Tables.reviewQueue,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> rejectAll() async {
    final database = await db.database;
    await database.delete(
      Tables.reviewQueue,
      where: 'status = ?',
      whereArgs: ['pending'],
    );
  }

  Future<void> deleteApproved() async {
    final database = await db.database;
    await database.delete(
      Tables.reviewQueue,
      where: 'status = ?',
      whereArgs: ['approved'],
    );
  }
}
