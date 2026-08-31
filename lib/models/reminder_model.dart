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

  /// Maps to the `reminders` table. Legacy columns (`description`, `date`,
  /// `repeat_type`, `is_completed`) are preserved for backward compatibility;
  /// the extended columns are added by the V22 migration.
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
    'linked_entity_id': linkedEntityId,
    'due_odometer': dueOdometer,
    'amount': amount,
    'notes': notes,
    'is_active': isActive ? 1 : 0,
    'last_triggered_at': lastTriggeredAt?.toIso8601String(),
    'snoozed_until': snoozedUntil?.toIso8601String(),
    'record_status': recordStatus.name,
    'source_type': sourceType.name,
    'source_id': sourceId,
    'next_trigger_at': nextTriggerAt?.millisecondsSinceEpoch,
  };

  factory Reminder.fromMap(Map<String, dynamic> map) {
    final legacy = _parseLegacyDescription(map['description'] as String? ?? '');

    final isCompleted = (map['is_completed'] as int? ?? 0) == 1;
    final recordStatus = map['record_status'] != null
        ? ReminderRecordStatus.values.firstWhere(
            (value) => value.name == map['record_status'],
            orElse: () => ReminderRecordStatus.pending,
          )
        : isCompleted
        ? ReminderRecordStatus.done
        : ReminderRecordStatus.pending;

    final dueDate = _parseDate(map['date']);
    final isActive = (map['is_active'] as int? ?? 1) == 1;

    final sourceTypeRaw = map['source_type'] as String? ?? legacy['sourceType'];
    final sourceType = ReminderSourceType.values.firstWhere(
      (value) => value.name == sourceTypeRaw,
      orElse: () => ReminderSourceType.manual,
    );
    final linkedEntityId =
        (map['linked_entity_id'] as String?) ?? legacy['linkedEntityId'];

    return Reminder(
      id: map['id'] as String?,
      type: ReminderType.values.firstWhere(
        (value) => value.name == map['type'],
        orElse: () => ReminderType.custom,
      ),
      title: map['title'] as String? ?? 'Reminder',
      linkedEntityId: linkedEntityId,
      dueDate: dueDate,
      dueOdometer: (map['due_odometer'] as num?)?.toDouble(),
      recurrencePeriod: ReminderRecurrence.values.firstWhere(
        (value) => value.name == map['repeat_type'],
        orElse: () => ReminderRecurrence.none,
      ),
      amount: (map['amount'] as num?)?.toDouble(),
      notes: (map['notes'] as String?) ?? legacy['notes'],
      isActive: isActive,
      lastTriggeredAt: _parseDate(map['last_triggered_at']),
      createdAt: _parseDate(map['created_at']) ?? DateTime.now(),
      snoozedUntil: _parseDate(map['snoozed_until']),
      status: _deriveStatus(dueDate, isActive, recordStatus),
      recordStatus: recordStatus,
      sourceType: sourceType,
      sourceId:
          (map['source_id'] as String?) ?? legacy['sourceId'] ?? linkedEntityId,
      nextTriggerAt: map['next_trigger_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (map['next_trigger_at'] as num).toInt(),
            )
          : null,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    final raw = value.toString();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Derives the due-status of a reminder from its persisted state.
  static ReminderStatus _deriveStatus(
    DateTime? dueDate,
    bool isActive,
    ReminderRecordStatus recordStatus,
  ) {
    if (!isActive || recordStatus == ReminderRecordStatus.done) {
      return ReminderStatus.inactive;
    }
    if (dueDate == null) return ReminderStatus.inactive;

    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final due = DateTime(dueDate.year, dueDate.month, dueDate.day);
    if (due.isBefore(day)) return ReminderStatus.overdue;
    if (due.isAtSameMomentAs(day)) return ReminderStatus.dueToday;
    return ReminderStatus.upcoming;
  }

  /// Reads the legacy `description` encoding (`sourceType:entityId`) written
  /// by older builds when dedicated columns did not exist yet.
  static Map<String, String?> _parseLegacyDescription(String desc) {
    if (desc.isEmpty) return const {};
    final idx = desc.indexOf(':');
    if (idx <= 0) return {'notes': desc};

    final key = desc.substring(0, idx);
    if (!ReminderSourceType.values.any((value) => value.name == key)) {
      return {'notes': desc};
    }

    final rest = desc.substring(idx + 1);
    final segments = rest.split(':');
    return {
      'sourceType': key,
      'linkedEntityId': segments.isNotEmpty ? segments[0] : null,
      'sourceId': segments.length > 1 ? segments[1] : null,
    };
  }
}
