import 'package:uuid/uuid.dart';

/// Full transaction model aligned with the spendx_local.db `transactions` table.
/// Fields match the schema as of DB version 40.
class TransactionModel {
  final String id;
  final String userId;
  final double amount;
  final String type; // 'income' | 'expense'
  final String? categoryId;
  final String? category; // legacy display name fallback
  final String date; // ISO-8601 string e.g. '2024-03-15T10:30:00.000'
  final String? notes;
  final String? source; // 'manual' | 'bank_account' | 'credit_card' | 'vehicle' | 'fuel_log'
  final String? relatedEntityId; // bank account / credit card id
  final String? vehicleId;
  final bool isVehicleExpense;
  final String? fuelLogId;
  final String? sourceType; // unified source classification (v40+)
  final String? sourceId;
  final String? location;
  final String? tags;
  final bool isDeleted;
  final String createdAt;
  final String updatedAt;

  TransactionModel({
    String? id,
    String? userId,
    required this.amount,
    required this.type,
    this.categoryId,
    this.category,
    String? date,
    this.notes,
    this.source = 'manual',
    this.relatedEntityId,
    this.vehicleId,
    this.isVehicleExpense = false,
    this.fuelLogId,
    this.sourceType,
    this.sourceId,
    this.location,
    this.tags,
    this.isDeleted = false,
    String? createdAt,
    String? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        userId = userId ?? 'default',
        date = date ?? DateTime.now().toIso8601String(),
        createdAt = createdAt ?? DateTime.now().toIso8601String(),
        updatedAt = updatedAt ?? DateTime.now().toIso8601String();

  /// Reconstruct from SQLite row map.
  factory TransactionModel.fromMap(Map<String, dynamic> map) {
    return TransactionModel(
      id: map['id'] as String,
      userId: (map['user_id'] as String?) ?? 'default',
      amount: (map['amount'] as num).toDouble(),
      type: (map['type'] as String?) ?? 'expense',
      categoryId: map['category_id'] as String?,
      category: map['category'] as String?,
      date: (map['date'] as String?) ?? DateTime.now().toIso8601String(),
      notes: map['notes'] as String?,
      source: map['source'] as String?,
      relatedEntityId: map['related_entity_id'] as String?,
      vehicleId: map['vehicle_id'] as String?,
      isVehicleExpense: ((map['is_vehicle_expense'] as int?) ?? 0) == 1,
      fuelLogId: map['fuel_log_id'] as String?,
      sourceType: map['source_type'] as String?,
      sourceId: map['source_id'] as String?,
      location: map['location'] as String?,
      tags: map['tags'] as String?,
      isDeleted: ((map['is_deleted'] as int?) ?? 0) == 1,
      createdAt: (map['created_at'] as String?) ?? DateTime.now().toIso8601String(),
      updatedAt: (map['updated_at'] as String?) ?? DateTime.now().toIso8601String(),
    );
  }

  /// Alias for fromMap — keeps compatibility with code using fromJson.
  factory TransactionModel.fromJson(Map<String, dynamic> json) =>
      TransactionModel.fromMap(json);

  /// Convert to SQLite row map.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'amount': amount,
      'type': type,
      'category_id': categoryId,
      'category': category,
      'date': date,
      'notes': notes,
      'source': source,
      'related_entity_id': relatedEntityId,
      'vehicle_id': vehicleId,
      'is_vehicle_expense': isVehicleExpense ? 1 : 0,
      'fuel_log_id': fuelLogId,
      'source_type': sourceType,
      'source_id': sourceId,
      'location': location,
      'tags': tags,
      'is_deleted': isDeleted ? 1 : 0,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  /// Alias for toMap — keeps compatibility with code using toJson.
  Map<String, dynamic> toJson() => toMap();

  TransactionModel copyWith({
    String? id,
    String? userId,
    double? amount,
    String? type,
    String? categoryId,
    String? category,
    String? date,
    String? notes,
    String? source,
    String? relatedEntityId,
    String? vehicleId,
    bool? isVehicleExpense,
    String? fuelLogId,
    String? sourceType,
    String? sourceId,
    String? location,
    String? tags,
    bool? isDeleted,
    String? createdAt,
    String? updatedAt,
  }) {
    return TransactionModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      categoryId: categoryId ?? this.categoryId,
      category: category ?? this.category,
      date: date ?? this.date,
      notes: notes ?? this.notes,
      source: source ?? this.source,
      relatedEntityId: relatedEntityId ?? this.relatedEntityId,
      vehicleId: vehicleId ?? this.vehicleId,
      isVehicleExpense: isVehicleExpense ?? this.isVehicleExpense,
      fuelLogId: fuelLogId ?? this.fuelLogId,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      location: location ?? this.location,
      tags: tags ?? this.tags,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'TransactionModel(id: $id, type: $type, amount: $amount, date: $date)';
}