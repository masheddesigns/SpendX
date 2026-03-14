import 'package:uuid/uuid.dart';

/// Represents a lending or borrowing record
class Lending {
  final String id;
  final String userId;
  final String personName;
  final String type; // 'lent' | 'borrowed'
  final double originalAmount;
  final double paidAmount; // how much has been settled
  final DateTime date;
  final DateTime? dueDate;
  final String? notes;
  final bool isSettled;
  final DateTime createdAt;
  final DateTime updatedAt;

  Lending({
    String? id,
    this.userId = 'offline_user',
    required this.personName,
    required this.type,
    required this.originalAmount,
    this.paidAmount = 0.0,
    DateTime? date,
    this.dueDate,
    this.notes,
    this.isSettled = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        date = date ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  double get remainingAmount => originalAmount - paidAmount;
  bool get isOverdue => dueDate != null && !isSettled && dueDate!.isBefore(DateTime.now());

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'person_name': personName,
        'type': type,
        'original_amount': originalAmount,
        'paid_amount': paidAmount,
        'date': date.toIso8601String(),
        'due_date': dueDate?.toIso8601String(),
        'notes': notes,
        'is_settled': isSettled ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Lending.fromMap(Map<String, dynamic> map) => Lending(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        personName: map['person_name'] as String,
        type: map['type'] as String,
        originalAmount: (map['original_amount'] as num).toDouble(),
        paidAmount: (map['paid_amount'] as num?)?.toDouble() ?? 0.0,
        date: DateTime.parse(map['date'] as String),
        dueDate: map['due_date'] != null ? DateTime.parse(map['due_date'] as String) : null,
        notes: map['notes'] as String?,
        isSettled: (map['is_settled'] as int? ?? 0) == 1,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );

  Lending copyWith({double? paidAmount, bool? isSettled}) => Lending(
        id: id,
        userId: userId,
        personName: personName,
        type: type,
        originalAmount: originalAmount,
        paidAmount: paidAmount ?? this.paidAmount,
        date: date,
        dueDate: dueDate,
        notes: notes,
        isSettled: isSettled ?? this.isSettled,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
}
