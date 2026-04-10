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
    );
  }
}
