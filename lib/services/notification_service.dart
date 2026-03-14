import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('ic_notification');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(android: androidInit, iOS: darwinInit, macOS: darwinInit);

    await _plugin.initialize(settings: initSettings);
    _initialized = true;

    // Create high-importance channels for Android
    await _createNotificationChannels();

    // Heavy/Dynamic tasks run in background without blocking
    _initTimezonesAndReminders();
  }

  Future<void> _createNotificationChannels() async {
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final prefs = await SharedPreferences.getInstance();
      final sound = prefs.getString('reminder_sound') ?? 'default';
      
      AndroidNotificationChannel createChannel({
        required String id,
        required String name,
        required String description,
        Importance importance = Importance.high,
        bool playSound = true,
      }) {
        RawResourceAndroidNotificationSound? androidSound;
        if (sound != 'default') {
          androidSound = RawResourceAndroidNotificationSound(sound.toLowerCase().replaceAll(' ', '_'));
        }
        return AndroidNotificationChannel(
          id,
          name,
          description: description,
          importance: importance,
          playSound: playSound,
          sound: androidSound,
        );
      }

      await androidPlugin.createNotificationChannel(AndroidNotificationChannel(
        'spendx_backup',
        'SpendX Backups',
        description: 'Status of Google Drive backups',
        importance: Importance.low,
      ));
      
      await androidPlugin.createNotificationChannel(createChannel(
        id: 'spendx_alerts',
        name: 'SpendX Alerts',
        description: 'Instant transaction and budget alerts',
      ));
      
      await androidPlugin.createNotificationChannel(createChannel(
        id: 'spendx_reminders',
        name: 'SpendX Reminders',
        description: 'Payment due date reminders',
      ));
      
      await androidPlugin.createNotificationChannel(createChannel(
        id: 'spendx_periodic',
        name: 'Periodic Reminders',
        description: 'Daily / weekly / monthly check-in reminders',
        importance: Importance.defaultImportance,
      ));
      
      await androidPlugin.createNotificationChannel(createChannel(
        id: 'spendx_networth',
        name: 'Net Worth Updates',
        description: 'Weekly reminders to update your net worth',
      ));
    }
  }

  /// Re-create channels with new sound settings
  Future<void> updateNotificationSounds() async {
    await _createNotificationChannels();
  }

  Future<void> _initTimezonesAndReminders() async {
    try {
      tz_data.initializeTimeZones();
      final tzInfo = await FlutterTimezone.getLocalTimezone().timeout(const Duration(seconds: 3));
      String tzName = tzInfo.identifier;
      if (tzName == 'Asia/Calcutta') tzName = 'Asia/Kolkata';
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (e) {
      debugPrint('Timezone init non-critical error: $e');
    }
    
    try {
      await scheduleWeeklyNetWorthReminder();
    } catch (e) {
      debugPrint('Reminder schedule non-critical error: $e');
    }
  }

  Future<void> requestPermissions() async {
    try {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.requestNotificationsPermission();
        await androidPlugin.requestExactAlarmsPermission();
      }
      
      await _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (e) {
      debugPrint('Error requesting notification permissions: $e');
    }
  }

  Future<bool> get notificationsEnabled async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('notifications_enabled') ?? true;
  }

  Future<void> setNotificationsEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', value);
    if (!value) await cancelAll();
  }

  Future<int> get daysBefore async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('notification_days_before') ?? 3;
  }

  Future<void> setDaysBefore(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('notification_days_before', days);
  }

  /// Schedule a notification on a specific date
  Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    if (!await notificationsEnabled) return;
    if (scheduledDate.isBefore(DateTime.now())) return;

    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'spendx_reminders',
          'SpendX Reminders',
          channelDescription: 'Payment due date reminders',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(badgeNumber: 1),
        macOS: DarwinNotificationDetails(badgeNumber: 1),
      );

      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(scheduledDate, tz.local),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } on MissingPluginException catch (e) {
      debugPrint('MissingPluginException scheduling notification: $e');
    } catch (e) {
      debugPrint('Error scheduling notification: $e');
    }
  }

  Future<void> showInstant({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails('spendx_alerts', 'SpendX Alerts', importance: Importance.high),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      );
      await _plugin.show(id: id, title: title, body: body, notificationDetails: details);
    } on MissingPluginException catch (e) {
      debugPrint('MissingPluginException showing notification: $e');
    } catch (e) {
      debugPrint('Error showing instant notification: $e');
    }
  }

  Future<void> cancel(int id) async {
    try { await _plugin.cancel(id: id); } catch (_) {}
  }

  Future<void> schedulePeriodicReminder(String frequency, {int hour = 9, int minute = 0}) async {
    const int reminderId = 999;
    await cancel(reminderId);

    if (frequency == 'off') return;
    if (!await notificationsEnabled) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'spendx_periodic',
        'Periodic Reminders',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    const title = 'Time to update SpendX!';
    const body = 'Log your expenses, check your bank balance, and track your net worth.';

    try {
      final now = tz.TZDateTime.now(tz.local);

      if (frequency == 'daily') {
        // Schedule for specified time every day
        var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
        if (scheduledDate.isBefore(now)) {
          scheduledDate = scheduledDate.add(const Duration(days: 1));
        }
        await _plugin.zonedSchedule(
          id: reminderId,
          title: title,
          body: body,
          scheduledDate: scheduledDate,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time, // repeats daily at same time
        );
      } else if (frequency == 'weekly') {
        // Schedule for specified time every Monday
        var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
        while (scheduledDate.weekday != DateTime.monday || scheduledDate.isBefore(now)) {
          scheduledDate = scheduledDate.add(const Duration(days: 1));
        }
        await _plugin.zonedSchedule(
          id: reminderId,
          title: title,
          body: body,
          scheduledDate: scheduledDate,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime, // repeats weekly
        );
      } else if (frequency == 'monthly') {
        // Schedule for specified time on 1st of every month
        var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, 1, hour, minute);
        if (scheduledDate.isBefore(now)) {
          scheduledDate = tz.TZDateTime(tz.local, now.year, now.month + 1, 1, hour, minute);
        }
        await _plugin.zonedSchedule(
          id: reminderId,
          title: title,
          body: body,
          scheduledDate: scheduledDate,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime, // repeats monthly
        );
      }
    } catch (e) {
      debugPrint('Error scheduling periodic reminder: $e');
    }
  }

  Future<void> scheduleWeeklyNetWorthReminder({int hour = 10, int minute = 0}) async {
    const int netWorthReminderId = 1001;
    await cancel(netWorthReminderId);

    if (!await notificationsEnabled) return;

    final details = const NotificationDetails(
      android: AndroidNotificationDetails(
        'spendx_networth',
        'Net Worth Updates',
        channelDescription: 'Weekly reminders to update your net worth',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    // Schedule for every Sunday at specified time
    var now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    
    // Find next Sunday (weekday 7)
    while (scheduledDate.weekday != DateTime.sunday || scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    try {
      await _plugin.zonedSchedule(
        id: netWorthReminderId,
        title: 'Review your Net Worth',
        body: 'It\'s been a week! Update your bank balances and investments to see your progress.',
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    } catch (e) {
      debugPrint('Error scheduling weekly net worth reminder: $e');
    }
  }

  /// Show a notification when a cloud backup/upload starts
  Future<void> showBackupStarted() async {
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'spendx_backup',
          'SpendX Backups',
          channelDescription: 'Status of Google Drive backups',
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: 100,
          progress: 50,
          onlyAlertOnce: true,
          icon: 'ic_notification',
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      );
      await _plugin.show(
        id: 2001,
        title: '☁️ Uploading to cloud…',
        body: 'Backing up your SpendX data',
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('showBackupStarted error: $e');
    }
  }

  /// Show a notification when a cloud backup completes
  Future<void> showBackupComplete(bool success) async {
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          'spendx_backup',
          'SpendX Backups',
          channelDescription: 'Status of Google Drive backups',
          importance: success ? Importance.defaultImportance : Importance.high,
          priority: success ? Priority.defaultPriority : Priority.high,
          icon: 'ic_notification',
        ),
        iOS: const DarwinNotificationDetails(),
        macOS: const DarwinNotificationDetails(),
      );
      await _plugin.show(
        id: 2001,
        title: success ? '✅ Backup complete' : '❌ Backup failed',
        body: success
            ? 'Your data has been safely backed up to cloud'
            : 'Could not upload to cloud. Check your connection.',
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('showBackupComplete error: $e');
    }
  }

  Future<void> cancelAll() async {
    try { await _plugin.cancelAll(); } catch (_) {}
  }
}
