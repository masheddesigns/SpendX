import 'package:uuid/uuid.dart';

/// Employment types for salary tracking.
enum EmploymentType {
  fullTime,
  partTime,
  freelance,
  contract,
}

/// Pay cycle determines how often income is expected.
enum PayCycle {
  monthly,    // Traditional salary — once a month
  weekly,     // Weekly pay (Upwork, gig platforms)
  biWeekly,   // Every 2 weeks
  daily,      // Day rate / per-shift
  perProject, // Milestone/project-based, irregular
}

class Company {
  Company({
    String? id,
    required this.name,
    required this.salaryCreditDay,
    this.currency = 'INR',
    this.employmentType = EmploymentType.fullTime,
    this.payCycle = PayCycle.monthly,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final String name;
  final int salaryCreditDay;
  final String currency;
  final EmploymentType employmentType;
  final PayCycle payCycle;
  final DateTime createdAt;

  String get employmentLabel {
    switch (employmentType) {
      case EmploymentType.fullTime:
        return 'Full-time';
      case EmploymentType.partTime:
        return 'Part-time';
      case EmploymentType.freelance:
        return 'Freelance';
      case EmploymentType.contract:
        return 'Contract';
    }
  }

  String get payCycleLabel {
    switch (payCycle) {
      case PayCycle.monthly:
        return 'Monthly';
      case PayCycle.weekly:
        return 'Weekly';
      case PayCycle.biWeekly:
        return 'Bi-weekly';
      case PayCycle.daily:
        return 'Daily';
      case PayCycle.perProject:
        return 'Per Project';
    }
  }

  /// True if the pay cycle doesn't have a fixed monthly expectation.
  bool get isFlexibleCycle =>
      payCycle == PayCycle.daily || payCycle == PayCycle.perProject;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'salary_credit_day': salaryCreditDay,
    'currency': currency,
    'employment_type': employmentType.name,
    'pay_cycle': payCycle.name,
    'created_at': createdAt.toIso8601String(),
  };

  factory Company.fromMap(Map<String, dynamic> map) => Company(
    id: map['id'] as String?,
    name: map['name'] as String? ?? '',
    salaryCreditDay: (map['salary_credit_day'] as num?)?.toInt() ?? 1,
    currency: map['currency'] as String? ?? 'INR',
    employmentType: _parseEmploymentType(map['employment_type'] as String?),
    payCycle: _parsePayCycle(map['pay_cycle'] as String?),
    createdAt: map['created_at'] != null
        ? DateTime.tryParse(map['created_at'] as String) ?? DateTime.now()
        : DateTime.now(),
  );

  Company copyWith({
    String? name,
    int? salaryCreditDay,
    String? currency,
    EmploymentType? employmentType,
    PayCycle? payCycle,
  }) {
    return Company(
      id: id,
      name: name ?? this.name,
      salaryCreditDay: salaryCreditDay ?? this.salaryCreditDay,
      currency: currency ?? this.currency,
      employmentType: employmentType ?? this.employmentType,
      payCycle: payCycle ?? this.payCycle,
      createdAt: createdAt,
    );
  }

  static EmploymentType _parseEmploymentType(String? value) {
    if (value == null) return EmploymentType.fullTime;
    return EmploymentType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => EmploymentType.fullTime,
    );
  }

  static PayCycle _parsePayCycle(String? value) {
    if (value == null) return PayCycle.monthly;
    return PayCycle.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PayCycle.monthly,
    );
  }
}
