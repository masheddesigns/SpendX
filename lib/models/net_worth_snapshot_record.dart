class NetWorthSnapshotRecord {
  const NetWorthSnapshotRecord({
    required this.id,
    required this.netWorth,
    required this.assets,
    required this.liabilities,
    required this.timestamp,
  });

  final String id;
  final double netWorth;
  final double assets;
  final double liabilities;
  final DateTime timestamp;

  factory NetWorthSnapshotRecord.fromMap(Map<String, dynamic> map) {
    return NetWorthSnapshotRecord(
      id: map['id'] as String,
      netWorth: (map['net_worth'] as num).toDouble(),
      assets: (map['assets'] as num).toDouble(),
      liabilities: (map['liabilities'] as num).toDouble(),
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'net_worth': netWorth,
      'assets': assets,
      'liabilities': liabilities,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}
