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

  /// Maps to the actual DB table columns (recurring_templates).
  /// Table has: id, name, amount, type, category_id, frequency,
  ///   interval, day_of_month, day_of_week, last_generated,
  ///   next_generation, is_active, created_at
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'amount': amount,
        'type': type,
        'category_id': categoryId,
        'frequency': frequency,
        'interval': 1,
        'last_generated': lastGeneratedDate?.toIso8601String(),
        'next_generation': startDate.toIso8601String(),
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory RecurringTemplate.fromMap(Map<String, dynamic> map) =>
      RecurringTemplate(
        id: map['id'] as String,
        userId: map['user_id'] as String? ?? 'offline_user',
        name: map['name'] as String,
        amount: (map['amount'] as num).toDouble(),
        type: map['type'] as String? ?? 'expense',
        categoryId: map['category_id'] as String?,
        frequency: map['frequency'] as String? ?? 'monthly',
        startDate: map['start_date'] != null
            ? DateTime.parse(map['start_date'] as String)
            : (map['next_generation'] != null
                  ? DateTime.parse(map['next_generation'] as String)
                  : DateTime.now()),
        endDate: map['end_date'] != null
            ? DateTime.parse(map['end_date'] as String)
            : null,
        lastGeneratedDate: map['last_generated_date'] != null
            ? DateTime.parse(map['last_generated_date'] as String)
            : (map['last_generated'] != null
                  ? DateTime.parse(map['last_generated'] as String)
                  : null),
        isActive: (map['is_active'] as int? ?? 1) == 1,
        notes: map['notes'] as String?,
        createdAt: map['created_at'] != null
            ? DateTime.parse(map['created_at'] as String)
            : DateTime.now(),
        updatedAt: map['updated_at'] != null
            ? DateTime.parse(map['updated_at'] as String)
            : (map['created_at'] != null
                  ? DateTime.parse(map['created_at'] as String)
                  : DateTime.now()),
      );

  RecurringTemplate copyWith({
    String? id,
    String? userId,
    String? name,
    double? amount,
    String? type,
    String? categoryId,
    String? frequency,
    DateTime? startDate,
    DateTime? endDate,
    DateTime? lastGeneratedDate,
    bool? isActive,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => RecurringTemplate(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        name: name ?? this.name,
        amount: amount ?? this.amount,
        type: type ?? this.type,
        categoryId: categoryId ?? this.categoryId,
        frequency: frequency ?? this.frequency,
        startDate: startDate ?? this.startDate,
        endDate: endDate ?? this.endDate,
        lastGeneratedDate: lastGeneratedDate ?? this.lastGeneratedDate,
        isActive: isActive ?? this.isActive,
        notes: notes ?? this.notes,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );
}
