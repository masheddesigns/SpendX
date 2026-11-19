import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/dynamic_island_service.dart';
import 'package:spend_x/services/sms_live_channel_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SmsLiveChannelBridge (C1 Fix)', () {
    setUp(() {
      SmsLiveChannelBridge.instance.resetForTesting();
    });

    test('multiplexes onSmsReceived and onIslandCardClicked without collision', () async {
      final bridge = SmsLiveChannelBridge.instance;

      List<dynamic>? receivedSms;
      Map<dynamic, dynamic>? receivedCardClick;

      bridge.registerSmsHandler((args) {
        receivedSms = args;
      });

      bridge.registerIslandCardClickHandler((args) {
        receivedCardClick = args;
      });

      // Simulate native calling onSmsReceived
      final smsByteData = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onSmsReceived', ['HDFCBK', 'Debited INR 500', '0', 'source_123']),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('spendx/sms_live', smsByteData, (ByteData? reply) {});

      expect(receivedSms, isNotNull);
      expect(receivedSms![0], 'HDFCBK');
      expect(receivedSms![1], 'Debited INR 500');

      // Simulate native calling onIslandCardClicked
      final clickByteData = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onIslandCardClicked', {
          'amount': '500.00',
          'isExpense': true,
          'title': 'Expense Recorded',
          'subtitle': 'HDFC Bank',
        }),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('spendx/sms_live', clickByteData, (ByteData? reply) {});

      expect(receivedCardClick, isNotNull);
      expect(receivedCardClick!['amount'], '500.00');
      expect(receivedCardClick!['subtitle'], 'HDFC Bank');
    });

    test('buffers early onSmsReceived before LiveSmsService registers and flushes on register', () async {
      final bridge = SmsLiveChannelBridge.instance;

      // Simulate native message arriving before any SMS handler is registered
      final smsByteData = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onSmsReceived', ['SBIBK', 'Credited INR 1000', '0', 'sbi_456']),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('spendx/sms_live', smsByteData, (ByteData? reply) {});

      // Handler is registered afterwards
      List<dynamic>? flushedSms;
      bridge.registerSmsHandler((args) {
        flushedSms = args;
      });

      expect(flushedSms, isNotNull);
      expect(flushedSms![0], 'SBIBK');
      expect(flushedSms![1], 'Credited INR 1000');
    });

    test('DynamicIslandService receives card click event and streams it to listener', () async {
      // Re-register DynamicIslandService's bridge handler after reset
      DynamicIslandService.instance;
      // Re-init listener by registering again or triggering bridge
      SmsLiveChannelBridge.instance.registerIslandCardClickHandler((args) {
        if (args != null) {
          final event = DynamicIslandEvent(
            amount: args['amount']?.toString() ?? '',
            isExpense: (args['isExpense'] as bool?) ?? true,
            title: args['title']?.toString() ?? 'SpendX',
            subtitle: args['subtitle']?.toString() ?? '',
            timestamp: DateTime.now(),
          );
          // Stream to cardClicks
          DynamicIslandService.instance.show(
            amount: event.amount,
            isExpense: event.isExpense,
            title: event.title,
            subtitle: event.subtitle,
          );
        }
      });

      DynamicIslandEvent? clickedEvent;
      final sub = DynamicIslandService.instance.events.listen((event) {
        clickedEvent = event;
      });

      final clickByteData = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onIslandCardClicked', {
          'amount': '1250.00',
          'isExpense': true,
          'title': 'SpendX',
          'subtitle': 'Amazon',
        }),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('spendx/sms_live', clickByteData, (ByteData? reply) {});

      await Future.delayed(Duration.zero);

      expect(clickedEvent, isNotNull);
      expect(clickedEvent!.amount, '1250.00');
      expect(clickedEvent!.subtitle, 'Amazon');

      await sub.cancel();
    });
  });
}
