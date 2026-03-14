import 'dart:math';
import 'package:uuid/uuid.dart';

/// Represents an EMI (equated monthly instalment) plan
class EmiPlan {
  final String id;
  final String userId;
  final String? cardId;        // null = cash/bank EMI
  final String name;           // e.g. "iPhone 16 EMI"
  final double principal;      // Purchase amount
  final double interestRate;   // Annual % rate (0 for zero-cost EMI)
  final int tenureMonths;      // Number of months
  final double emiAmount;      // Calculated monthly instalment
  final DateTime startDate;    // Date of first instalment
  final String? categoryId;
  final String? notes;
  final bool isActive;
  final int paidInstalments;
  final DateTime createdAt;

  EmiPlan({
    String? id,
    this.userId = 'offline_user',
    this.cardId,
    required this.name,
    required this.principal,
    required this.interestRate,
    required this.tenureMonths,
    double? emiAmount,
    DateTime? startDate,
    this.categoryId,
    this.notes,
    this.isActive = true,
    this.paidInstalments = 0,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        emiAmount = emiAmount ?? calculateEmiAmount(principal, interestRate, tenureMonths),
        startDate = startDate ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  /// Standard EMI formula: P × r × (1+r)^n / ((1+r)^n - 1)
  static double calculateEmiAmount(double principal, double annualRate, int months) {
    if (annualRate == 0) return principal / months;
    final r = annualRate / 12 / 100;
    final pow = (1 + r).toDouble();
    final numerator = principal * r * pow.toPrecision(months);
    final denominator = pow.toPrecision(months) - 1;
    return numerator / denominator;
  }

  double get totalPayable => emiAmount * tenureMonths;
  double get totalInterest => totalPayable - principal;

  /// Returns number of instalments currently paid by user
  int get currentInstalment {
    return min(paidInstalments, tenureMonths);
  }

  int get remainingInstalments => tenureMonths - currentInstalment;

  /// Returns true if there is an installment due or upcoming within 15 days
  bool get isDue {
    if (remainingInstalments == 0 || !isActive) return false;
    final nextToPay = amortizationSchedule.firstWhere((e) => !e.isPaid);
    final now = DateTime.now();
    final windowStart = nextToPay.dueDate.subtract(const Duration(days: 15));
    return now.isAfter(windowStart);
  }

  /// Generate amortization schedule
  List<AmortizationEntry> get amortizationSchedule {
    final entries = <AmortizationEntry>[];
    double balance = principal;
    final r = interestRate / 12 / 100;

    for (int i = 0; i < tenureMonths; i++) {
      final interestForMonth = balance * r;
      final principalForMonth = interestRate == 0
          ? principal / tenureMonths
          : emiAmount - interestForMonth;
      balance = (balance - principalForMonth).clamp(0, double.infinity);

      final dueDate = DateTime(startDate.year, startDate.month + i, startDate.day);
      entries.add(AmortizationEntry(
        month: i + 1,
        dueDate: dueDate,
        emiAmount: emiAmount,
        principal: principalForMonth,
        interest: interestForMonth,
        balance: balance,
        isPaid: i < paidInstalments,
      ));
    }
    return entries;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'card_id': cardId,
        'name': name,
        'principal': principal,
        'interest_rate': interestRate,
        'tenure_months': tenureMonths,
        'emi_amount': emiAmount,
        'start_date': startDate.toIso8601String(),
        'category_id': categoryId,
        'notes': notes,
        'is_active': isActive ? 1 : 0,
        'paid_instalments': paidInstalments,
        'created_at': createdAt.toIso8601String(),
      };

  factory EmiPlan.fromMap(Map<String, dynamic> map) => EmiPlan(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        cardId: map['card_id'] as String?,
        name: map['name'] as String,
        principal: (map['principal'] as num).toDouble(),
        interestRate: (map['interest_rate'] as num).toDouble(),
        tenureMonths: map['tenure_months'] as int,
        emiAmount: (map['emi_amount'] as num).toDouble(),
        startDate: DateTime.parse(map['start_date'] as String),
        categoryId: map['category_id'] as String?,
        notes: map['notes'] as String?,
        isActive: (map['is_active'] as int? ?? 1) == 1,
        paidInstalments: map['paid_instalments'] as int? ?? 0,
        createdAt: DateTime.parse(map['created_at'] as String),
      );

  EmiPlan copyWith({
    String? id,
    String? userId,
    String? cardId,
    String? name,
    double? principal,
    double? interestRate,
    int? tenureMonths,
    double? emiAmount,
    DateTime? startDate,
    String? categoryId,
    String? notes,
    bool? isActive,
    int? paidInstalments,
    DateTime? createdAt,
  }) {
    return EmiPlan(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      cardId: cardId ?? this.cardId,
      name: name ?? this.name,
      principal: principal ?? this.principal,
      interestRate: interestRate ?? this.interestRate,
      tenureMonths: tenureMonths ?? this.tenureMonths,
      emiAmount: emiAmount ?? this.emiAmount,
      startDate: startDate ?? this.startDate,
      categoryId: categoryId ?? this.categoryId,
      notes: notes ?? this.notes,
      isActive: isActive ?? this.isActive,
      paidInstalments: paidInstalments ?? this.paidInstalments,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

extension on double {
  double toPrecision(int n) => pow(this, n).toDouble();
}

class AmortizationEntry {
  final int month;
  final DateTime dueDate;
  final double emiAmount;
  final double principal;
  final double interest;
  final double balance;
  final bool isPaid;

  AmortizationEntry({
    required this.month,
    required this.dueDate,
    required this.emiAmount,
    required this.principal,
    required this.interest,
    required this.balance,
    required this.isPaid,
  });
}
