import '../../models/vehicle_reminder.dart';
import '../core/app_database.dart';
import '../core/tables.dart';

class VehicleReminderRepo {
  final db = AppDatabase.instance;

  static const _table = Tables.vehicleReminders;

  Future<List<VehicleReminder>> getByVehicle(String vehicleId) async {
    final database = await db.database;
    final results = await database.query(
      _table,
      where: 'vehicle_id = ?',
      whereArgs: [vehicleId],
      orderBy: 'created_at DESC',
    );
    return results.map(VehicleReminder.fromMap).toList();
  }

  Future<VehicleReminder?> getById(String id) async {
    final database = await db.database;
    final results = await database.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) {
      return null;
    }
    return VehicleReminder.fromMap(results.first);
  }

  Future<bool> exists(String id) async => (await getById(id)) != null;

  Future<void> insert(VehicleReminder reminder) async {
    final database = await db.database;
    await database.insert(_table, reminder.toMap());
  }

  Future<int> update(VehicleReminder reminder) async {
    final database = await db.database;
    return database.update(
      _table,
      reminder.toMap(),
      where: 'id = ?',
      whereArgs: [reminder.id],
    );
  }

  Future<int> delete(String id) async {
    final database = await db.database;
    return database.delete(_table, where: 'id = ?', whereArgs: [id]);
  }
}
