import 'package:uuid/uuid.dart';

class Increment {
  Increment({
    String? id,
    required this.contractId,
    required this.amountIncrease,
    required this.effectiveFrom,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String contractId;
  final double amountIncrease;
  final DateTime effectiveFrom;

  Map<String, dynamic> toMap() => {
    'id': id,
    'contract_id': contractId,
    'amount_increase': amountIncrease,
    'effective_from': effectiveFrom.toIso8601String(),
  };

  factory Increment.fromMap(Map<String, dynamic> map) => Increment(
    id: map['id'] as String?,
    contractId: map['contract_id'] as String? ?? '',
    amountIncrease: (map['amount_increase'] as num?)?.toDouble() ?? 0,
    effectiveFrom: DateTime.parse(map['effective_from'] as String),
  );
}
