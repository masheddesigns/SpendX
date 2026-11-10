class CreditTransaction {
  final String id;
  final String cardId;
  final double amount;
  final DateTime date;
  final String category;
  final String? note;
  final String type; // purchase, emi_installment, payment, processing_fee, interest_charge, refund
  final String status; // active, converted_to_emi, reversed, pending
  final String? statementId;
  final String? categoryId;
  final String? relatedEntityId;

  CreditTransaction({
    required this.id,
    required this.cardId,
    required this.amount,
    required this.date,
    required this.category,
    this.note,
    required this.type,
    required this.status,
    this.statementId,
    this.categoryId,
    this.relatedEntityId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'cardId': cardId,
      'amount': amount,
      'date': date.toIso8601String(),
      'category': category,
      'note': note,
      'type': type,
      'status': status,
      'statementId': statementId,
      'categoryId': categoryId,
      if (relatedEntityId != null) 'relatedEntityId': relatedEntityId,
    };
  }

  factory CreditTransaction.fromMap(Map<String, dynamic> map) {
    return CreditTransaction(
      id: map['id'],
      cardId: map['cardId'],
      amount: (map['amount'] as num).toDouble(),
      date: DateTime.parse(map['date']),
      category: map['category'],
      note: map['note'],
      type: map['type'],
      status: map['status'] ?? 'active',
      statementId: map['statementId'],
      categoryId: map['categoryId'],
      relatedEntityId: map['relatedEntityId'] ?? map['related_entity_id'],
    );
  }

  CreditTransaction copyWith({
    String? id,
    String? cardId,
    double? amount,
    DateTime? date,
    String? category,
    String? note,
    String? type,
    String? status,
    String? statementId,
    String? categoryId,
    String? relatedEntityId,
  }) {
    return CreditTransaction(
      id: id ?? this.id,
      cardId: cardId ?? this.cardId,
      amount: amount ?? this.amount,
      date: date ?? this.date,
      category: category ?? this.category,
      note: note ?? this.note,
      type: type ?? this.type,
      status: status ?? this.status,
      statementId: statementId ?? this.statementId,
      categoryId: categoryId ?? this.categoryId,
      relatedEntityId: relatedEntityId ?? this.relatedEntityId,
    );
  }
}
