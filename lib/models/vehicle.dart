import 'package:uuid/uuid.dart';

/// Represents a vehicle (bike, car, etc.)
class Vehicle {
  final String id;
  final String userId;
  final String name;
  final String type;
  final String? regNumber;
  final String fuelType;
  final double? tankCapacity; // litres, optional
  final DateTime createdAt;

  Vehicle({
    String? id,
    this.userId = 'offline_user',
    required this.name,
    this.type = 'bike',
    this.regNumber,
    this.fuelType = 'petrol',
    this.tankCapacity,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'name': name,
        'type': type,
        'reg_number': regNumber,
        'fuel_type': fuelType,
        'tank_capacity': tankCapacity,
        'created_at': createdAt.toIso8601String(),
      };

  factory Vehicle.fromMap(Map<String, dynamic> map) => Vehicle(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        name: map['name'] as String,
        type: map['type'] as String? ?? 'bike',
        regNumber: map['reg_number'] as String?,
        fuelType: map['fuel_type'] as String? ?? 'petrol',
        tankCapacity: map['tank_capacity'] != null ? (map['tank_capacity'] as num).toDouble() : null,
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}

/// Represents a fuel fill-up log for a vehicle
class FuelLog {
  final String id;
  final String vehicleId;
  final double odometer; // km reading at fill-up
  final double litres;
  final double pricePerLitre;
  final double totalCost;
  final double? efficiency; // km/litre, calculated
  final DateTime date;
  final String? location;
  final bool isFullTank;
  final String? notes;

  FuelLog({
    String? id,
    required this.vehicleId,
    required this.odometer,
    required this.litres,
    required this.pricePerLitre,
    required this.totalCost,
    this.efficiency,
    DateTime? date,
    this.location,
    this.isFullTank = true,
    this.notes,
  })  : id = id ?? const Uuid().v4(),
        date = date ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'vehicle_id': vehicleId,
        'odometer': odometer,
        'litres': litres,
        'price_per_litre': pricePerLitre,
        'total_cost': totalCost,
        'efficiency': efficiency,
        'date': date.toIso8601String(),
        'location': location,
        'is_full_tank': isFullTank ? 1 : 0,
        'notes': notes,
      };

  factory FuelLog.fromMap(Map<String, dynamic> map) => FuelLog(
        id: map['id'] as String,
        vehicleId: map['vehicle_id'] as String,
        odometer: (map['odometer'] as num).toDouble(),
        litres: (map['litres'] as num).toDouble(),
        pricePerLitre: (map['price_per_litre'] as num).toDouble(),
        totalCost: (map['total_cost'] as num).toDouble(),
        efficiency: map['efficiency'] != null ? (map['efficiency'] as num).toDouble() : null,
        date: DateTime.parse(map['date'] as String),
        location: map['location'] as String?,
        isFullTank: map['is_full_tank'] == null ? true : (map['is_full_tank'] as int) == 1,
        notes: map['notes'] as String?,
      );
}
