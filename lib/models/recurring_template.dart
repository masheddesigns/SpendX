import 'package:uuid/uuid.dart';

/// Represents a recurring payment template that auto-generates transactions.
class RecurringTemplate {
  final String id;
  final String userId;
  final String name;
  final double amount;
  final String type; // 'income' | 'expense'
  final String? categoryId;
  final String frequency; // 'daily' | 'weekly' | 'monthly' | 'yearly'
  final DateTime startDate;
  final DateTime? endDate;
  final DateTime? lastGeneratedDate;
  final bool isActive;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  RecurringTemplate({
    String? id,
    this.userId = 'offline_user',
    required this.name,
    required this.amount,
    this.type = 'expense',
    this.categoryId,
    this.frequency = 'monthly',
    required this.startDate,
    this.endDate,
    this.lastGeneratedDate,
    this.isActive = true,
    this.notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'name': name,
        'amount': amount,
        'type': type,
        'category_id': categoryId,
        'frequency': frequency,
        'start_date': startDate.toIso8601String(),
        'end_date': endDate?.toIso8601String(),
        'last_generated_date': lastGeneratedDate?.toIso8601String(),
        'is_active': isActive ? 1 : 0,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory RecurringTemplate.fromMap(Map<String, dynamic> map) => RecurringTemplate(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        name: map['name'] as String,
        amount: (map['amount'] as num).toDouble(),
        type: map['type'] as String? ?? 'expense',
        categoryId: map['category_id'] as String?,
        frequency: map['frequency'] as String? ?? 'monthly',
        startDate: DateTime.parse(map['start_date'] as String),
        endDate: map['end_date'] != null ? DateTime.parse(map['end_date'] as String) : null,
        lastGeneratedDate: map['last_generated_date'] != null
            ? DateTime.parse(map['last_generated_date'] as String)
            : null,
        isActive: (map['is_active'] as int? ?? 1) == 1,
        notes: map['notes'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );

  RecurringTemplate copyWith({DateTime? lastGeneratedDate, bool? isActive}) =>
      RecurringTemplate(
        id: id,
        userId: userId,
        name: name,
        amount: amount,
        type: type,
        categoryId: categoryId,
        frequency: frequency,
        startDate: startDate,
        endDate: endDate,
        lastGeneratedDate: lastGeneratedDate ?? this.lastGeneratedDate,
        isActive: isActive ?? this.isActive,
        notes: notes,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
}
