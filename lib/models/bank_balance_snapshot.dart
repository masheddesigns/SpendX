class BankBalanceSnapshot {
  final int? id;
  final String accountId;
  final double balance;
  final DateTime timestamp;

  BankBalanceSnapshot({
    this.id,
    required this.accountId,
    required this.balance,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'accountId': accountId,
      'balance': balance,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  factory BankBalanceSnapshot.fromMap(Map<String, dynamic> map) {
    return BankBalanceSnapshot(
      id: map['id'],
      accountId: map['accountId'],
      balance: (map['balance'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
    );
  }

  /// Normalizes a DateTime to YYYY-MM-DD for deduplication
  static DateTime normalize(DateTime dt) {
    return DateTime(dt.year, dt.month, dt.day);
  }
}
