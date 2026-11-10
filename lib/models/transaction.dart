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
  final String source; // 'manual', 'lending', 'credit_card', 'ai_import'
  final String? relatedEntityId;
  final String? externalRef;
  final String? location;
  final bool isDeleted;
  final String? rawPayload;
  final double? interestAmount;
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
    this.location,
    this.isDeleted = false,
    this.rawPayload,
    this.interestAmount,
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
      location: map['location'] as String?,
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
      rawPayload: map['raw_payload'] as String?,
      interestAmount: (map['interest_amount'] as num?)?.toDouble(),
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

  /// Whether this transaction represents an outflow (spent).
  bool get isExpenseType =>
      type == 'expense' ||
      type == 'credit_card_purchase' ||
      type == 'credit_purchase' ||
      type == 'loan_payment';

  /// Whether this transaction represents an inflow (received).
  bool get isIncomeType =>
      type == 'income' ||
      type == 'refund' ||
      type == 'loan_disbursement';

  /// Whether this transaction represents a movement between accounts.
  bool get isTransferType =>
      type == 'transfer' ||
      type == 'credit_payment' ||
      type == 'loan_repayment';

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
    String? location,
    bool? isDeleted,
    String? rawPayload,
    double? interestAmount,
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
      location: location ?? this.location,
      isDeleted: isDeleted ?? this.isDeleted,
      rawPayload: rawPayload ?? this.rawPayload,
      interestAmount: interestAmount ?? this.interestAmount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
