import 'package:uuid/uuid.dart';

class Budget {
  final String id;
  final String userId;
  final String categoryId;
  final double limit;
  final String period; // 'monthly' | 'weekly'
  final DateTime createdAt;
  final DateTime updatedAt;

  Budget({
    String? id,
    this.userId = 'offline_user',
    required this.categoryId,
    required this.limit,
    this.period = 'monthly',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// Maps to actual DB columns: id, category_id, limit_amount, period, created_at
  Map<String, dynamic> toMap() => {
    'id': id,
    'category_id': categoryId,
    'limit_amount': limit,
    'period': period,
    'created_at': createdAt.toIso8601String(),
  };

  factory Budget.fromMap(Map<String, dynamic> map) => Budget(
    id: map['id'] as String,
    userId: map['user_id'] as String? ?? 'offline_user',
    categoryId: map['category_id'] as String,
    limit: (map['limit_amount'] as num).toDouble(),
    period: map['period'] as String? ?? 'monthly',
    createdAt: map['created_at'] != null
        ? DateTime.parse(map['created_at'] as String)
        : DateTime.now(),
    updatedAt: map['updated_at'] != null
        ? DateTime.parse(map['updated_at'] as String)
        : (map['created_at'] != null
              ? DateTime.parse(map['created_at'] as String)
              : DateTime.now()),
  );

  Budget copyWith({
    String? id,
    String? userId,
    String? categoryId,
    double? limit,
    String? period,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Budget(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      categoryId: categoryId ?? this.categoryId,
      limit: limit ?? this.limit,
      period: period ?? this.period,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}
