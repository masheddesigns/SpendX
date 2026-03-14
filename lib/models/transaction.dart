import 'dart:convert';
import 'package:uuid/uuid.dart';

class Transaction {
  final String id;
  final String userId;
  final String type; // 'income', 'expense', 'transfer'
  final String? categoryId; // Allow nullable for transfers
  final double amount;
  final DateTime date;
  final String notes;
  final List<String> tags; // Stored as JSON string in DB
  final String source; // 'manual', 'vehicle', 'lending', 'credit_card', 'ai_import'
  final String? relatedEntityId;
  final String? vehicleId;
  final String? location;
  final DateTime createdAt;
  final DateTime updatedAt;

  Transaction({
    String? id,
    required this.userId,
    required this.type,
    this.categoryId,
    required this.amount,
    required this.date,
    this.notes = '',
    this.tags = const [],
    this.source = 'manual',
    this.relatedEntityId,
    this.vehicleId,
    this.location,
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
      'amount': amount,
      'date': date.toIso8601String(),
      'notes': notes,
      'tags': jsonEncode(tags), // Serialize tags to string
      'source': source,
      'related_entity_id': relatedEntityId,
      'vehicle_id': vehicleId,
      'location': location,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Transaction.fromMap(Map<String, dynamic> map) {
    return Transaction(
      id: map['id'],
      userId: map['user_id'] ?? '',
      type: map['type'],
      categoryId: map['category_id'],
      amount: (map['amount'] as num).toDouble(),
      date: DateTime.parse(map['date']),
      notes: map['notes'] ?? '',
      tags: map['tags'] != null ? List<String>.from(jsonDecode(map['tags'])) : [],
      source: map['source'] ?? 'manual',
      relatedEntityId: map['related_entity_id'],
      vehicleId: map['vehicle_id'],
      location: map['location'],
      createdAt: map['created_at'] != null ? DateTime.parse(map['created_at']) : DateTime.now(),
      updatedAt: map['updated_at'] != null ? DateTime.parse(map['updated_at']) : DateTime.now(),
    );
  }

  // Required for backward compatibility with SharedPreferences before migration
  Map<String, dynamic> toJson() => toMap();
  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction.fromMap(json);
}
