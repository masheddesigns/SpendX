class LoanInstallment {
  final String id;
  final String loanId;
  final DateTime dueDate;
  final double amount;
  final double principalComponent;
  final double interestComponent;
  final String status; // pending, paid
  final DateTime? paidDate;

  LoanInstallment({
    required this.id,
    required this.loanId,
    required this.dueDate,
    required this.amount,
    required this.principalComponent,
    required this.interestComponent,
    required this.status,
    this.paidDate,
  });

  LoanInstallment copyWith({
    String? id,
    String? loanId,
    DateTime? dueDate,
    double? amount,
    double? principalComponent,
    double? interestComponent,
    String? status,
    DateTime? paidDate,
  }) {
    return LoanInstallment(
      id: id ?? this.id,
      loanId: loanId ?? this.loanId,
      dueDate: dueDate ?? this.dueDate,
      amount: amount ?? this.amount,
      principalComponent: principalComponent ?? this.principalComponent,
      interestComponent: interestComponent ?? this.interestComponent,
      status: status ?? this.status,
      paidDate: paidDate ?? this.paidDate,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'loanId': loanId,
      'dueDate': dueDate.toIso8601String(),
      'amount': amount,
      'principalComponent': principalComponent,
      'interestComponent': interestComponent,
      'status': status,
      'paidDate': paidDate?.toIso8601String(),
    };
  }

  factory LoanInstallment.fromMap(Map<String, dynamic> map) {
    return LoanInstallment(
      id: map['id'],
      loanId: map['loanId'],
      dueDate: DateTime.parse(map['dueDate']),
      amount: (map['amount'] as num).toDouble(),
      principalComponent: (map['principalComponent'] as num).toDouble(),
      interestComponent: (map['interestComponent'] as num).toDouble(),
      status: map['status'],
      paidDate: map['paidDate'] != null ? DateTime.parse(map['paidDate']) : null,
    );
  }
}
