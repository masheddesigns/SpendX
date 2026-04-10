import 'package:uuid/uuid.dart';

class SalaryContract {
  SalaryContract({
    String? id,
    required this.companyId,
    required this.baseSalary,
    required this.startDate,
    this.defaultAccountId,
    this.isActive = true,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final String companyId;
  final double baseSalary;
  final DateTime startDate;
  final String? defaultAccountId;
  final bool isActive;
  final DateTime createdAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'company_id': companyId,
    'base_salary': baseSalary,
    'start_date': startDate.toIso8601String(),
    'default_account_id': defaultAccountId,
    'is_active': isActive ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory SalaryContract.fromMap(Map<String, dynamic> map) => SalaryContract(
    id: map['id'] as String?,
    companyId: map['company_id'] as String? ?? '',
    baseSalary: (map['base_salary'] as num?)?.toDouble() ?? 0,
    startDate: DateTime.parse(map['start_date'] as String),
    defaultAccountId: map['default_account_id'] as String?,
    isActive: (map['is_active'] as int? ?? 1) == 1,
    createdAt: map['created_at'] != null
        ? DateTime.tryParse(map['created_at'] as String) ?? DateTime.now()
        : DateTime.now(),
  );

  SalaryContract copyWith({
    String? companyId,
    double? baseSalary,
    DateTime? startDate,
    String? defaultAccountId,
    bool? isActive,
  }) {
    return SalaryContract(
      id: id,
      companyId: companyId ?? this.companyId,
      baseSalary: baseSalary ?? this.baseSalary,
      startDate: startDate ?? this.startDate,
      defaultAccountId: defaultAccountId ?? this.defaultAccountId,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
    );
  }
}
