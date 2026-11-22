import 'dart:async';
import 'sms_live_channel_bridge.dart';

class DynamicIslandEvent {
  final String amount;
  final bool isExpense;
  final String title;
  final String subtitle;
  final DateTime timestamp;

  const DynamicIslandEvent({
    required this.amount,
    required this.isExpense,
    this.title = 'SpendX',
    this.subtitle = '',
    required this.timestamp,
  });
}

/// Dynamic Island service - decommissioned per user request to eliminate
/// overlay crashes, WindowManager bugs, and notification listener interference.
class DynamicIslandService {
  DynamicIslandService._() {
    SmsLiveChannelBridge.instance.registerIslandCardClickHandler((args) {
      if (args != null) {
        final event = DynamicIslandEvent(
          amount: args['amount']?.toString() ?? '',
          isExpense: args['isExpense'] == true,
          title: args['title']?.toString() ?? 'SpendX',
          subtitle: args['subtitle']?.toString() ?? '',
          timestamp: DateTime.now(),
        );
        _controller.add(event);
        _cardClickController.add(event);
      }
    });
  }
  static final DynamicIslandService instance = DynamicIslandService._();

  final _controller = StreamController<DynamicIslandEvent>.broadcast();
  Stream<DynamicIslandEvent> get events => _controller.stream;

  final _cardClickController = StreamController<DynamicIslandEvent>.broadcast();
  Stream<DynamicIslandEvent> get cardClicks => _cardClickController.stream;

  Future<bool> hasOverlayPermission() async => false;

  Future<void> requestOverlayPermission() async {}

  Future<void> show({
    required String amount,
    required bool isExpense,
    String title = 'SpendX',
    String subtitle = '',
  }) async {
    final event = DynamicIslandEvent(
      amount: amount,
      isExpense: isExpense,
      title: title,
      subtitle: subtitle,
      timestamp: DateTime.now(),
    );
    _controller.add(event);
  }
}
