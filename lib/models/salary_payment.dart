import 'package:uuid/uuid.dart';

enum SalaryPaymentStatus { pending, received, partial, delayed, onHold }

class SalaryPayment {
  SalaryPayment({
    String? id,
    required this.contractId,
    required this.month,
    required this.expectedDate,
    this.receivedDate,
    required this.totalAmount,
    this.amountReceived = 0,
    this.bonusAmount = 0,
    this.accountId,
    this.linkedTransactionId,
    this.manualStatus,
    this.notes,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String contractId;
  final DateTime month;
  final DateTime expectedDate;
  final DateTime? receivedDate;
  final double totalAmount;
  final double amountReceived;
  final double bonusAmount;
  final String? accountId;
  final String? linkedTransactionId;
  final SalaryPaymentStatus? manualStatus;
  final String? notes;

  double get remainingAmount =>
      (totalAmount - amountReceived).clamp(0, double.infinity);

  SalaryPaymentStatus get status {
    if (manualStatus == SalaryPaymentStatus.onHold) {
      return SalaryPaymentStatus.onHold;
    }
    if (amountReceived >= totalAmount && totalAmount > 0) {
      return SalaryPaymentStatus.received;
    }
    if (amountReceived > 0 && amountReceived < totalAmount) {
      return SalaryPaymentStatus.partial;
    }
    if (DateTime.now().isAfter(expectedDate)) {
      return SalaryPaymentStatus.delayed;
    }
    return SalaryPaymentStatus.pending;
  }

  int get delayedByDays {
    if (status != SalaryPaymentStatus.delayed) return 0;
    return DateTime.now().difference(expectedDate).inDays;
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'contract_id': contractId,
    'month': month.toIso8601String(),
    'expected_date': expectedDate.toIso8601String(),
    'received_date': receivedDate?.toIso8601String(),
    'total_amount': totalAmount,
    'amount_received': amountReceived,
    'bonus_amount': bonusAmount,
    'account_id': accountId,
    'linked_transaction_id': linkedTransactionId,
    'manual_status': manualStatus?.name,
    'notes': notes,
  };

  factory SalaryPayment.fromMap(Map<String, dynamic> map) => SalaryPayment(
    id: map['id'] as String?,
    contractId: map['contract_id'] as String? ?? '',
    month: DateTime.parse(map['month'] as String),
    expectedDate: DateTime.parse(map['expected_date'] as String),
    receivedDate: map['received_date'] != null
        ? DateTime.tryParse(map['received_date'] as String)
        : null,
    totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0,
    amountReceived: (map['amount_received'] as num?)?.toDouble() ?? 0,
    bonusAmount: (map['bonus_amount'] as num?)?.toDouble() ?? 0,
    accountId: map['account_id'] as String?,
    linkedTransactionId: map['linked_transaction_id'] as String?,
    manualStatus: map['manual_status'] != null
        ? SalaryPaymentStatus.values.firstWhere(
            (value) => value.name == map['manual_status'],
            orElse: () => SalaryPaymentStatus.pending,
          )
        : null,
    notes: map['notes'] as String?,
  );

  SalaryPayment copyWith({
    String? contractId,
    DateTime? month,
    DateTime? expectedDate,
    DateTime? receivedDate,
    double? totalAmount,
    double? amountReceived,
    double? bonusAmount,
    String? accountId,
    String? linkedTransactionId,
    SalaryPaymentStatus? manualStatus,
    String? notes,
  }) {
    return SalaryPayment(
      id: id,
      contractId: contractId ?? this.contractId,
      month: month ?? this.month,
      expectedDate: expectedDate ?? this.expectedDate,
      receivedDate: receivedDate ?? this.receivedDate,
      totalAmount: totalAmount ?? this.totalAmount,
      amountReceived: amountReceived ?? this.amountReceived,
      bonusAmount: bonusAmount ?? this.bonusAmount,
      accountId: accountId ?? this.accountId,
      linkedTransactionId: linkedTransactionId ?? this.linkedTransactionId,
      manualStatus: manualStatus ?? this.manualStatus,
      notes: notes ?? this.notes,
    );
  }
}
