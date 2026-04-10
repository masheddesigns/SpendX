class EMIInstallment {
  final String id;
  final String emiId;
  final DateTime dueDate;
  final double amount;
  final double principal;
  final double interest;
  final String status; // pending, paid

  EMIInstallment({
    required this.id,
    required this.emiId,
    required this.dueDate,
    required this.amount,
    this.principal = 0,
    this.interest = 0,
    required this.status,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'emiId': emiId,
      'dueDate': dueDate.toIso8601String(),
      'amount': amount,
      'principal': principal,
      'interest': interest,
      'status': status,
    };
  }

  factory EMIInstallment.fromMap(Map<String, dynamic> map) {
    return EMIInstallment(
      id: map['id'],
      emiId: map['emiId'],
      dueDate: DateTime.parse(map['dueDate']),
      amount: (map['amount'] as num).toDouble(),
      principal: (map['principal'] as num?)?.toDouble() ?? 0,
      interest: (map['interest'] as num?)?.toDouble() ?? 0,
      status: map['status'],
    );
  }

  EMIInstallment copyWith({
    String? id,
    String? emiId,
    DateTime? dueDate,
    double? amount,
    double? principal,
    double? interest,
    String? status,
  }) {
    return EMIInstallment(
      id: id ?? this.id,
      emiId: emiId ?? this.emiId,
      dueDate: dueDate ?? this.dueDate,
      amount: amount ?? this.amount,
      principal: principal ?? this.principal,
      interest: interest ?? this.interest,
      status: status ?? this.status,
    );
  }
}
