import 'package:uuid/uuid.dart';

class BankAccount {
  final String id;
  final String userId;
  final String name; // e.g. "SBI Savings"
  final String bank; // e.g. "State Bank of India"
  final String
  accountType; // 'savings' | 'current' | 'fd' | 'wallet' | 'ppf' | 'stock'
  final double balance;
  final String color; // Hex color for display
  final String icon; // Icon name
  final bool isAsset; // true = asset, false = liability
  final DateTime createdAt;
  final DateTime updatedAt;

  BankAccount({
    String? id,
    this.userId = 'offline_user',
    required this.name,
    required this.bank,
    this.accountType = 'savings',
    required this.balance,
    this.color = '#10B981',
    this.icon = 'account_balance',
    this.isAsset = true,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  static String iconForType(String type) {
    switch (type) {
      case 'savings':
        return 'account_balance';
      case 'current':
        return 'account_balance_wallet';
      case 'fd':
        return 'lock';
      case 'cash':
        return 'payments';
      case 'wallet':
        return 'wallet';
      case 'ppf':
        return 'savings';
      case 'stock':
        return 'trending_up';
      case 'mutual_fund':
        return 'pie_chart';
      default:
        return 'account_balance';
    }
  }

  static String colorForType(String type) {
    switch (type) {
      case 'savings':
        return '#10B981';
      case 'current':
        return '#3B82F6';
      case 'fd':
        return '#F59E0B';
      case 'cash':
        return '#22C55E';
      case 'wallet':
        return '#8B5CF6';
      case 'ppf':
        return '#06B6D4';
      case 'stock':
        return '#EF4444';
      case 'mutual_fund':
        return '#EC4899';
      default:
        return '#10B981';
    }
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'bank': bank,
    'account_type': accountType,
    'balance': balance,
    'color': color,
    'icon': icon,
    'is_asset': isAsset ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory BankAccount.fromMap(Map<String, dynamic> map) => BankAccount(
    id: map['id'] as String,
    userId: map['user_id'] as String? ?? 'offline_user',
    name: map['name'] as String,
    bank: map['bank'] as String? ?? '',
    accountType: map['account_type'] as String? ?? 'savings',
    balance: (map['balance'] as num).toDouble(),
    color: map['color'] as String? ?? '#10B981',
    icon: map['icon'] as String? ?? 'account_balance',
    isAsset: (map['is_asset'] as int? ?? 1) == 1,
    createdAt: map['created_at'] != null
        ? DateTime.parse(map['created_at'] as String)
        : DateTime.now(),
    updatedAt: map['updated_at'] != null
        ? DateTime.parse(map['updated_at'] as String)
        : DateTime.now(),
  );

  BankAccount copyWith({String? id, double? balance, String? name}) =>
      BankAccount(
        id: id ?? this.id,
        userId: userId,
        name: name ?? this.name,
        bank: bank,
        accountType: accountType,
        balance: balance ?? this.balance,
        color: color,
        icon: icon,
        isAsset: isAsset,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
}
