import 'package:uuid/uuid.dart';

enum SalaryStatus { pending, received, delayed, onHold, partial }

class Salary {
  Salary({
    String? id,
    required this.companyName,
    required this.salaryMonth,
    required this.expectedDate,
    this.receivedDate,
    required this.netSalary,
    this.amountReceived = 0,
    this.accountId,
    this.linkedTransactionId,
    this.manualStatus,
    this.notes,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final String companyName;
  final DateTime salaryMonth;
  final DateTime expectedDate;
  final DateTime? receivedDate;
  final double netSalary;
  final double amountReceived;
  final String? accountId;
  final String? linkedTransactionId;
  final SalaryStatus? manualStatus;
  final String? notes;
  final DateTime createdAt;

  double get remainingAmount =>
      (netSalary - amountReceived).clamp(0, double.infinity);

  SalaryStatus get status {
    if (manualStatus == SalaryStatus.onHold) return SalaryStatus.onHold;
    if (amountReceived > 0 && amountReceived < netSalary) {
      return SalaryStatus.partial;
    }
    if (amountReceived >= netSalary || receivedDate != null) {
      return SalaryStatus.received;
    }
    if (DateTime.now().isAfter(expectedDate)) {
      return SalaryStatus.delayed;
    }
    return SalaryStatus.pending;
  }

  int get delayedByDays {
    if (status != SalaryStatus.delayed) return 0;
    return DateTime.now().difference(expectedDate).inDays;
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'company_name': companyName,
    'salary_month': salaryMonth.toIso8601String(),
    'expected_date': expectedDate.toIso8601String(),
    'received_date': receivedDate?.toIso8601String(),
    'net_salary': netSalary,
    'amount_received': amountReceived,
    'account_id': accountId,
    'linked_transaction_id': linkedTransactionId,
    'manual_status': manualStatus?.name,
    'notes': notes,
    'created_at': createdAt.toIso8601String(),
  };

  factory Salary.fromMap(Map<String, dynamic> map) => Salary(
    id: map['id'] as String?,
    companyName: map['company_name'] as String? ?? '',
    salaryMonth: DateTime.parse(map['salary_month'] as String),
    expectedDate: DateTime.parse(map['expected_date'] as String),
    receivedDate: map['received_date'] != null
        ? DateTime.tryParse(map['received_date'] as String)
        : null,
    netSalary: (map['net_salary'] as num?)?.toDouble() ?? 0,
    amountReceived: (map['amount_received'] as num?)?.toDouble() ?? 0,
    accountId: map['account_id'] as String?,
    linkedTransactionId: map['linked_transaction_id'] as String?,
    manualStatus: map['manual_status'] != null
        ? SalaryStatus.values.firstWhere(
            (value) => value.name == map['manual_status'],
            orElse: () => SalaryStatus.pending,
          )
        : null,
    notes: map['notes'] as String?,
    createdAt: map['created_at'] != null
        ? DateTime.tryParse(map['created_at'] as String)
        : null,
  );

  Salary copyWith({
    String? companyName,
    DateTime? salaryMonth,
    DateTime? expectedDate,
    DateTime? receivedDate,
    double? netSalary,
    double? amountReceived,
    String? accountId,
    String? linkedTransactionId,
    SalaryStatus? manualStatus,
    String? notes,
  }) {
    return Salary(
      id: id,
      companyName: companyName ?? this.companyName,
      salaryMonth: salaryMonth ?? this.salaryMonth,
      expectedDate: expectedDate ?? this.expectedDate,
      receivedDate: receivedDate ?? this.receivedDate,
      netSalary: netSalary ?? this.netSalary,
      amountReceived: amountReceived ?? this.amountReceived,
      accountId: accountId ?? this.accountId,
      linkedTransactionId: linkedTransactionId ?? this.linkedTransactionId,
      manualStatus: manualStatus ?? this.manualStatus,
      notes: notes ?? this.notes,
      createdAt: createdAt,
    );
  }
}
