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
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'category_id': categoryId,
        'limit_amount': limit,
        'period': period,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Budget.fromMap(Map<String, dynamic> map) => Budget(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        categoryId: map['category_id'] as String,
        limit: (map['limit_amount'] as num).toDouble(),
        period: map['period'] as String? ?? 'monthly',
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );
}
