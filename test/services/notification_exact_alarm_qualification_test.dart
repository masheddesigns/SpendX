import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/models/notification_settings.dart';
import 'package:spend_x/models/reminder_model.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/notification_settings_service.dart';

void main() {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  TestWidgetsFlutterBinding.ensureInitialized();

  const notifChannel = MethodChannel('dexterous.com/flutter/local_notifications');
  const tzChannel = MethodChannel('flutter_timezone');

  final List<MethodCall> notifLog = [];
  bool exactAlarmGranted = true;
  bool throwOnExactSchedule = false;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    notifLog.clear();
    exactAlarmGranted = true;
    throwOnExactSchedule = false;
    SharedPreferences.setMockInitialValues({});

    // Save default enabled notification settings
    final settingsService = NotificationSettingsService();
    await settingsService.save(
      NotificationSettings(
        expenseReminder: true,
        loanDue: true,
        creditDue: true,
        salaryReminder: true,
        emiPayment: true,
      ),
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(tzChannel, (MethodCall call) async {
      if (call.method == 'getLocalTimezone') {
        return 'UTC';
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, (MethodCall call) async {
      notifLog.add(call);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'canScheduleExactNotifications':
          return exactAlarmGranted;
        case 'requestExactAlarmsPermission':
          exactAlarmGranted = true;
          return true;
        case 'requestNotificationsPermission':
          return true;
        case 'cancel':
        case 'cancelAll':
          return null;
        case 'zonedSchedule':
          final args = call.arguments as Map<dynamic, dynamic>? ?? {};
          final platformSpecifics =
              args['platformSpecifics'] as Map<dynamic, dynamic>? ?? {};
          final scheduleMode = platformSpecifics['scheduleMode'] as String?;

          if (scheduleMode == 'exactAllowWhileIdle' &&
              (throwOnExactSchedule || !exactAlarmGranted)) {
            throw PlatformException(
              code: 'exact_alarms_not_permitted',
              message:
                  'Exact alarms not permitted. The SCHEDULE_EXACT_ALARM permission is required.',
            );
          }
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(tzChannel, null);
  });

  group('Phase 5A: Exact Alarm Permission & Degradation Qualification', () {
    test('1. canScheduleExactAlarms reflects permission status', () async {
      final service = NotificationServiceV2();
      exactAlarmGranted = true;
      expect(await service.canScheduleExactAlarms(), isTrue);

      exactAlarmGranted = false;
      expect(await service.canScheduleExactAlarms(), isFalse);
    });

    test('2. Permission granted -> schedules with exactAllowWhileIdle', () async {
      final service = NotificationServiceV2();
      exactAlarmGranted = true;
      throwOnExactSchedule = false;

      final futureDate = DateTime.now().add(const Duration(days: 3));
      await service.scheduleNotification(
        id: 101,
        title: 'Exact Test',
        body: 'Testing exact alarm',
        scheduledDate: futureDate,
      );

      final scheduleCalls =
          notifLog.where((c) => c.method == 'zonedSchedule').toList();
      expect(scheduleCalls, hasLength(1));

      final args = scheduleCalls.first.arguments as Map<dynamic, dynamic>;
      final platformSpecifics =
          args['platformSpecifics'] as Map<dynamic, dynamic>;
      expect(platformSpecifics['scheduleMode'], equals('exactAllowWhileIdle'));
    });

    test('3. Permission denied -> proactively degrades to inexactAllowWhileIdle', () async {
      final service = NotificationServiceV2();
      exactAlarmGranted = false;
      throwOnExactSchedule = false;

      final futureDate = DateTime.now().add(const Duration(days: 3));
      await service.scheduleNotification(
        id: 102,
        title: 'Inexact Fallback Test',
        body: 'Testing proactive inexact fallback',
        scheduledDate: futureDate,
      );

      final scheduleCalls =
          notifLog.where((c) => c.method == 'zonedSchedule').toList();
      expect(scheduleCalls, hasLength(1));

      final args = scheduleCalls.first.arguments as Map<dynamic, dynamic>;
      final platformSpecifics =
          args['platformSpecifics'] as Map<dynamic, dynamic>;
      expect(platformSpecifics['scheduleMode'], equals('inexactAllowWhileIdle'));
    });

    test('4. Permission revoked at runtime -> catches PlatformException and degrades safely', () async {
      final service = NotificationServiceV2();
      // Suppose check passed or race condition occurred, so exact is attempted but throws
      exactAlarmGranted = true;
      throwOnExactSchedule = true;

      final futureDate = DateTime.now().add(const Duration(days: 3));
      // Should not throw or crash
      await expectLater(
        service.scheduleNotification(
          id: 103,
          title: 'Revoked Test',
          body: 'Testing runtime revocation handling',
          scheduledDate: futureDate,
        ),
        completes,
      );

      final scheduleCalls =
          notifLog.where((c) => c.method == 'zonedSchedule').toList();
      // First attempt with exactAllowWhileIdle failed, second attempt with inexactAllowWhileIdle succeeded
      expect(scheduleCalls, hasLength(2));

      final firstCallSpecs = (scheduleCalls[0].arguments
          as Map<dynamic, dynamic>)['platformSpecifics'] as Map<dynamic, dynamic>;
      final secondCallSpecs = (scheduleCalls[1].arguments
          as Map<dynamic, dynamic>)['platformSpecifics'] as Map<dynamic, dynamic>;

      expect(firstCallSpecs['scheduleMode'], equals('exactAllowWhileIdle'));
      expect(secondCallSpecs['scheduleMode'], equals('inexactAllowWhileIdle'));
    });

    test('5. Bill reminder scheduling under both permission states', () async {
      final service = NotificationServiceV2();
      final billReminder = Reminder(
        id: 'bill_card_1',
        title: 'HDFC Credit Card Bill',
        amount: 15400.0,
        dueDate: DateTime.now().add(const Duration(days: 5)),
        type: ReminderType.credit,
        status: ReminderStatus.upcoming,
        recordStatus: ReminderRecordStatus.pending,
      );

      // Case A: Permission Granted
      exactAlarmGranted = true;
      throwOnExactSchedule = false;
      notifLog.clear();

      await service.syncNotificationsFromDB([billReminder]);
      final callsGranted =
          notifLog.where((c) => c.method == 'zonedSchedule').toList();
      // 2 notifications: upcoming (2 days before) and due day
      expect(callsGranted, hasLength(2));
      for (final call in callsGranted) {
        final specs = (call.arguments
            as Map<dynamic, dynamic>)['platformSpecifics'] as Map<dynamic, dynamic>;
        expect(specs['scheduleMode'], equals('exactAllowWhileIdle'));
      }

      // Case B: Permission Denied
      exactAlarmGranted = false;
      throwOnExactSchedule = false;
      notifLog.clear();

      await service.syncNotificationsFromDB([billReminder]);
      final callsDenied =
          notifLog.where((c) => c.method == 'zonedSchedule').toList();
      expect(callsDenied, hasLength(2));
      for (final call in callsDenied) {
        final specs = (call.arguments
            as Map<dynamic, dynamic>)['platformSpecifics'] as Map<dynamic, dynamic>;
        expect(specs['scheduleMode'], equals('inexactAllowWhileIdle'));
      }
    });

    test('6. EMI reminder scheduling degrades safely without state corruption', () async {
      final service = NotificationServiceV2();
      final emiReminder = Reminder(
        id: 'loan_emi_101',
        title: 'Home Loan EMI',
        amount: 32500.0,
        dueDate: DateTime.now().add(const Duration(days: 4)),
        type: ReminderType.emi,
        status: ReminderStatus.upcoming,
        recordStatus: ReminderRecordStatus.pending,
      );

      // Test with permission revoked (throwing on exact)
      exactAlarmGranted = true;
      throwOnExactSchedule = true;
      notifLog.clear();

      await expectLater(
        service.syncNotificationsFromDB([emiReminder]),
        completes,
      );

      final calls = notifLog.where((c) => c.method == 'zonedSchedule').toList();
      // 2 reminders scheduled (each attempted exact once, then fell back to inexact) = 4 calls
      expect(calls, hasLength(4));

      final fallbackUpcoming = (calls[1].arguments
          as Map<dynamic, dynamic>)['platformSpecifics'] as Map<dynamic, dynamic>;
      final fallbackDue = (calls[3].arguments
          as Map<dynamic, dynamic>)['platformSpecifics'] as Map<dynamic, dynamic>;

      expect(fallbackUpcoming['scheduleMode'], equals('inexactAllowWhileIdle'));
      expect(fallbackDue['scheduleMode'], equals('inexactAllowWhileIdle'));
    });

    test('7. Daily expense reminder degrades gracefully on revoked permission', () async {
      final service = NotificationServiceV2();
      exactAlarmGranted = true;
      throwOnExactSchedule = true;
      notifLog.clear();

      await expectLater(
        service.scheduleDailyReminder(hour: 20, minute: 30),
        completes,
      );

      final calls = notifLog.where((c) => c.method == 'zonedSchedule').toList();
      expect(calls.length, greaterThanOrEqualTo(2));
      final lastSpecs = (calls.last.arguments
          as Map<dynamic, dynamic>)['platformSpecifics'] as Map<dynamic, dynamic>;
      expect(lastSpecs['scheduleMode'], equals('inexactAllowWhileIdle'));
    });
  });
}
