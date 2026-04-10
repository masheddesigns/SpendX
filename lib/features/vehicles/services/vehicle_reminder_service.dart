import '../../../models/vehicle_reminder.dart';
import '../../../models/reminder_model.dart' as rm;
import '../../../data/repositories/reminder_repo.dart';
import '../../../data/repositories/vehicle_reminder_repo.dart';
import '../../../services/notification_service_v2.dart';

/// Checks and acknowledges vehicle reminders against the current odometer.
class VehicleReminderService {
  VehicleReminderService._();
  static final VehicleReminderService instance = VehicleReminderService._();

  final VehicleReminderRepo _vehicleReminderRepo = VehicleReminderRepo();
  final ReminderRepo _reminderRepo = ReminderRepo();

  Future<List<VehicleReminder>> getReminders(String vehicleId) async {
    return _vehicleReminderRepo.getByVehicle(vehicleId);
  }

  Future<void> saveReminder(VehicleReminder reminder) async {
    if (await _exists(reminder.id)) {
      await _vehicleReminderRepo.update(reminder);
    } else {
      await _vehicleReminderRepo.insert(reminder);
    }

    // Handle background notification schedule
    if (reminder.isActive && reminder.dueDate != null) {
      final title = reminder.title;
      final body = reminder.recurrencePeriod != null
          ? 'Recurring task is due: $title'
          : 'Task is due: $title';
      await NotificationServiceV2().scheduleNotification(
        id: reminder.id.hashCode & 0x7FFFFFFF,
        title: 'Vehicle Reminder',
        body: body,
        scheduledDate: reminder.dueDate!,
      );
    } else {
      await NotificationServiceV2().cancelNotification(reminder.id);
    }

    await _syncToGlobalReminders(reminder);
  }

  Future<void> _syncToGlobalReminders(VehicleReminder vr) async {
    final reminder = rm.Reminder(
      id: 'vehicle_${vr.id}',
      type: vr.title.toLowerCase().contains('insurance')
          ? rm.ReminderType.insurance
          : rm.ReminderType.service,
      title: vr.title,
      linkedEntityId: vr.vehicleId,
      dueDate: vr.dueDate,
      dueOdometer: vr.dueOdometer,
      recurrencePeriod: _mapRecurrence(vr.recurrencePeriod),
      isActive: vr.isActive,
      createdAt: vr.createdAt,
      status: vr.isActive
          ? rm.ReminderStatus.upcoming
          : rm.ReminderStatus.inactive,
      recordStatus: vr.isActive
          ? rm.ReminderRecordStatus.pending
          : rm.ReminderRecordStatus.done,
      sourceType: rm.ReminderSourceType.vehicle,
      sourceId: vr.id,
    );
    await _reminderRepo.upsert(reminder);
  }

  /// Returns reminders that are overdue or due soon (< 500 km / 7 days).
  Future<List<VehicleReminder>> getAlerts(
    String vehicleId,
    double currentOdo,
  ) async {
    final all = await getReminders(vehicleId);
    return all.where((r) {
      if (!r.isActive) return false;
      if (r.isOverdue(currentOdo)) return true;
      final km = r.kmRemaining(currentOdo);
      if (km != null && km < 500) return true;
      final days = r.daysRemaining();
      if (days != null && days <= 7) return true;
      return false;
    }).toList();
  }

  /// Marks a reminder as triggered at the current odometer and schedules next.
  Future<void> acknowledge(VehicleReminder reminder, double currentOdo) async {
    reminder.lastTriggeredOdometer = currentOdo;
    if (reminder.type == ReminderType.dateBased ||
        reminder.type == ReminderType.hybrid) {
      if (reminder.recurrencePeriod != null && reminder.dueDate != null) {
        final now = DateTime.now();
        final baseDate = reminder.dueDate!.isAfter(now)
            ? reminder.dueDate!
            : now;
        final match = RegExp(
          r'^(\d+)([dwmy])$',
        ).firstMatch(reminder.recurrencePeriod!);
        if (match != null) {
          final count = int.parse(match.group(1)!);
          final unit = match.group(2)!;
          switch (unit) {
            case 'd':
              reminder.dueDate = baseDate.add(Duration(days: count));
              break;
            case 'w':
              reminder.dueDate = baseDate.add(Duration(days: count * 7));
              break;
            case 'm':
              reminder.dueDate = DateTime(
                baseDate.year,
                baseDate.month + count,
                baseDate.day,
              );
              break;
            case 'y':
              reminder.dueDate = DateTime(
                baseDate.year + count,
                baseDate.month,
                baseDate.day,
              );
              break;
          }
        }
      } else if (reminder.type == ReminderType.dateBased) {
        reminder.isActive = false; // Disable one-shot date reminders
      }
    }

    if (reminder.type == ReminderType.odoBased ||
        reminder.type == ReminderType.hybrid) {
      if (reminder.intervalKm != null) {
        // Do NOT disable — interval auto-resets via lastTriggeredOdometer
      } else if (reminder.type == ReminderType.odoBased) {
        reminder.isActive = false; // One-shot odo reminder — disable
      }
    }

    if (reminder.type == ReminderType.hybrid &&
        reminder.intervalKm == null &&
        reminder.recurrencePeriod == null) {
      reminder.isActive = false;
    }
    await saveReminder(reminder);
  }

  Future<bool> _exists(String id) async {
    return _vehicleReminderRepo.exists(id);
  }

  rm.ReminderRecurrence _mapRecurrence(String? recurrence) {
    switch (recurrence) {
      case '1w':
        return rm.ReminderRecurrence.weekly;
      case '1y':
        return rm.ReminderRecurrence.yearly;
      case '1m':
      case '3m':
      case '6m':
        return rm.ReminderRecurrence.monthly;
      default:
        return rm.ReminderRecurrence.none;
    }
  }
}
