// ignore_for_file: constant_identifier_names
enum LedgerType {
  expense,
  income,
  credit_purchase,
  credit_payment,
  emi_installment,
  loan_disbursement,
  loan_payment,
  transfer,
  lending_given,
  lending_received,
  fuel_expense,
  processing_fee,
  interest_charge,
  refund,
}


class LedgerTransaction {
  final int? id;
  final LedgerType type;
  final double amount;
  final DateTime date;

  final String? accountId;
  final String? creditCardId;
  final String? loanId;
  final String? categoryId;

  final String? note;
  final String? referenceId;

  const LedgerTransaction({
    this.id,
    required this.type,
    required this.amount,
    required this.date,
    this.accountId,
    this.creditCardId,
    this.loanId,
    this.categoryId,
    this.note,
    this.referenceId,
  });

  /// Maps to actual DB columns: id, type, amount, date, note,
  /// account_id, credit_card_id, loan_id, reference_id, created_at
  /// (no user_id, no category_id in table)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'amount': amount,
      'date': date.toIso8601String(),
      'account_id': accountId,
      'credit_card_id': creditCardId,
      'loan_id': loanId,
      'note': note,
      'reference_id': referenceId,
      'created_at': DateTime.now().toIso8601String(),
    };
  }

  factory LedgerTransaction.fromMap(Map<String, dynamic> map) {
    return LedgerTransaction(
      id: map['id'] as int?,
      type: LedgerType.values.firstWhere((e) => e.name == map['type']),
      amount: (map['amount'] as num).toDouble(),
      date: DateTime.parse(map['date'] as String),
      accountId: map['account_id'] as String?,
      creditCardId: map['credit_card_id'] as String?,
      loanId: map['loan_id'] as String?,
      categoryId: map['category_id'] as String?,
      note: map['note'] as String?,
      referenceId: map['reference_id'] as String?,
    );
  }

}
