class CreditEMI {
  final String id;
  final String cardId;
  final String transactionId;
  final double principalAmount;
  final double interestRate;
  final double interestAmount;
  final double processingFee;
  final int tenureMonths;
  final double monthlyInstallment;
  final DateTime startDate;
  final int paidMonths;
  final int remainingMonths;
  final DateTime createdAt;
  final String? categoryId;

  CreditEMI({
    required this.id,
    required this.cardId,
    required this.transactionId,
    required this.principalAmount,
    required this.interestRate,
    required this.interestAmount,
    required this.processingFee,
    required this.tenureMonths,
    required this.monthlyInstallment,
    required this.startDate,
    required this.paidMonths,
    required this.remainingMonths,
    required this.createdAt,
    this.categoryId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'cardId': cardId,
      'transactionId': transactionId,
      'principalAmount': principalAmount,
      'interestRate': interestRate,
      'interestAmount': interestAmount,
      'processingFee': processingFee,
      'tenureMonths': tenureMonths,
      'monthlyInstallment': monthlyInstallment,
      'startDate': startDate.toIso8601String(),
      'paidMonths': paidMonths,
      'remainingMonths': remainingMonths,
      'createdAt': createdAt.toIso8601String(),
      'categoryId': categoryId,
    };
  }

  factory CreditEMI.fromMap(Map<String, dynamic> map) {
    return CreditEMI(
      id: map['id'],
      cardId: map['cardId'],
      transactionId: map['transactionId'],
      principalAmount: (map['principalAmount'] as num).toDouble(),
      interestRate: (map['interestRate'] as num).toDouble(),
      interestAmount: (map['interestAmount'] as num).toDouble(),
      processingFee: (map['processingFee'] as num).toDouble(),
      tenureMonths: map['tenureMonths'] as int,
      monthlyInstallment: (map['monthlyInstallment'] as num).toDouble(),
      startDate: DateTime.parse(map['startDate']),
      paidMonths: map['paidMonths'] as int,
      remainingMonths: map['remainingMonths'] as int,
      createdAt: DateTime.parse(map['createdAt']),
      categoryId: map['categoryId'],
    );
  }

  CreditEMI copyWith({
    String? id,
    String? cardId,
    String? transactionId,
    double? principalAmount,
    double? interestRate,
    double? interestAmount,
    double? processingFee,
    int? tenureMonths,
    double? monthlyInstallment,
    DateTime? startDate,
    int? paidMonths,
    int? remainingMonths,
    DateTime? createdAt,
    String? categoryId,
  }) {
    return CreditEMI(
      id: id ?? this.id,
      cardId: cardId ?? this.cardId,
      transactionId: transactionId ?? this.transactionId,
      principalAmount: principalAmount ?? this.principalAmount,
      interestRate: interestRate ?? this.interestRate,
      interestAmount: interestAmount ?? this.interestAmount,
      processingFee: processingFee ?? this.processingFee,
      tenureMonths: tenureMonths ?? this.tenureMonths,
      monthlyInstallment: monthlyInstallment ?? this.monthlyInstallment,
      startDate: startDate ?? this.startDate,
      paidMonths: paidMonths ?? this.paidMonths,
      remainingMonths: remainingMonths ?? this.remainingMonths,
      createdAt: createdAt ?? this.createdAt,
      categoryId: categoryId ?? this.categoryId,
    );
  }

  int get totalMonths => tenureMonths;
  String? get notes => null;
  double get installmentAmount => monthlyInstallment;
}
