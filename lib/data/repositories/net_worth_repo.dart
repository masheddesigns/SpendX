import 'package:uuid/uuid.dart';

import '../core/app_database.dart';
import '../core/tables.dart';
import '../../models/net_worth_snapshot_record.dart';

class NetWorthRepo {
  final db = AppDatabase.instance;

  Future<void> insertSnapshot({
    required String id,
    required double netWorth,
    required double assets,
    required double liabilities,
    required DateTime timestamp,
  }) async {
    final database = await db.database;
    await database.insert(Tables.netWorthHistory, {
      'id': id,
      'net_worth': netWorth,
      'assets': assets,
      'liabilities': liabilities,
      'timestamp': timestamp.toIso8601String(),
    });
  }

  /// Insert a snapshot only if one doesn't already exist for today.
  /// Returns true if a new snapshot was inserted, false if today already has one.
  Future<bool> insertDailySnapshot({
    required double netWorth,
    required double assets,
    required double liabilities,
  }) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day).toIso8601String();
    final tomorrowStart = DateTime(now.year, now.month, now.day + 1).toIso8601String();

    final database = await db.database;
    final existing = await database.query(
      Tables.netWorthHistory,
      where: 'timestamp >= ? AND timestamp < ?',
      whereArgs: [todayStart, tomorrowStart],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      // Update today's snapshot with latest values
      await database.update(
        Tables.netWorthHistory,
        {
          'net_worth': netWorth,
          'assets': assets,
          'liabilities': liabilities,
          'timestamp': now.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
      return false;
    }

    await database.insert(Tables.netWorthHistory, {
      'id': const Uuid().v4(),
      'net_worth': netWorth,
      'assets': assets,
      'liabilities': liabilities,
      'timestamp': now.toIso8601String(),
    });
    return true;
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    final database = await db.database;
    return await database.query(
      Tables.netWorthHistory,
      orderBy: 'timestamp DESC',
    );
  }

  Future<List<NetWorthSnapshotRecord>> getSnapshotRecords({int? limit}) async {
    final database = await db.database;
    final results = await database.query(
      Tables.netWorthHistory,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return results.map(NetWorthSnapshotRecord.fromMap).toList();
  }

  /// Get snapshots within a date range (for timeline charts).
  Future<List<NetWorthSnapshotRecord>> getRange({
    required DateTime from,
    required DateTime to,
  }) async {
    final database = await db.database;
    final results = await database.query(
      Tables.netWorthHistory,
      where: 'timestamp >= ? AND timestamp <= ?',
      whereArgs: [from.toIso8601String(), to.toIso8601String()],
      orderBy: 'timestamp ASC',
    );
    return results.map(NetWorthSnapshotRecord.fromMap).toList();
  }

  /// Get the latest snapshot.
  Future<NetWorthSnapshotRecord?> getLatest() async {
    final database = await db.database;
    final results = await database.query(
      Tables.netWorthHistory,
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    return NetWorthSnapshotRecord.fromMap(results.first);
  }

  Future<int> deleteSnapshot(String id) async {
    final database = await db.database;
    return database.delete(
      Tables.netWorthHistory,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
