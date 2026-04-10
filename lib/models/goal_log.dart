import 'package:uuid/uuid.dart';

class GoalLog {
  final String id;
  final String goalId;
  final double amount;
  final String? note;
  final DateTime createdAt;

  GoalLog({
    String? id,
    required this.goalId,
    required this.amount,
    this.note,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'goal_id': goalId,
    'amount': amount,
    'note': note,
    'created_at': createdAt.toIso8601String(),
  };

  factory GoalLog.fromMap(Map<String, dynamic> map) => GoalLog(
    id: map['id'] as String,
    goalId: map['goal_id'] as String,
    amount: (map['amount'] as num).toDouble(),
    note: map['note'] as String?,
    createdAt: DateTime.parse(map['created_at'] as String),
  );
}
