import 'package:uuid/uuid.dart';

enum ReminderType {
  salary,
  loan,
  credit,
  emi,
  insurance,
  service,
  lending,
  custom,
}

enum ReminderRecurrence { none, weekly, monthly, yearly }

enum ReminderStatus { overdue, dueToday, upcoming, inactive }

enum ReminderRecordStatus { pending, done, snoozed }

enum ReminderSourceType { salary, loan, credit, vehicle, lending, manual }

class Reminder {
  Reminder({
    String? id,
    required this.type,
    required this.title,
    this.linkedEntityId,
    this.dueDate,
    this.dueOdometer,
    this.recurrencePeriod = ReminderRecurrence.none,
    this.amount,
    this.notes,
    this.isActive = true,
    this.lastTriggeredAt,
    DateTime? createdAt,
    this.snoozedUntil,
    this.status = ReminderStatus.inactive,
    this.recordStatus = ReminderRecordStatus.pending,
    this.sourceType = ReminderSourceType.manual,
    this.sourceId,
    this.nextTriggerAt,
    this.metadata = const {},
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final ReminderType type;
  final String title;
  final String? linkedEntityId;
  final DateTime? dueDate;
  final double? dueOdometer;
  final ReminderRecurrence recurrencePeriod;
  final double? amount;
  final String? notes;
  final bool isActive;
  final DateTime? lastTriggeredAt;
  final DateTime createdAt;
  final DateTime? snoozedUntil;
  final ReminderStatus status;
  final ReminderRecordStatus recordStatus;
  final ReminderSourceType sourceType;
  final String? sourceId;
  final DateTime? nextTriggerAt;
  final Map<String, dynamic> metadata;

  bool get isSnoozed =>
      recordStatus == ReminderRecordStatus.snoozed &&
      effectiveNextTriggerAt != null &&
      effectiveNextTriggerAt!.isAfter(DateTime.now());

  bool get isDone => recordStatus == ReminderRecordStatus.done;

  DateTime? get effectiveNextTriggerAt => nextTriggerAt ?? snoozedUntil;

  Reminder copyWith({
    String? id,
    ReminderType? type,
    String? title,
    String? linkedEntityId,
    DateTime? dueDate,
    double? dueOdometer,
    ReminderRecurrence? recurrencePeriod,
    double? amount,
    String? notes,
    bool? isActive,
    DateTime? lastTriggeredAt,
    DateTime? createdAt,
    DateTime? snoozedUntil,
    ReminderStatus? status,
    ReminderRecordStatus? recordStatus,
    ReminderSourceType? sourceType,
    String? sourceId,
    DateTime? nextTriggerAt,
    Map<String, dynamic>? metadata,
  }) {
    return Reminder(
      id: id ?? this.id,
      type: type ?? this.type,
      title: title ?? this.title,
      linkedEntityId: linkedEntityId ?? this.linkedEntityId,
      dueDate: dueDate ?? this.dueDate,
      dueOdometer: dueOdometer ?? this.dueOdometer,
      recurrencePeriod: recurrencePeriod ?? this.recurrencePeriod,
      amount: amount ?? this.amount,
      notes: notes ?? this.notes,
      isActive: isActive ?? this.isActive,
      lastTriggeredAt: lastTriggeredAt ?? this.lastTriggeredAt,
      createdAt: createdAt ?? this.createdAt,
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
      status: status ?? this.status,
      recordStatus: recordStatus ?? this.recordStatus,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      nextTriggerAt: nextTriggerAt ?? this.nextTriggerAt,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Maps to actual DB columns: id, title, description, type, date,
  /// repeat_type, is_completed, created_at
  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'description': notes ?? '${sourceType.name}:${linkedEntityId ?? ""}',
    'type': type.name,
    'date': dueDate?.toIso8601String() ?? createdAt.toIso8601String(),
    'repeat_type': recurrencePeriod == ReminderRecurrence.none
        ? 'once'
        : recurrencePeriod.name,
    'is_completed': recordStatus == ReminderRecordStatus.done ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory Reminder.fromMap(Map<String, dynamic> map) {
    return Reminder(
      id: map['id'] as String?,
      type: ReminderType.values.firstWhere(
        (value) => value.name == map['type'],
        orElse: () => ReminderType.custom,
      ),
      title: map['title'] as String? ?? 'Reminder',
      linkedEntityId: map['linked_entity_id'] as String?,
      dueDate: map['due_date'] != null
          ? DateTime.tryParse(map['due_date'] as String)
          : null,
      dueOdometer: (map['due_odometer'] as num?)?.toDouble(),
      recurrencePeriod: ReminderRecurrence.values.firstWhere(
        (value) => value.name == map['recurrence_period'],
        orElse: () => ReminderRecurrence.none,
      ),
      amount: (map['amount'] as num?)?.toDouble(),
      notes: map['notes'] as String?,
      isActive: (map['is_active'] as int? ?? 1) == 1,
      lastTriggeredAt: map['last_triggered_at'] != null
          ? DateTime.tryParse(map['last_triggered_at'] as String)
          : null,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      snoozedUntil: map['snoozed_until'] != null
          ? DateTime.tryParse(map['snoozed_until'] as String)
          : null,
      recordStatus: ReminderRecordStatus.values.firstWhere(
        (value) => value.name == map['status'],
        orElse: () => ReminderRecordStatus.pending,
      ),
      sourceType: ReminderSourceType.values.firstWhere(
        (value) => value.name == map['source_type'],
        orElse: () => ReminderSourceType.manual,
      ),
      sourceId:
          map['source_id'] as String? ?? map['linked_entity_id'] as String?,
      nextTriggerAt: map['next_trigger_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (map['next_trigger_at'] as num).toInt(),
            )
          : null,
    );
  }
}
