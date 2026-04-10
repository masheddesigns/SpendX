enum LoanType { reducing, flat, interestOnly }

class Loan {
  final String id;
  final String name;
  final String bank;
  final double total;
  final double interestRate;
  final int tenureMonths;
  final double monthlyInstallment;
  final DateTime startDate;
  final double paidAmount;
  final String loanStatus; // active, closed, defaulted
  final DateTime? nextDueDate;
  final String? categoryId;
  final int dueDay;
  final LoanType type;

  double get principalAmount => total;

  Loan({
    required this.id,
    required this.name,
    required this.bank,
    required this.total,
    required this.interestRate,
    required this.tenureMonths,
    required this.monthlyInstallment,
    required this.startDate,
    required this.paidAmount,
    required this.loanStatus,
    this.nextDueDate,
    this.categoryId,
    required this.dueDay,
    this.type = LoanType.reducing,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'bank': bank,
      'total': total,
      'interest_rate': interestRate,
      'tenure_months': tenureMonths,
      'monthly_installment': monthlyInstallment,
      'start_date': startDate.toIso8601String(),
      'paid_amount': paidAmount,
      'loan_status': loanStatus,
      'next_due_date': nextDueDate?.toIso8601String(),
      'category_id': categoryId,
      'due_day': dueDay,
      'loan_type': type.name,
    };
  }

  factory Loan.fromMap(Map<String, dynamic> map) {
    return Loan(
      id: map['id'] as String,
      name: map['name'] as String,
      bank: map['bank'] as String? ?? '',
      total: (map['total'] as num?)?.toDouble() ?? 0.0,
      interestRate: (map['interest_rate'] as num?)?.toDouble() ?? 0.0,
      tenureMonths: (map['tenure_months'] as int?) ?? 0,
      monthlyInstallment:
          (map['monthly_installment'] as num?)?.toDouble() ?? 0.0,
      startDate: map['start_date'] != null
          ? DateTime.parse(map['start_date'] as String)
          : DateTime.now(),
      paidAmount: (map['paid_amount'] as num?)?.toDouble() ?? 0.0,
      loanStatus: map['loan_status'] as String? ?? 'active',
      nextDueDate: map['next_due_date'] != null
          ? DateTime.parse(map['next_due_date'] as String)
          : null,
      categoryId: map['category_id'] as String?,
      dueDay: (map['due_day'] as int?) ?? 1,
      type: LoanType.values.firstWhere(
        (e) => e.name == (map['loan_type'] ?? 'reducing'),
        orElse: () => LoanType.reducing,
      ),
    );
  }

  Loan copyWith({
    String? id,
    String? name,
    String? bank,
    double? total,
    double? interestRate,
    int? tenureMonths,
    double? monthlyInstallment,
    DateTime? startDate,
    double? paidAmount,
    String? loanStatus,
    DateTime? nextDueDate,
    String? categoryId,
    int? dueDay,
    LoanType? type,
  }) {
    return Loan(
      id: id ?? this.id,
      name: name ?? this.name,
      bank: bank ?? this.bank,
      total: total ?? this.total,
      interestRate: interestRate ?? this.interestRate,
      tenureMonths: tenureMonths ?? this.tenureMonths,
      monthlyInstallment: monthlyInstallment ?? this.monthlyInstallment,
      startDate: startDate ?? this.startDate,
      paidAmount: paidAmount ?? this.paidAmount,
      loanStatus: loanStatus ?? this.loanStatus,
      nextDueDate: nextDueDate ?? this.nextDueDate,
      categoryId: categoryId ?? this.categoryId,
      dueDay: dueDay ?? this.dueDay,
      type: type ?? this.type,
    );
  }
}
