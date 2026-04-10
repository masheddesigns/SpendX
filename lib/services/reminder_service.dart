import 'dart:async';

import 'package:flutter/material.dart';

import '../core/database/database_service.dart';
import '../data/repositories/reminder_repo.dart';
import '../features/alerts/data/alert_service.dart';
import '../models/reminder_model.dart';
import 'notification_service_v2.dart';

class ReminderService extends ChangeNotifier {
  ReminderService({required this.reminderRepo});

  final ReminderRepo reminderRepo;

  static final instance = ReminderService(reminderRepo: ReminderRepo());

  static const Duration _backgroundCheckInterval = Duration(minutes: 15);
  static const Duration _popupCooldown = Duration(minutes: 30);

  final NotificationServiceV2 _notificationService = NotificationServiceV2();
  Timer? _periodicTimer;
  bool _initialized = false;
  List<Reminder> _cachedDueReminders = const [];

  List<Reminder> get cachedDueReminders => _cachedDueReminders;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await refreshDueReminders();
    _periodicTimer = Timer.periodic(_backgroundCheckInterval, (_) {
      unawaited(checkAndDispatchAlerts());
    });
  }

  Future<List<Reminder>> getAllReminders() async {
    final reminders = await reminderRepo.getAll();
    reminders.sort(_sortByPriority);
    return reminders;
  }

  Future<List<Reminder>> getAllDueReminders() async {
    return refreshDueReminders();
  }

  Future<List<Reminder>> refreshDueReminders() async {
    final allReminders = await getAllReminders();
    final reminders = allReminders
        .where(
          (reminder) =>
              reminder.status != ReminderStatus.inactive &&
              !reminder.isSnoozed &&
              reminder.recordStatus != ReminderRecordStatus.done,
        )
        .toList();
    await _syncScheduledNotifications(allReminders);
    _cachedDueReminders = reminders;
    notifyListeners();
    return reminders;
  }

  Future<void> checkAndDispatchAlerts({BuildContext? context}) async {
    final reminders = await refreshDueReminders();
    for (final reminder in reminders) {
      if (!_shouldAlert(reminder)) continue;

      await _notificationService.showReminderAlert(
        reminder,
        // ignore: use_build_context_synchronously
        context: context,
        onMarkDone: () => markReminderDone(reminder),
        onSnooze: (duration) => snoozeReminder(reminder, duration),
      );

      await _persistReminderMeta(
        reminder.copyWith(lastTriggeredAt: DateTime.now()),
      );
    }
  }

  Future<void> markReminderDone(Reminder reminder) async {
    await AlertService(
      databaseService: DatabaseService(),
    ).markDone(reminder.id);
    await refreshDueReminders();
  }

  Future<void> snoozeReminder(Reminder reminder, Duration duration) async {
    await AlertService(
      databaseService: DatabaseService(),
    ).snooze(reminder.id, duration);
    await refreshDueReminders();
  }

  Future<void> snoozeReminderById(String alertId, Duration duration) async {
    await AlertService(
      databaseService: DatabaseService(),
    ).snooze(alertId, duration);
    await refreshDueReminders();
  }

  Future<void> saveCustomReminder(Reminder reminder) async {
    await reminderRepo.upsert(reminder);
    await refreshDueReminders();
  }

  Future<void> deleteCustomReminder(String id) async {
    await reminderRepo.deleteGlobalReminder(id);
    await refreshDueReminders();
  }

  Future<void> disposeService() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _initialized = false;
  }

  Future<void> _syncScheduledNotifications(List<Reminder> reminders) async {
    await _notificationService.syncNotificationsFromDB(reminders);
  }

  bool _shouldAlert(Reminder reminder) {
    if (reminder.status == ReminderStatus.inactive || reminder.isSnoozed) {
      return false;
    }
    if (reminder.lastTriggeredAt == null) return true;
    return DateTime.now().difference(reminder.lastTriggeredAt!) >=
        _popupCooldown;
  }

  int _sortByPriority(Reminder a, Reminder b) {
    const order = {
      ReminderStatus.overdue: 0,
      ReminderStatus.dueToday: 1,
      ReminderStatus.upcoming: 2,
      ReminderStatus.inactive: 3,
    };
    final statusCompare = (order[a.status] ?? 99).compareTo(
      order[b.status] ?? 99,
    );
    if (statusCompare != 0) return statusCompare;

    if (a.dueDate == null && b.dueDate == null) {
      return a.title.compareTo(b.title);
    }
    if (a.dueDate == null) return 1;
    if (b.dueDate == null) return -1;
    return a.dueDate!.compareTo(b.dueDate!);
  }

  Future<void> _persistReminderMeta(Reminder reminder) async {
    await reminderRepo.update(reminder);
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    super.dispose();
  }
}
