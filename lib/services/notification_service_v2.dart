import '../core/logging/app_logger.dart';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'notification_settings_service.dart';
import '../models/notification_settings.dart';
import '../models/reminder_model.dart';
import 'haptic_service.dart';
import '../widgets/common/primary_action_button.dart';
import '../main.dart';
import '../features/salary/screens/salary_screen.dart';
import '../screens/loans/loans_screen.dart';
import '../screens/credit_card_screen.dart';
import '../screens/lending/lending_screen.dart';
import '../shared/widgets/app_page_route.dart';

class NotificationServiceV2 {
  static final NotificationServiceV2 _instance = NotificationServiceV2._();
  factory NotificationServiceV2() => _instance;

  NotificationServiceV2._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final _settingsService = NotificationSettingsService();
  final List<_QueuedReminderAlert> _popupQueue = [];
  bool _isShowingPopup = false;
  int _nextEphemeralId = 400000;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Initialize Timezones — wrapped defensively
    try {
      tz_data.initializeTimeZones();
    } catch (_) {}
    try {
      final tzInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzInfo.identifier));
    } catch (e) {
      // Fallback — timezone not critical for basic functionality
    }

    /// Use ic_notification — a white transparent vector drawable — as the
    /// small notification icon. Using the launcher icon causes a grey square.
    const android = AndroidInitializationSettings('@drawable/ic_notification');
    const darwin = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleNotificationTap,
    );

    // Create Channels
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'spendx_channel',
            'SpendX Notifications',
            importance: Importance.max,
          ),
        );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'scheduled_channel',
            'Scheduled Notifications',
            importance: Importance.high,
          ),
        );
  }

  Future<void> showNotification({
    required String title,
    required String body,
    String? category, // e.g. 'backupStatus'
    int? id,
  }) async {
    if (category != null) {
      final settings = await _settingsService.load();
      final map = settings.toMap();
      if (map[category] == false) return;
    }

    const androidDetails = AndroidNotificationDetails(
      'spendx_channel',
      'SpendX Notifications',
      channelDescription: 'SpendX financial alerts & reminders',
      icon: '@drawable/ic_notification',
      importance: Importance.max,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(
      id: id ?? _allocateEphemeralId(),
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? category,
    String? payload,
  }) async {
    // Ensure timezone is initialized before scheduling
    if (!_initialized) await init();

    if (category != null) {
      final settings = await _settingsService.load();
      final map = settings.toMap();
      if (map[category] == false) return;
    }

    if (scheduledDate.isBefore(DateTime.now())) return;

    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(scheduledDate, tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'scheduled_channel',
          'Scheduled Notifications',
          channelDescription: 'SpendX daily reminder',
          icon: '@drawable/ic_notification',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payload,
    );
  }

  Future<void> cancelNotification(String id) async {
    final numericId = id.hashCode & 0x7FFFFFFF;
    await _plugin.cancel(id: numericId);
  }

  Future<void> showInstant({
    required String title,
    required String body,
    String? channelId,
    int? id,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      channelId ?? 'spendx_channel',
      'SpendX Notifications',
      channelDescription: 'SpendX alerts',
      icon: '@drawable/ic_notification',
      importance: Importance.max,
      priority: Priority.high,
    );

    await _plugin.show(
      id: id ?? _allocateEphemeralId(),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: androidDetails),
    );
  }

  Future<void> syncNotificationsFromDB(List<Reminder> reminders) async {
    final settings = await _settingsService.load();

    // 1. Cancel all scheduled notifications to start fresh (avoids duplicates)
    await _plugin.cancelAll();

    // 2. Define a horizon to avoid hitting Android's 500 alarm limit
    final now = DateTime.now();
    final horizon = now.add(const Duration(days: 45));

    for (final reminder in reminders) {
      if (!reminder.isActive || reminder.isDone) continue;

      // Skip reminders that are too far in the future
      if (reminder.dueDate != null && reminder.dueDate!.isAfter(horizon)) {
        continue;
      }

      final category = _categoryForReminder(reminder);
      final settingsMap = settings.toMap();
      if (settingsMap[category] == false) continue;

      await _cancelReminderSchedules(reminder.id);
      await _scheduleForType(reminder, settings);
    }
  }

  Future<void> _scheduleForType(
    Reminder reminder,
    NotificationSettings settings,
  ) async {
    final reminderTime = settings.reminderTime;
    final hour = _parseReminderHour(reminderTime);
    final minute = _parseReminderMinute(reminderTime);

    final payload = jsonEncode({
      'source_type': reminder.type.name,
      'source_id': reminder.sourceId ?? reminder.linkedEntityId ?? '',
    });

    switch (reminder.type) {
      case ReminderType.salary:
        // Rule: Notify same day at 9 PM
        if (reminder.dueDate != null) {
          final scheduledDate = DateTime(
            reminder.dueDate!.year,
            reminder.dueDate!.month,
            reminder.dueDate!.day,
            21,
            0,
          );
          await _safeSchedule(
            id: _notificationIdFor(reminder.id, 'due'),
            title: 'Salary Due Today',
            body: _buildReminderBody(reminder),
            scheduledDate: scheduledDate,
            payload: payload,
          );
        }
        break;

      case ReminderType.loan:
      case ReminderType.credit:
      case ReminderType.emi:
        // Rule: 2 days before + due day
        if (reminder.dueDate != null) {
          // 2 days before
          final upcomingAt = _scheduleAt(
            reminder.dueDate!.subtract(const Duration(days: 2)),
            hour,
            minute,
          );
          await _safeSchedule(
            id: _notificationIdFor(reminder.id, 'upcoming'),
            title: _notificationTitle(reminder, upcoming: true),
            body: _buildReminderBody(reminder),
            scheduledDate: upcomingAt,
            payload: payload,
          );

          // Due day
          final dueAt = _scheduleAt(reminder.dueDate!, hour, minute);
          await _safeSchedule(
            id: _notificationIdFor(reminder.id, 'due'),
            title: _notificationTitle(reminder),
            body: _buildReminderBody(reminder),
            scheduledDate: dueAt,
            payload: payload,
          );
        }
        break;

      case ReminderType.service:
      case ReminderType.insurance:
        // Rule: Date-based vehicle/insurance
        if (reminder.dueDate != null) {
          final dueAt = _scheduleAt(reminder.dueDate!, hour, minute);
          await _safeSchedule(
            id: _notificationIdFor(reminder.id, 'due'),
            title: _notificationTitle(reminder),
            body: _buildReminderBody(reminder),
            scheduledDate: dueAt,
            payload: payload,
          );
        }
        break;

      case ReminderType.lending:
        // Rule: Notify on due date
        if (reminder.dueDate != null) {
          final dueAt = _scheduleAt(reminder.dueDate!, hour, minute);
          await _safeSchedule(
            id: _notificationIdFor(reminder.id, 'due'),
            title: _notificationTitle(reminder),
            body: _buildReminderBody(reminder),
            scheduledDate: dueAt,
            payload: payload,
          );
        }
        break;

      case ReminderType.custom:
        // Rule: User selected time
        final triggerAt =
            reminder.effectiveNextTriggerAt ??
            (reminder.dueDate != null
                ? _scheduleAt(reminder.dueDate!, hour, minute)
                : null);
        if (triggerAt != null) {
          await _safeSchedule(
            id: _notificationIdFor(reminder.id, 'custom'),
            title: reminder.title,
            body: reminder.notes ?? 'Scheduled reminder',
            scheduledDate: triggerAt,
            payload: payload,
          );
        }
        break;
    }
  }

  Future<void> _safeSchedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? payload,
  }) async {
    if (scheduledDate.isBefore(DateTime.now())) return;
    await scheduleNotification(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      payload: payload,
    );
  }

  void _handleNotificationTap(NotificationResponse details) {
    if (details.payload == null || details.payload!.isEmpty) return;

    try {
      final payload = jsonDecode(details.payload!);
      handleNotificationNavigation(
        payload['source_type'] ?? '',
        payload['source_id'] ?? '',
      );
    } catch (e) {
      AppLogger.d('Error decoding notification payload: $e');
    }
  }

  void handleNotificationNavigation(String sourceType, String sourceId) {
    final context = MyApp.navigatorKey.currentContext;
    if (context == null) return;

    AppLogger.d('Routing to $sourceType with ID: $sourceId');

    switch (sourceType) {
      case 'salary':
        Navigator.of(context).push(
          AppPageRoute(builder: (_) => const SalaryScreen()),
        );
        break;
      case 'loan':
      case 'emi':
        Navigator.of(
          context,
        ).push(AppPageRoute(builder: (_) => const LoansScreen()));
        break;
      case 'credit':
        Navigator.of(
          context,
        ).push(AppPageRoute(builder: (_) => const CreditCardScreen()));
        break;
      case 'service':
      case 'insurance':
      case 'vehicle':
        break;
      case 'lending':
        Navigator.of(
          context,
        ).push(AppPageRoute(builder: (_) => const LendingScreen()));
        break;
      default:
        // Generic landing
        break;
    }
  }

  Future<void> showReminderAlert(
    Reminder reminder, {
    BuildContext? context,
    Future<void> Function()? onMarkDone,
    Future<void> Function(Duration)? onSnooze,
    VoidCallback? onViewDetails,
  }) async {
    if (context == null) {
      await showNotification(
        title: 'Reminder Due',
        body: _buildReminderBody(reminder),
        category: 'paymentReminder',
      );
      return;
    }

    _popupQueue.add(
      _QueuedReminderAlert(
        reminder: reminder,
        context: context,
        onMarkDone: onMarkDone,
        onSnooze: onSnooze,
        onViewDetails: onViewDetails,
      ),
    );
    await _drainPopupQueue();
  }

  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
  }) async {
    const int reminderId = 999;
    await _plugin.cancel(id: reminderId);

    final settings = await _settingsService.load();
    if (!settings.expenseReminder) return;

    // Sound resolved per user preference
    final AndroidNotificationSound? resolvedSound;
    switch (settings.reminderSound) {
      case 'elegant':
        resolvedSound = const RawResourceAndroidNotificationSound('elegant');
        break;
      case 'bright':
        resolvedSound = const RawResourceAndroidNotificationSound('bright');
        break;
      case 'nature':
        resolvedSound = const RawResourceAndroidNotificationSound('nature');
        break;
      case 'digital':
        resolvedSound = const RawResourceAndroidNotificationSound('digital');
        break;
      default:
        resolvedSound = null; // System default
    }

    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    Future<void> doSchedule(AndroidNotificationSound? snd) =>
        _plugin.zonedSchedule(
          id: reminderId,
          title: 'SpendX Reminder',
          body: 'Time to log your expenses and stay on track!',
          scheduledDate: scheduledDate,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              'scheduled_channel',
              'Scheduled Notifications',
              channelDescription: 'SpendX daily reminder',
              icon: '@drawable/ic_notification',
              importance: Importance.high,
              priority: Priority.high,
              sound: snd,
              playSound: snd != null,
            ),
            iOS: const DarwinNotificationDetails(),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time,
        );

    try {
      await doSchedule(resolvedSound);
    } catch (_) {
      // Custom sound file missing — fall back to system default
      await doSchedule(null);
    }
  }

  Future<void> refreshAllReminders() async {
    final settings = await _settingsService.load();
    final timeParts = settings.reminderTime.split(':');
    if (timeParts.length == 2) {
      final h = int.tryParse(timeParts[0]) ?? 9;
      final m = int.tryParse(timeParts[1]) ?? 0;
      await scheduleDailyReminder(hour: h, minute: m);
    }
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  String _buildReminderBody(Reminder reminder) {
    switch (reminder.type) {
      case ReminderType.salary:
        return '${reminder.title}. Add or confirm now.';
      case ReminderType.credit:
      case ReminderType.loan:
      case ReminderType.emi:
      case ReminderType.lending:
        final amount = reminder.amount?.toStringAsFixed(0);
        if (amount != null) {
          return '${reminder.title} ₹$amount due';
        }
        return reminder.title;
      case ReminderType.insurance:
      case ReminderType.service:
      case ReminderType.custom:
        return reminder.title;
    }
  }

  String _categoryForReminder(Reminder reminder) {
    switch (reminder.type) {
      case ReminderType.loan:
        return 'loanDue';
      case ReminderType.credit:
        return 'creditDue';
      case ReminderType.salary:
        return 'salaryReminder';
      case ReminderType.emi:
        return 'emiPayment';
      case ReminderType.insurance:
      case ReminderType.service:
        return 'subscriptionAlerts';
      case ReminderType.lending:
      case ReminderType.custom:
        return 'expenseReminder';
    }
  }

  String _notificationTitle(Reminder reminder, {bool upcoming = false}) {
    switch (reminder.type) {
      case ReminderType.salary:
        return 'Salary Expected Today';
      case ReminderType.credit:
        return upcoming
            ? 'Credit Card Payment Due Soon'
            : 'Credit Card Payment Due';
      case ReminderType.loan:
      case ReminderType.emi:
        return upcoming ? 'EMI Due Soon' : 'EMI Due';
      case ReminderType.insurance:
      case ReminderType.service:
        return upcoming ? 'Renewal Reminder' : 'Renewal Due';
      case ReminderType.lending:
        return upcoming ? 'Return Due Soon' : 'Return Due';
      case ReminderType.custom:
        return upcoming ? 'Upcoming Reminder' : 'Reminder Due';
    }
  }

  int _notificationIdFor(String reminderId, String phase) =>
      '${reminderId}_$phase'.hashCode & 0x7FFFFFFF;

  Future<void> _cancelReminderSchedules(String reminderId) async {
    await _plugin.cancel(id: _notificationIdFor(reminderId, 'upcoming'));
    await _plugin.cancel(id: _notificationIdFor(reminderId, 'due'));
  }

  DateTime _scheduleAt(DateTime source, int hour, int minute) {
    return DateTime(source.year, source.month, source.day, hour, minute);
  }

  int _parseReminderHour(String reminderTime) {
    final parts = reminderTime.split(':');
    return parts.length == 2 ? int.tryParse(parts[0]) ?? 9 : 9;
  }

  int _parseReminderMinute(String reminderTime) {
    final parts = reminderTime.split(':');
    return parts.length == 2 ? int.tryParse(parts[1]) ?? 0 : 0;
  }

  int _allocateEphemeralId() {
    _nextEphemeralId++;
    if (_nextEphemeralId > 499999) {
      _nextEphemeralId = 400000;
    }
    return _nextEphemeralId;
  }

  Future<void> _drainPopupQueue() async {
    if (_isShowingPopup || _popupQueue.isEmpty) return;
    _isShowingPopup = true;

    while (_popupQueue.isNotEmpty) {
      final alert = _popupQueue.removeAt(0);
      if (!alert.context.mounted) {
        continue;
      }

      await showDialog<void>(
        context: alert.context,
        barrierDismissible: true,
        builder: (context) => _ReminderAlertDialog(
          reminder: alert.reminder,
          onMarkDone: alert.onMarkDone,
          onSnooze: alert.onSnooze,
          onViewDetails: alert.onViewDetails,
        ),
      );
    }

    _isShowingPopup = false;
  }
}

