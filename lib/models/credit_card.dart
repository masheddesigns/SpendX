import 'package:uuid/uuid.dart';

/// Represents a credit card tracked in SpendX
class CreditCard {
  final String id;
  final String userId;
  final String name; // e.g. "HDFC Regalia"
  final String bank; // e.g. "HDFC"
  final String last4; // Last 4 digits
  final double limitAmount;
  final int billingDay; // Day of month billing cycle resets
  final int dueDay; // Day of month payment is due
  final String cardType; // 'visa' | 'mastercard' | 'rupay' | 'amex'
  final String color; // Hex color for card gradient
  final double usedAmount; // Current outstanding amount
  final double lastStatementBalance; // Last generated bill amount
  final DateTime createdAt;

  CreditCard({
    String? id,
    this.userId = 'offline_user',
    required this.name,
    required this.bank,
    this.last4 = '0000',
    required this.limitAmount,
    this.billingDay = 1,
    this.dueDay = 20,
    this.cardType = 'visa',
    this.color = '#6366F1',
    this.usedAmount = 0,
    this.lastStatementBalance = 0,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  double get availableLimit =>
      (limitAmount - usedAmount).clamp(0, double.infinity);
  double get utilizationPct =>
      limitAmount > 0 ? (usedAmount / limitAmount * 100).clamp(0, 100) : 0;
  double get creditLimit => limitAmount;
  double get outstanding => usedAmount;

  /// Next billing date from today
  DateTime get nextBillingDate {
    final now = DateTime.now();
    var d = DateTime(now.year, now.month, billingDay);
    if (d.isBefore(now) || d.isAtSameMomentAs(now)) {
      d = DateTime(now.year, now.month + 1, billingDay);
    }
    return d;
  }

  /// Next due date from today
  DateTime get nextDueDate {
    final now = DateTime.now();
    var d = DateTime(now.year, now.month, dueDay);
    if (d.isBefore(now) || d.isAtSameMomentAs(now)) {
      d = DateTime(now.year, now.month + 1, dueDay);
    }
    return d;
  }

  int get daysUntilDue => nextDueDate.difference(DateTime.now()).inDays;

  Map<String, dynamic> toMap() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'bank': bank,
    'last4': last4,
    'limit_amount': limitAmount,
    'billing_day': billingDay,
    'due_day': dueDay,
    'card_type': cardType,
    'color': color,
    'used_amount': usedAmount,
    'last_statement_balance': lastStatementBalance,
    'created_at': createdAt.toIso8601String(),
  };

  factory CreditCard.fromMap(Map<String, dynamic> map) => CreditCard(
    id: map['id'] as String,
    userId: map['user_id'] as String? ?? 'offline_user',
    name: map['name'] as String,
    bank: map['bank'] as String? ?? '',
    last4: map['last4'] as String? ?? '0000',
    limitAmount: (map['limit_amount'] as num?)?.toDouble() ?? 0.0,
    billingDay: (map['billing_day'] as int?) ?? 1,
    dueDay: (map['due_day'] as int?) ?? 20,
    cardType: map['card_type'] as String? ?? 'visa',
    color: map['color'] as String? ?? '#6366F1',
    usedAmount: (map['used_amount'] as num?)?.toDouble() ?? 0.0,
    lastStatementBalance:
        (map['last_statement_balance'] as num?)?.toDouble() ?? 0.0,
    createdAt: map['created_at'] != null
        ? DateTime.parse(map['created_at'] as String)
        : DateTime.now(),
  );

  CreditCard copyWith({
    String? id,
    double? usedAmount,
    double? outstanding,
    double? lastStatementBalance,
    String? name,
    String? bank,
    String? last4,
    double? limitAmount,
    double? creditLimit,
    int? billingDay,
    int? dueDay,
    String? cardType,
    String? color,
  }) => CreditCard(
    id: id ?? this.id,
    userId: userId,
    name: name ?? this.name,
    bank: bank ?? this.bank,
    last4: last4 ?? this.last4,
    limitAmount: limitAmount ?? creditLimit ?? this.limitAmount,
    billingDay: billingDay ?? this.billingDay,
    dueDay: dueDay ?? this.dueDay,
    cardType: cardType ?? this.cardType,
    color: color ?? this.color,
    usedAmount: usedAmount ?? outstanding ?? this.usedAmount,
    lastStatementBalance: lastStatementBalance ?? this.lastStatementBalance,
    createdAt: createdAt,
  );
}
