import 'dart:convert';
import 'package:uuid/uuid.dart';

class Transaction {
  final String id;
  final String userId;
  final String type; // 'income', 'expense', 'transfer'
  final String? categoryId; // Allow nullable for transfers
  final String? accountId;
  final double amount;
  final DateTime date;
  final String notes;
  final List<String> tags; // Stored as JSON string in DB
  final String source; // 'manual', 'vehicle', 'lending', 'credit_card', 'ai_import'
  final String? relatedEntityId;
  final String? externalRef;
  final String? vehicleId;
  final bool isVehicleExpense;
  final String? fuelLogId;
  final String? location;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  Transaction({
    String? id,
    required this.userId,
    required this.type,
    this.categoryId,
    this.accountId,
    required this.amount,
    required this.date,
    this.notes = '',
    this.tags = const [],
    this.source = 'manual',
    this.relatedEntityId,
    this.externalRef,
    this.vehicleId,
    this.isVehicleExpense = false,
    this.fuelLogId,
    this.location,
    this.isDeleted = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'type': type,
      'category_id': categoryId,
      'account_id': accountId,
      'amount': amount,
      'date': date.toIso8601String(),
      'notes': notes,
      'tags': jsonEncode(tags), // Serialize tags to string
      'source': source,
      'related_entity_id': relatedEntityId,
      'external_ref': externalRef,
      'vehicle_id': vehicleId,
      'is_vehicle_expense': isVehicleExpense ? 1 : 0,
      'fuel_log_id': fuelLogId,
      'location': location,
      'is_deleted': isDeleted ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Transaction.fromMap(Map<String, dynamic> map) {
    return Transaction(
      id: map['id'] as String,
      userId: map['user_id'] as String? ?? 'offline_user',
      type: map['type'] as String,
      categoryId: map['category_id'] as String?,
      accountId: map['account_id'] as String? ?? map['related_entity_id'] as String?,
      amount: (map['amount'] as num).toDouble(),
      date: DateTime.parse(map['date'] as String),
      notes: map['notes'] as String? ?? map['note'] as String? ?? '',
      tags: _parseTags(map['tags']),
      source: map['source'] as String? ?? 'manual',
      relatedEntityId: map['related_entity_id'] as String?,
      externalRef: map['external_ref'] as String?,
      vehicleId: map['vehicle_id'] as String?,
      isVehicleExpense: (map['is_vehicle_expense'] as int? ?? 0) == 1,
      fuelLogId: map['fuel_log_id'] as String?,
      location: map['location'] as String?,
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
      createdAt: map['created_at'] != null ? DateTime.parse(map['created_at'] as String) : DateTime.now(),
      updatedAt: map['updated_at'] != null ? DateTime.parse(map['updated_at'] as String) : DateTime.now(),
    );
  }


  /// Safely parse tags JSON — prevents crash on corrupted data.
  static List<String> _parseTags(dynamic raw) {
    if (raw == null) return const [];
    try {
      return List<String>.from(jsonDecode(raw as String));
    } catch (_) {
      return const [];
    }
  }

  // Required for backward compatibility with SharedPreferences before migration
  Map<String, dynamic> toJson() => toMap();
  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction.fromMap(json);

  Transaction copyWith({
    String? id,
    String? userId,
    String? type,
    String? categoryId,
    String? accountId,
    double? amount,
    DateTime? date,
    String? notes,
    List<String>? tags,
    String? source,
    String? relatedEntityId,
    String? externalRef,
    String? vehicleId,
    bool? isVehicleExpense,
    String? fuelLogId,
    String? location,
    bool? isDeleted,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Transaction(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      type: type ?? this.type,
      categoryId: categoryId ?? this.categoryId,
      accountId: accountId ?? this.accountId,
      amount: amount ?? this.amount,
      date: date ?? this.date,
      notes: notes ?? this.notes,
      tags: tags ?? this.tags,
      source: source ?? this.source,
      relatedEntityId: relatedEntityId ?? this.relatedEntityId,
      externalRef: externalRef ?? this.externalRef,
      vehicleId: vehicleId ?? this.vehicleId,
      isVehicleExpense: isVehicleExpense ?? this.isVehicleExpense,
      fuelLogId: fuelLogId ?? this.fuelLogId,
      location: location ?? this.location,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
