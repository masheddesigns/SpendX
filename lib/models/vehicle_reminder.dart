import 'package:uuid/uuid.dart';

enum ReminderType { dateBased, odoBased, hybrid }

/// A vehicle-linked reminder supporting three trigger modes:
/// - date_based: fires after a due date
/// - odo_based: fires when current odometer reaches dueOdometer,
///              OR every intervalKm km (from lastTriggeredOdometer)
/// - hybrid: fires on whichever comes first
class VehicleReminder {
  final String id;
  final String vehicleId;
  String title;
  ReminderType type;

  // Date-based fields
  DateTime? dueDate;
  String? recurrencePeriod; // e.g. '1w', '1m', '3m', '6m', '1y'

  // Odometer-based fields
  double? dueOdometer;      // absolute odometer reading to trigger once
  double? intervalKm;       // repeat every N km from lastTriggeredOdometer
  double? lastTriggeredOdometer;

  bool isActive;
  String? notes;
  final DateTime createdAt;

  VehicleReminder({
    String? id,
    required this.vehicleId,
    required this.title,
    this.type = ReminderType.dateBased,
    this.dueDate,
    this.recurrencePeriod,
    this.dueOdometer,
    this.intervalKm,
    this.lastTriggeredOdometer,
    this.isActive = true,
    this.notes,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  // ── Status helpers ──────────────────────────────────────────────

  /// Returns true if this reminder is currently overdue.
  bool isOverdue(double currentOdo) {
    final dateOverdue = dueDate != null && DateTime.now().isAfter(dueDate!);
    final odoOverdue = _isOdoOverdue(currentOdo);
    switch (type) {
      case ReminderType.dateBased:
        return dateOverdue;
      case ReminderType.odoBased:
        return odoOverdue;
      case ReminderType.hybrid:
        return dateOverdue || odoOverdue;
    }
  }

  /// Returns km remaining until this reminder triggers (null if not odo-based).
  double? kmRemaining(double currentOdo) {
    if (type == ReminderType.dateBased) return null;
    final target = _nextOdoTarget();
    if (target == null) return null;
    return target - currentOdo;
  }

  /// Returns days remaining until due date (null if not date-based).
  int? daysRemaining() {
    if (dueDate == null) return null;
    return dueDate!.difference(DateTime.now()).inDays;
  }

  bool _isOdoOverdue(double currentOdo) {
    final target = _nextOdoTarget();
    return target != null && currentOdo >= target;
  }

  double? _nextOdoTarget() {
    if (intervalKm != null && intervalKm! > 0) {
      final base = lastTriggeredOdometer ?? 0;
      return base + intervalKm!;
    }
    return dueOdometer;
  }

  // ── Serialisation ───────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
        'id': id,
        'vehicle_id': vehicleId,
        'title': title,
        'type': type.name,
        'due_date': dueDate?.toIso8601String(),
        'recurrence_period': recurrencePeriod,
        'due_odometer': dueOdometer,
        'interval_km': intervalKm,
        'last_triggered_odometer': lastTriggeredOdometer,
        'is_active': isActive ? 1 : 0,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
      };

  factory VehicleReminder.fromMap(Map<String, dynamic> m) => VehicleReminder(
        id: m['id'] as String,
        vehicleId: m['vehicle_id'] as String,
        title: m['title'] as String,
        type: ReminderType.values.firstWhere(
          (e) => e.name == m['type'],
          orElse: () => ReminderType.dateBased,
        ),
        dueDate: m['due_date'] != null ? DateTime.parse(m['due_date'] as String) : null,
        recurrencePeriod: m['recurrence_period'] as String?,
        dueOdometer: m['due_odometer'] != null ? (m['due_odometer'] as num).toDouble() : null,
        intervalKm: m['interval_km'] != null ? (m['interval_km'] as num).toDouble() : null,
        lastTriggeredOdometer: m['last_triggered_odometer'] != null
            ? (m['last_triggered_odometer'] as num).toDouble()
            : null,
        isActive: (m['is_active'] as int? ?? 1) == 1,
        notes: m['notes'] as String?,
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}
