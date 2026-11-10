import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/platform_process_lock_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 4.5A.2.5 — Real Android Device Native Process Lock & Background Ticket E2E Suite', () {
    testWidgets('1. Native MethodChannel attaches and acquires foreground lease on device', (tester) async {
      final token = await PlatformProcessLockService.instance.acquireForegroundLease(engineId: 'e2e_engine');
      try {
        expect(token, isNotEmpty);

        final status = await PlatformProcessLockService.instance.getLockStatus();
        expect(status['state'], equals('OPEN'));
        expect(status['activeReadersCount'], greaterThanOrEqualTo(1));
      } finally {
        final released = await PlatformProcessLockService.instance.releaseForegroundLease(
          leaseToken: token,
          engineId: 'e2e_engine',
        );
        expect(released, isTrue);
      }
    });

    testWidgets('2. Native operation ticket acquires, bounds lifecycle engineId, and releases on device', (tester) async {
      final ticket = await PlatformProcessLockService.instance.acquireOperationTicket(tag: 'e2e_op_test');
      expect(ticket.ticketId, isNotEmpty);
      expect(ticket.tag, equals('e2e_op_test'));
      expect(ticket.engineId, isNotNull);
      expect(ticket.engineId, contains('engine_'));

      final ok = await PlatformProcessLockService.instance.releaseOperationTicket(
        ticket.ticketId,
        engineId: ticket.engineId,
      );
      expect(ok, isTrue);

      // Re-releasing same ticket is rejected as stale
      expect(
        () => PlatformProcessLockService.instance.releaseOperationTicket(
          ticket.ticketId,
          engineId: ticket.engineId,
        ),
        throwsA(isA<StaleTicketException>()),
      );
    });

    testWidgets('3. Cross-engine ticket release is rejected by native manager on device', (tester) async {
      final ticket = await PlatformProcessLockService.instance.acquireOperationTicket(
        engineId: 'engine_alpha',
        tag: 'e2e_cross_test',
      );

      try {
        // Attempt release with unauthorized engine_beta
        expect(
          () => PlatformProcessLockService.instance.releaseOperationTicket(
            ticket.ticketId,
            engineId: 'engine_beta',
          ),
          throwsA(isA<CrossEngineReleaseException>()),
        );
      } finally {
        // Clean release with authorized engine_alpha
        final ok = await PlatformProcessLockService.instance.releaseOperationTicket(
          ticket.ticketId,
          engineId: 'engine_alpha',
        );
        expect(ok, isTrue);
      }
    });

    testWidgets('4. notificationTapBackground executes under native ticket protocol on device', (tester) async {
      final payload = jsonEncode({
        'source_type': 'live_choice',
        'review_id': 'rev_e2e_123',
      });

      final response = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        actionId: NotificationServiceV2.liveExpenseAction,
        payload: payload,
      );

      // Executes acquireOperationTicket -> TrackedDatabaseTaskQueue -> releaseOperationTicket
      await notificationTapBackground(response);

      final status = await PlatformProcessLockService.instance.getLockStatus();
      expect(status['state'], equals('OPEN'));
      // The background operation ticket was cleanly released in finally
      expect(status['activeTicketsCount'], equals(0));
    });

    testWidgets('5. Restore admission closure causes notificationTapBackground to fail closed on device', (tester) async {
      // 1. Drain database admission and release foreground lease
      await DatabaseAccessGate.instance.closeAdmissionAndDrain();

      // 2. Native restore begins exclusive mode
      final restoreToken = await PlatformProcessLockService.instance.beginExclusiveRestore();
      expect(restoreToken, isNotEmpty);

      try {
        final statusDuring = await PlatformProcessLockService.instance.getLockStatus();
        expect(statusDuring['state'], equals('EXCLUSIVE_HELD'));
        expect(statusDuring['exclusiveHeld'], isTrue);

        // 3. Attempting direct ticket acquisition throws DatabaseAdmissionClosedException
        expect(
          () => PlatformProcessLockService.instance.acquireOperationTicket(tag: 'during_restore'),
          throwsA(isA<DatabaseAdmissionClosedException>()),
        );

        final payload = jsonEncode({
          'source_type': 'live_choice',
          'review_id': 'rev_e2e_blocked',
        });

        final response = NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          actionId: NotificationServiceV2.liveExpenseAction,
          payload: payload,
        );

        // 4. Must fail closed without throwing unhandled error or accessing database
        await notificationTapBackground(response);
      } finally {
        // 5. Complete restore and reopen gate
        final completeOk = await PlatformProcessLockService.instance.completeExclusiveRestore(restoreToken);
        expect(completeOk, isTrue);
        DatabaseAccessGate.instance.reopenAdmission();
      }

      final statusAfter = await PlatformProcessLockService.instance.getLockStatus();
      expect(statusAfter['state'], equals('OPEN'));
      expect(statusAfter['exclusiveHeld'], isFalse);
      expect(statusAfter['activeTicketsCount'], equals(0));
    });
  });
}