class _QueuedReminderAlert {
  const _QueuedReminderAlert({
    required this.reminder,
    required this.context,
    this.onMarkDone,
    this.onSnooze,
    this.onViewDetails,
  });

  final Reminder reminder;
  final BuildContext context;
  final Future<void> Function()? onMarkDone;
  final Future<void> Function(Duration)? onSnooze;
  final VoidCallback? onViewDetails;
}

class _SnoozeTile extends StatelessWidget {
  const _SnoozeTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.duration,
  });

  final IconData icon;
  final String label;
  final Duration? duration;
  final Function(Duration?) onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: cs.primary, size: 20),
      ),
      title: Text(
        label,
        style: TextStyle(
          color: cs.onSurface,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: () => onTap(duration),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

class _ReminderAlertDialog extends StatelessWidget {
  const _ReminderAlertDialog({
    required this.reminder,
    this.onMarkDone,
    this.onSnooze,
    this.onViewDetails,
  });

  final Reminder reminder;
  final Future<void> Function()? onMarkDone;
  final Future<void> Function(Duration)? onSnooze;
  final VoidCallback? onViewDetails;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final statusColor = switch (reminder.status) {
      ReminderStatus.overdue => cs.error,
      ReminderStatus.dueToday => Colors.orange,
      ReminderStatus.upcoming => Colors.amber,
      ReminderStatus.inactive => cs.outline,
    };

    final icon = switch (reminder.type) {
      ReminderType.salary => Icons.work_rounded,
      ReminderType.loan || ReminderType.emi => Icons.account_balance_rounded,
      ReminderType.credit => Icons.credit_card_rounded,
      ReminderType.service ||
      ReminderType.insurance => Icons.directions_car_rounded,
      ReminderType.lending => Icons.handshake_rounded,
      ReminderType.custom => Icons.notifications_active_rounded,
    };

    final accentColor = switch (reminder.type) {
      ReminderType.salary => Colors.blue,
      ReminderType.loan || ReminderType.emi => Colors.orange,
      ReminderType.credit => Colors.purple,
      ReminderType.service || ReminderType.insurance => Colors.green,
      ReminderType.lending => Colors.yellow.shade800,
      ReminderType.custom => cs.primary,
    };

    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutBack,
      tween: Tween(begin: 0.0, end: 1.0),
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 40 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 30,
                offset: const Offset(0, 15),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(icon, color: accentColor),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          reminder.type.name.toUpperCase(),
                          style: TextStyle(
                            color: accentColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          'Reminder Due',
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (reminder.amount != null) ...[
                Text(
                  '₹${reminder.amount!.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                reminder.title,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (reminder.notes != null && reminder.notes!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  reminder.notes!,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event_rounded, size: 14, color: statusColor),
                    const SizedBox(width: 6),
                    Text(
                      reminder.status.name.toUpperCase(),
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              PrimaryActionButton(
                label: 'Mark as Done',
                icon: Icons.check_rounded,
                hapticType: SpendXHapticType.success,
                onPressed: () async {
                  Navigator.of(context).pop();
                  await onMarkDone?.call();
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        HapticService.instance.selection();
                        await _showSnoozeBottomSheet(context);
                      },
                      child: const Text('Snooze'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        foregroundColor: cs.onSurfaceVariant,
                      ),
                      child: const Text('Dismiss'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSnoozeBottomSheet(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;

    final Duration? selectedDuration = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                'Snooze Reminder',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              _SnoozeTile(
                icon: Icons.access_time_rounded,
                label: 'In 1 Hour',
                duration: const Duration(hours: 1),
                onTap: (d) => Navigator.pop(context, d),
              ),
              _SnoozeTile(
                icon: Icons.wb_sunny_rounded,
                label: 'Tomorrow Morning',
                duration: _calculateTomorrowMorning(),
                onTap: (d) => Navigator.pop(context, d),
              ),
              _SnoozeTile(
                icon: Icons.next_plan_rounded,
                label: 'Next Week',
                duration: const Duration(days: 7),
                onTap: (d) => Navigator.pop(context, d),
              ),
              _SnoozeTile(
                icon: Icons.event_available_rounded,
                label: 'Custom Time',
                onTap: (_) async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.now(),
                  );
                  if (time != null) {
                    final now = DateTime.now();
                    var scheduled = DateTime(
                      now.year,
                      now.month,
                      now.day,
                      time.hour,
                      time.minute,
                    );
                    if (scheduled.isBefore(now)) {
                      scheduled = scheduled.add(const Duration(days: 1));
                    }
                    if (context.mounted) {
                      Navigator.pop(context, scheduled.difference(now));
                    }
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );

    if (selectedDuration != null && context.mounted) {
      Navigator.of(context).pop();
      await onSnooze?.call(selectedDuration);
    }
  }

  Duration _calculateTomorrowMorning() {
    final now = DateTime.now();
    final nextTrig = DateTime(now.year, now.month, now.day + 1, 9, 0);
    return nextTrig.difference(now);
  }
}
