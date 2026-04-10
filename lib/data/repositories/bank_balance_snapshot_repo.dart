import '../../models/bank_balance_snapshot.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class BankBalanceSnapshotRepo {
  final db = AppDatabase.instance;

  static const tableName = Tables.bankBalanceSnapshots;

  Future<void> insert(BankBalanceSnapshot snapshot) async {
    final database = await db.database;
    await database.insert(tableName, snapshot.toMap());
  }

  Future<bool> existsForDate(String accountId, int normalizedTimestamp) async {
    final database = await db.database;
    final result = await database.query(
      tableName,
      where: 'accountId = ? AND timestamp = ?',
      whereArgs: [accountId, normalizedTimestamp],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  Future<void> pruneBefore(int thresholdTimestamp) async {
    final database = await db.database;
    await database.delete(
      tableName,
      where: 'timestamp < ?',
      whereArgs: [thresholdTimestamp],
    );
  }

  Future<Map<String, dynamic>?> getHighestBalance(String accountId) async {
    final database = await db.database;
    final result = await database.rawQuery(
      '''
        SELECT balance, timestamp FROM $tableName
        WHERE accountId = ?
        ORDER BY balance DESC
        LIMIT 1
      ''',
      [accountId],
    );

    if (result.isEmpty) {
      return null;
    }
    return result.first;
  }

  Future<List<BankBalanceSnapshot>> getSnapshotsForAccount(
    String accountId,
  ) async {
    final database = await db.database;
    final rows = await database.query(
      tableName,
      where: 'accountId = ?',
      whereArgs: [accountId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(BankBalanceSnapshot.fromMap).toList();
  }
}
