import 'package:uuid/uuid.dart';

/// Goal types determine how progress is measured.
enum GoalType {
  savings,       // Track total savings towards target
  spendingLimit, // Track spending under limit (per month)
  debtPayoff,    // Track debt reduction
}

class Goal {
  final String id;
  final String title;
  final GoalType type;
  final double targetAmount;
  final double currentAmount;
  final DateTime startDate;
  final DateTime endDate;
  final String? categoryId; // For spending_limit goals
  final String? accountId;  // For savings/debt goals
  final bool isActive;
  final DateTime createdAt;

  Goal({
    String? id,
    required this.title,
    required this.type,
    required this.targetAmount,
    this.currentAmount = 0,
    required this.startDate,
    required this.endDate,
    this.categoryId,
    this.accountId,
    this.isActive = true,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'type': type.name,
    'target_amount': targetAmount,
    'current_amount': currentAmount,
    'start_date': startDate.toIso8601String(),
    'end_date': endDate.toIso8601String(),
    'category_id': categoryId,
    'account_id': accountId,
    'is_active': isActive ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory Goal.fromMap(Map<String, dynamic> map) => Goal(
    id: map['id'] as String,
    title: map['title'] as String,
    type: GoalType.values.firstWhere(
      (e) => e.name == (map['type'] as String? ?? 'savings'),
      orElse: () => GoalType.savings,
    ),
    targetAmount: (map['target_amount'] as num).toDouble(),
    currentAmount: (map['current_amount'] as num?)?.toDouble() ?? 0,
    startDate: DateTime.parse(map['start_date'] as String),
    endDate: DateTime.parse(map['end_date'] as String),
    categoryId: map['category_id'] as String?,
    accountId: map['account_id'] as String?,
    isActive: (map['is_active'] as int?) == 1,
    createdAt: map['created_at'] != null
        ? DateTime.parse(map['created_at'] as String)
        : DateTime.now(),
  );

  Goal copyWith({
    String? title,
    GoalType? type,
    double? targetAmount,
    double? currentAmount,
    DateTime? startDate,
    DateTime? endDate,
    String? categoryId,
    String? accountId,
    bool? isActive,
  }) => Goal(
    id: id,
    title: title ?? this.title,
    type: type ?? this.type,
    targetAmount: targetAmount ?? this.targetAmount,
    currentAmount: currentAmount ?? this.currentAmount,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    categoryId: categoryId ?? this.categoryId,
    accountId: accountId ?? this.accountId,
    isActive: isActive ?? this.isActive,
    createdAt: createdAt,
  );
}
