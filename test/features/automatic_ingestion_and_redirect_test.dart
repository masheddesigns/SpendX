import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/features/ingestion/providers/ingestion_providers.dart';
import 'package:spend_x/services/notification_service_v2.dart';

void main() {
  group('Automatic Ingestion Status & Model Tests', () {
    test('needsAttention is true when notification listener is disabled', () {
      const status = AutomaticIngestionStatus(
        isLiveSmsEnabled: true,
        hasSmsPermission: true,
        isNotificationListenerEnabled: false,
        isBatteryOptimizationIgnored: true,
      );

      expect(status.isFullyActive, isFalse);
      expect(status.needsAttention, isTrue);
      expect(status.statusTitle, equals('Notification Access Needed'));
      expect(status.statusSubtitle, contains('Enable Notification Access'));
    });

    test('needsAttention is true when SMS permission is missing', () {
      const status = AutomaticIngestionStatus(
        isLiveSmsEnabled: true,
        hasSmsPermission: false,
        isNotificationListenerEnabled: true,
        isBatteryOptimizationIgnored: true,
      );

      expect(status.isFullyActive, isFalse);
      expect(status.needsAttention, isTrue);
      expect(status.statusTitle, equals('SMS Permission Needed'));
      expect(status.statusSubtitle, contains('Grant SMS permission'));
    });

    test('needsAttention is true when both are missing', () {
      const status = AutomaticIngestionStatus(
        isLiveSmsEnabled: true,
        hasSmsPermission: false,
        isNotificationListenerEnabled: false,
        isBatteryOptimizationIgnored: false,
      );

      expect(status.isFullyActive, isFalse);
      expect(status.needsAttention, isTrue);
      expect(status.statusTitle, equals('Setup Required'));
    });

    test('isFullyActive is true when all primary channels are authorized', () {
      const status = AutomaticIngestionStatus(
        isLiveSmsEnabled: true,
        hasSmsPermission: true,
        isNotificationListenerEnabled: true,
        isBatteryOptimizationIgnored: true,
        todayIngestedCount: 3,
      );

      expect(status.isFullyActive, isTrue);
      expect(status.needsAttention, isFalse);
      expect(status.statusTitle, equals('Active & Listening'));
      expect(status.statusSubtitle, equals('3 transactions auto-captured today'));
    });
  });

  group('Transaction Notification Payload & Redirection Tests', () {
    test('transaction notification payload encodes source_type and transaction_id', () {
      const txId = 'test_tx_uuid_9999';
      final payloadStr = jsonEncode({
        'source_type': 'transaction',
        'source_id': txId,
        'transaction_id': txId,
      });

      final decoded = jsonDecode(payloadStr) as Map<String, dynamic>;
      expect(decoded['source_type'], equals('transaction'));
      expect(decoded['source_id'], equals(txId));
      expect(decoded['transaction_id'], equals(txId));
    });

    test('NotificationServiceV2 singleton initialized and supports cold-start checking', () async {
      final notifService = NotificationServiceV2();
      expect(notifService, isNotNull);

      // Verify checking pending launch doesn't crash even if null
      await notifService.checkAndRoutePendingLaunchNotification();
    });
  });
}
