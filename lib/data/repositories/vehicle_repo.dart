import '../../models/vehicle.dart';
import '../core/app_database.dart';
import '../core/tables.dart';
import '../../models/transaction.dart' as spx;
import 'package:sqflite/sqflite.dart';

class VehicleRepo {
  final db = AppDatabase.instance;

  Future<List<Map<String, dynamic>>> getAll() async {
    final database = await db.database;
    return await database.query(Tables.vehicles);
  }

  Future<List<Vehicle>> getAllVehicles() async {
    final rows = await getAll();
    return rows.map(Vehicle.fromMap).toList();
  }

  Future<Vehicle?> getVehicleById(String id) async {
    final database = await db.database;
    final rows = await database.query(
      Tables.vehicles,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Vehicle.fromMap(rows.first);
  }

  Future<String> insert(Map<String, dynamic> vehicle) async {
    final database = await db.database;
    final id =
        vehicle['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final data = Map<String, dynamic>.from(vehicle)..['id'] = id;
    await database.insert(Tables.vehicles, data);
    return id;
  }

  Future<String> insertVehicle(Vehicle vehicle) async {
    return insert(vehicle.toMap());
  }

  Future<int> deleteVehicle(String id) async {
    final database = await db.database;
    return await database.delete(
      Tables.vehicles,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<FuelLog>> getFuelLogsForVehicle(
    String vehicleId, {
    int? limit,
    int? offset,
  }) async {
    final database = await db.database;
    final results = await database.query(
      Tables.fuelLogs,
      where: 'vehicle_id = ?',
      whereArgs: [vehicleId],
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return results.map(_mapFuelLogRow).toList();
  }

  Future<FuelLog?> getFuelLogById(String id) async {
    final database = await db.database;
    final results = await database.query(
      Tables.fuelLogs,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) {
      return null;
    }
    return _mapFuelLogRow(results.first);
  }

  Future<void> insertFuelLog(FuelLog log) async {
    final database = await db.database;
    await database.insert(
      Tables.fuelLogs,
      _fuelLogToRow(log),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> deleteFuelLog(String id) async {
    final database = await db.database;
    return database.delete(Tables.fuelLogs, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<spx.Transaction>> getTransactionsForVehicle(
    String vehicleId,
  ) async {
    final database = await db.database;
    final results = await database.query(
      Tables.transactions,
      where: 'vehicle_id = ? OR (related_entity_id = ? AND source = ?)',
      whereArgs: [vehicleId, vehicleId, 'vehicle'],
      orderBy: 'date DESC',
    );
    return results.map(spx.Transaction.fromMap).toList();
  }

  Future<List<FuelLog>> getAllFuelLogs() async {
    final database = await db.database;
    final results = await database.query(Tables.fuelLogs, orderBy: 'date ASC');
    return results.map(_mapFuelLogRow).toList();
  }

  FuelLog _mapFuelLogRow(Map<String, dynamic> row) {
    final normalized = Map<String, dynamic>.from(row);
    normalized.putIfAbsent('litres', () => normalized['quantity']);
    normalized.putIfAbsent(
      'price_per_litre',
      () => normalized['price_per_unit'],
    );
    normalized.putIfAbsent('date', () => normalized['created_at']);
    return FuelLog.fromMap(normalized);
  }

  Map<String, dynamic> _fuelLogToRow(FuelLog log) {
    return {
      'id': log.id,
      'vehicle_id': log.vehicleId,
      'date': log.date.toIso8601String(),
      'odometer': log.odometer,
      'quantity': log.litres,
      'price_per_unit': log.pricePerLitre,
      'total_cost': log.totalCost,
      'is_full_tank': log.isFullTank ? 1 : 0,
      'notes': log.notes,
      'created_at': log.date.toIso8601String(),
    };
  }
}
