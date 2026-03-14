import 'package:uuid/uuid.dart';

/// Represents a credit card tracked in SpendX
class CreditCard {
  final String id;
  final String userId;
  final String name;       // e.g. "HDFC Regalia"
  final String bank;       // e.g. "HDFC"
  final String last4;      // Last 4 digits
  final double creditLimit;
  final int billingDay;    // Day of month billing cycle resets
  final int dueDay;        // Day of month payment is due
  final String cardType;   // 'visa' | 'mastercard' | 'rupay' | 'amex'
  final String color;      // Hex color for card gradient
  final double outstanding; // Current outstanding amount (manually updated)
  final DateTime createdAt;

  CreditCard({
    String? id,
    this.userId = 'offline_user',
    required this.name,
    required this.bank,
    this.last4 = '0000',
    required this.creditLimit,
    this.billingDay = 1,
    this.dueDay = 20,
    this.cardType = 'visa',
    this.color = '#6366F1',
    this.outstanding = 0,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  double get availableLimit => (creditLimit - outstanding).clamp(0, creditLimit);
  double get utilizationPct => creditLimit > 0 ? (outstanding / creditLimit * 100).clamp(0, 100) : 0;

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
        'credit_limit': creditLimit,
        'billing_day': billingDay,
        'due_day': dueDay,
        'card_type': cardType,
        'color': color,
        'outstanding': outstanding,
        'created_at': createdAt.toIso8601String(),
      };

  factory CreditCard.fromMap(Map<String, dynamic> map) => CreditCard(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        name: map['name'] as String,
        bank: map['bank'] as String,
        last4: map['last4'] as String? ?? '0000',
        creditLimit: (map['credit_limit'] as num).toDouble(),
        billingDay: (map['billing_day'] as int?) ?? 1,
        dueDay: (map['due_day'] as int?) ?? 20,
        cardType: map['card_type'] as String? ?? 'visa',
        color: map['color'] as String? ?? '#6366F1',
        outstanding: (map['outstanding'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.parse(map['created_at'] as String),
      );

  CreditCard copyWith({double? outstanding}) => CreditCard(
        id: id,
        userId: userId,
        name: name,
        bank: bank,
        last4: last4,
        creditLimit: creditLimit,
        billingDay: billingDay,
        dueDay: dueDay,
        cardType: cardType,
        color: color,
        outstanding: outstanding ?? this.outstanding,
        createdAt: createdAt,
      );
}
