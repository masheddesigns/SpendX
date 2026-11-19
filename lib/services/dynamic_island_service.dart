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

class DynamicIslandService {
  DynamicIslandService._() {
    _initNativeBridge();
  }
  static final DynamicIslandService instance = DynamicIslandService._();

  final _controller = StreamController<DynamicIslandEvent>.broadcast();
  Stream<DynamicIslandEvent> get events => _controller.stream;

  DynamicIslandEvent? _pendingCardClick;
  late final StreamController<DynamicIslandEvent> _cardClickController =
      StreamController<DynamicIslandEvent>.broadcast(onListen: () {
    final pending = _pendingCardClick;
    if (pending != null) {
      _pendingCardClick = null;
      scheduleMicrotask(() {
        if (!_cardClickController.isClosed) {
          _cardClickController.add(pending);
        }
      });
    }
  });

  Stream<DynamicIslandEvent> get cardClicks => _cardClickController.stream;

  void _initNativeBridge() {
    SmsLiveChannelBridge.instance.registerIslandCardClickHandler((args) {
      if (args != null) {
        final event = DynamicIslandEvent(
          amount: args['amount']?.toString() ?? '',
          isExpense: (args['isExpense'] as bool?) ?? true,
          title: args['title']?.toString() ?? 'SpendX',
          subtitle: args['subtitle']?.toString() ?? '',
          timestamp: DateTime.now(),
        );
        if (_cardClickController.hasListener) {
          _cardClickController.add(event);
        } else {
          _pendingCardClick = event;
        }
      }
    });

    SmsLiveChannelBridge.instance.registerDynamicIslandEventHandler((args) {
      if (args != null) {
        final event = DynamicIslandEvent(
          amount: args['amount']?.toString() ?? '',
          isExpense: (args['isExpense'] as bool?) ?? true,
          title: args['title']?.toString() ?? 'SpendX',
          subtitle: args['subtitle']?.toString() ?? '',
          timestamp: DateTime.now(),
        );
        _controller.add(event);
      }
    });
  }

  Future<bool> hasOverlayPermission() async {
    try {
      final res = await SmsLiveChannelBridge.instance.invokeMethod<bool>('hasOverlayPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestOverlayPermission() async {
    try {
      await SmsLiveChannelBridge.instance.invokeMethod('requestOverlayPermission');
    } catch (_) {}
  }

  /// Triggers the Dynamic Island animation across both native Android overlay
  /// and the in-app camera cutout HUD.
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

    // 1. Notify in-app HUD listener
    _controller.add(event);

    // 2. Trigger native Android overlay if supported
    try {
      await SmsLiveChannelBridge.instance.invokeMethod('showDynamicIsland', {
        'title': title,
        'amount': amount,
        'isExpense': isExpense,
        'subtitle': subtitle,
      });
    } catch (_) {}
  }
}
