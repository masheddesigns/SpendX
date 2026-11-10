import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/tracked_database_task_queue.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('spendx/process_lock');
  final List<String> channelInvocations = [];
  final Map<String, dynamic> activeTickets = {};
  bool admissionClosed = false;

  setUp(() {
    channelInvocations.clear();
    activeTickets.clear();
    admissionClosed = false;

    // Reset Gate & TaskQueue
    DatabaseAccessGate.instanceForTesting = DatabaseAccessGate();
    TrackedDatabaseTaskQueue.instance.resetForTesting();
    PlatformProcessLockService.instanceForTesting = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      channelInvocations.add(call.method);
      switch (call.method) {
        case 'acquireOperationTicket':
          if (admissionClosed) {
            throw PlatformException(
              code: 'ADMISSION_CLOSED',
              message: 'Admission closed for restore',
            );
          }
          final ticketId = 'ticket_${DateTime.now().microsecondsSinceEpoch}';
          final tag = call.arguments['tag'] as String? ?? 'generic_op';
          final engineId = call.arguments['engineId'] as String? ?? 'bound_bg_engine_1';
          activeTickets[ticketId] = {'tag': tag, 'engineId': engineId};
          return {
            'status': 'ok',
            'ticketId': ticketId,
            'tag': tag,
            'engineId': engineId,
          };
        case 'releaseOperationTicket':
          final ticketId = call.arguments['ticketId'] as String?;
          final callerEngineId = call.arguments['engineId'] as String?;
          if (ticketId == null || !activeTickets.containsKey(ticketId)) {
            return {'status': 'stale'};
          }
          final ticketData = activeTickets[ticketId];
          final storedEngineId = ticketData is Map ? ticketData['engineId'] as String? : null;
          if (callerEngineId != null && storedEngineId != null && storedEngineId != callerEngineId) {
            throw PlatformException(
              code: 'CROSS_ENGINE_RELEASE_PROHIBITED',
              message: 'Ticket belongs to $storedEngineId, caller is $callerEngineId',
            );
          }
          activeTickets.remove(ticketId);
          return {'status': 'ok'};
        case 'acquireForegroundLease':
          return {'status': 'ok', 'leaseToken': 'test_fg_lease'};
        case 'releaseForegroundLease':
          return {'status': 'ok'};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PlatformProcessLockService.instanceForTesting = null;
    TrackedDatabaseTaskQueue.instance.resetForTesting();
  });

  group('Milestone 4.5A.2.5 — notificationTapBackground Native Ticket Protocol', () {
    test('1. Valid live choice notification acquires native ticket and releases in finally', () async {
      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_test_123',
        }),
      );

      await notificationTapBackground(response);

      // Verify channel calls
      expect(channelInvocations, contains('acquireOperationTicket'));
      expect(channelInvocations, contains('releaseOperationTicket'));
      expect(activeTickets.isEmpty, isTrue, reason: 'Ticket must be released in finally');
    });

    test('2. Income action executes with liveIncomeAction and releases ticket', () async {
      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveIncomeAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_test_456',
        }),
      );

      await notificationTapBackground(response);

      expect(channelInvocations, contains('acquireOperationTicket'));
      expect(channelInvocations, contains('releaseOperationTicket'));
      expect(activeTickets.isEmpty, isTrue);
    });

    test('3. Fail-closed guarantee: when ticket acquisition throws ADMISSION_CLOSED, abort immediately', () async {
      admissionClosed = true;

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_test_closed',
        }),
      );

      // Must not throw unhandled exception to the engine
      await notificationTapBackground(response);

      // Verify that ticket acquisition was attempted, rejected, and no release was attempted
      expect(channelInvocations, ['acquireOperationTicket']);
      expect(channelInvocations.contains('releaseOperationTicket'), isFalse);
      expect(TrackedDatabaseTaskQueue.instance.activeTaskCount, 0);
    });

    test('4. Fail-closed guarantee: when ticket acquisition encounters platform error, abort immediately', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        channelInvocations.add(call.method);
        if (call.method == 'acquireOperationTicket') {
          throw PlatformException(code: 'NATIVE_ERROR', message: 'Process lock failure');
        }
        return null;
      });

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_test_err',
        }),
      );

      await notificationTapBackground(response);

      expect(channelInvocations, ['acquireOperationTicket']);
      expect(channelInvocations.contains('releaseOperationTicket'), isFalse);
      expect(TrackedDatabaseTaskQueue.instance.activeTaskCount, 0);
    });

    test('5. Safe release: ticket is released even if Gate is closed during task queue run', () async {
      // Gate is closed, so TrackedDatabaseTaskQueue.run throws DatabaseGateClosedException
      final closedGate = DatabaseAccessGate();
      await closedGate.closeAdmissionAndDrain(); // Put gate in closed state
      DatabaseAccessGate.instanceForTesting = closedGate;

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_test_gate_closed',
        }),
      );

      await notificationTapBackground(response);

      // Ticket was acquired and STILL released cleanly via finally
      expect(channelInvocations, contains('acquireOperationTicket'));
      expect(channelInvocations, contains('releaseOperationTicket'));
      expect(activeTickets.isEmpty, isTrue, reason: 'Ticket must not be leaked on gate closure');
    });

    test('6. Non-matching notifications do not acquire ticket or touch database', () async {
      // Case A: Different action ID
      final responseA = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: 'some_other_action',
        payload: jsonEncode({'source_type': 'live_choice', 'review_id': 'rev_1'}),
      );
      await notificationTapBackground(responseA);
      expect(channelInvocations.isEmpty, isTrue);

      // Case B: Null payload
      final responseB = const NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: null,
      );
      await notificationTapBackground(responseB);
      expect(channelInvocations.isEmpty, isTrue);

      // Case C: Non-live_choice payload
      final responseC = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({'source_type': 'reminder', 'review_id': 'rev_1'}),
      );
      await notificationTapBackground(responseC);
      expect(channelInvocations.isEmpty, isTrue);

      // Case D: Missing or empty review_id
      final responseD = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({'source_type': 'live_choice', 'review_id': ''}),
      );
      await notificationTapBackground(responseD);
      expect(channelInvocations.isEmpty, isTrue);
    });

    test('7. Duplicate rapid taps acquire separate tickets and release cleanly without leakage', () async {
      final response1 = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({'source_type': 'live_choice', 'review_id': 'rev_tap_1'}),
      );
      final response2 = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveIncomeAction,
        payload: jsonEncode({'source_type': 'live_choice', 'review_id': 'rev_tap_2'}),
      );

      await Future.wait([
        notificationTapBackground(response1),
        notificationTapBackground(response2),
      ]);

      final acquires = channelInvocations.where((m) => m == 'acquireOperationTicket').length;
      final releases = channelInvocations.where((m) => m == 'releaseOperationTicket').length;

      expect(acquires, 2);
      expect(releases, 2);
      expect(activeTickets.isEmpty, isTrue);
    });

    test('8. Stale ticket release throws StaleTicketException but is safely caught in finally', () async {
      final lockService = PlatformProcessLockService();
      // Directly releasing a stale ticket throws StaleTicketException
      expect(
        () => lockService.releaseOperationTicket('nonexistent_ticket_999'),
        throwsA(isA<StaleTicketException>()),
      );

      // Now verify that if release throws StaleTicketException during notificationTapBackground,
      // the finally block safely swallows it with a warning and does not crash the background isolate.
      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_test_stale_release',
        }),
      );

      // Custom handler where releaseOperationTicket always returns stale
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'acquireOperationTicket') {
          return {'status': 'ok', 'ticketId': 'ticket_will_be_stale', 'tag': 'test'};
        }
        if (call.method == 'releaseOperationTicket') {
          return {'status': 'stale'};
        }
        return null;
      });

      // Must not throw
      await notificationTapBackground(response);
    });

    test('9. Restore drain blocks while background ticket is active', () async {
      final completer = Completer<void>();
      late String activeTicketId;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'acquireOperationTicket') {
          activeTicketId = 'holding_ticket_1';
          activeTickets[activeTicketId] = 'holding_task';
          return {'status': 'ok', 'ticketId': activeTicketId, 'tag': 'holding_task'};
        }
        if (call.method == 'releaseOperationTicket') {
          activeTickets.remove(call.arguments['ticketId']);
          return {'status': 'ok'};
        }
        if (call.method == 'beginExclusiveRestore') {
          // Native manager blocks until activeTickets is empty
          if (activeTickets.isNotEmpty) {
            await completer.future.timeout(const Duration(milliseconds: 500));
          }
          return {'status': 'ok', 'restoreToken': 'restore_token_1'};
        }
        return null;
      });

      // 1. Acquire ticket
      final ticket = await PlatformProcessLockService.instance.acquireOperationTicket(
        engineId: 'test_engine',
        tag: 'holding_task',
      );
      expect(activeTickets.containsKey(ticket.ticketId), isTrue);

      // 2. Restore attempt should wait or time out if ticket not released
      bool restoreStarted = false;
      unawaited(
        PlatformProcessLockService.instance.beginExclusiveRestore().then((_) {
          restoreStarted = true;
        }),
      );

      // Allow microtasks to run
      await Future.delayed(const Duration(milliseconds: 20));
      expect(restoreStarted, isFalse, reason: 'Restore cannot start while background ticket is active');

      // 3. Release ticket
      await PlatformProcessLockService.instance.releaseOperationTicket(ticket.ticketId);
      completer.complete();

      await Future.delayed(const Duration(milliseconds: 20));
      expect(restoreStarted, isTrue, reason: 'Restore proceeds after background ticket is released');
    });

    test('10. Fail-closed guarantee: when process_lock channel is missing (MissingPluginException), abort immediately without database access', () async {
      // Unregister handler so invoking the method channel triggers MissingPluginException
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_test_missing_plugin',
        }),
      );

      // Must abort immediately without throwing unhandled error or touching database
      await notificationTapBackground(response);

      expect(TrackedDatabaseTaskQueue.instance.activeTaskCount, 0);
    });

    test('11. Lifecycle engine binding & cross-engine release protection', () async {
      final ticket = await PlatformProcessLockService.instance.acquireOperationTicket(
        engineId: 'engine_alpha',
        tag: 'alpha_task',
      );
      expect(ticket.engineId, 'engine_alpha');

      // Attempt release with different engineId -> throws CrossEngineReleaseException
      expect(
        () => PlatformProcessLockService.instance.releaseOperationTicket(
          ticket.ticketId,
          engineId: 'engine_beta',
        ),
        throwsA(isA<CrossEngineReleaseException>()),
      );

      // Legitimate release with matching engineId -> succeeds
      final ok = await PlatformProcessLockService.instance.releaseOperationTicket(
        ticket.ticketId,
        engineId: 'engine_alpha',
      );
      expect(ok, isTrue);
    });
  });
}
