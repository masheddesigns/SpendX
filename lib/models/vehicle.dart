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
  final double? serviceIntervalKm; // km between services
  final double? lastServiceOdometer; // odometer at last service
  final DateTime createdAt;

  Vehicle({
    String? id,
    this.userId = 'offline_user',
    required this.name,
    this.type = 'bike',
    this.regNumber,
    this.fuelType = 'petrol',
    this.tankCapacity,
    this.serviceIntervalKm,
    this.lastServiceOdometer,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'type': type,
    'reg_number': regNumber,
    'fuel_type': fuelType,
    'tank_capacity': tankCapacity,
    'service_interval_km': serviceIntervalKm,
    'last_service_odo': lastServiceOdometer,
    'created_at': createdAt.toIso8601String(),
  };

  factory Vehicle.fromMap(Map<String, dynamic> map) => Vehicle(
    id: map['id'] as String,
    userId: map['user_id'] as String? ?? 'offline_user',
    name: map['name'] as String,
    type: map['type'] as String? ?? 'bike',
    regNumber: map['reg_number'] as String?,
    fuelType: map['fuel_type'] as String? ?? 'petrol',
    tankCapacity: map['tank_capacity'] != null
        ? (map['tank_capacity'] as num).toDouble()
        : null,
    serviceIntervalKm: map['service_interval_km'] != null
        ? (map['service_interval_km'] as num).toDouble()
        : null,
    lastServiceOdometer: map['last_service_odo'] != null
        ? (map['last_service_odo'] as num).toDouble()
        : null,
    createdAt: map['created_at'] != null
        ? DateTime.parse(map['created_at'] as String)
        : DateTime.now(),
  );

  Vehicle copyWith({
    String? id,
    String? userId,
    String? name,
    String? type,
    String? regNumber,
    String? fuelType,
    double? tankCapacity,
    double? serviceIntervalKm,
    double? lastServiceOdometer,
    DateTime? createdAt,
  }) => Vehicle(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    type: type ?? this.type,
    regNumber: regNumber ?? this.regNumber,
    fuelType: fuelType ?? this.fuelType,
    tankCapacity: tankCapacity ?? this.tankCapacity,
    serviceIntervalKm: serviceIntervalKm ?? this.serviceIntervalKm,
    lastServiceOdometer: lastServiceOdometer ?? this.lastServiceOdometer,
    createdAt: createdAt ?? this.createdAt,
  );
}

/// Represents a fuel fill-up log for a vehicle
class FuelLog {
  final String id;
  final String vehicleId;
  final double odometer;
  final double litres;
  final double pricePerLitre;
  final double totalCost;
  final double? efficiency;
  final DateTime date;
  final String? location;
  final bool isFullTank;
  final String? fuelType;
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
    this.fuelType,
    this.notes,
  }) : id = id ?? const Uuid().v4(),
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
    'fuel_type': fuelType,
    'notes': notes,
  };

  factory FuelLog.fromMap(Map<String, dynamic> map) => FuelLog(
    id: map['id'] as String,
    vehicleId: map['vehicle_id'] as String,
    odometer: (map['odometer'] as num).toDouble(),
    litres: (map['litres'] as num).toDouble(),
    pricePerLitre: (map['price_per_litre'] as num).toDouble(),
    totalCost: (map['total_cost'] as num).toDouble(),
    efficiency: map['efficiency'] != null
        ? (map['efficiency'] as num).toDouble()
        : null,
    date: DateTime.parse(map['date'] as String),
    location: map['location'] as String?,
    isFullTank: map['is_full_tank'] == null
        ? true
        : (map['is_full_tank'] as int) == 1,
    fuelType: map['fuel_type'] as String?,
    notes: map['notes'] as String?,
  );

  FuelLog copyWith({
    String? id,
    String? vehicleId,
    double? odometer,
    double? litres,
    double? pricePerLitre,
    double? totalCost,
    double? efficiency,
    DateTime? date,
    String? location,
    bool? isFullTank,
    String? fuelType,
    String? notes,
  }) => FuelLog(
    id: id ?? this.id,
    vehicleId: vehicleId ?? this.vehicleId,
    odometer: odometer ?? this.odometer,
    litres: litres ?? this.litres,
    pricePerLitre: pricePerLitre ?? this.pricePerLitre,
    totalCost: totalCost ?? this.totalCost,
    efficiency: efficiency ?? this.efficiency,
    date: date ?? this.date,
    location: location ?? this.location,
    isFullTank: isFullTank ?? this.isFullTank,
    fuelType: fuelType ?? this.fuelType,
    notes: notes ?? this.notes,
  );
}
