import 'dart:async';
import 'package:flutter/services.dart';

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
  DynamicIslandService._();
  static final DynamicIslandService instance = DynamicIslandService._();

  static const _channel = MethodChannel('com.mashingdesigns.spend_x/sms');

  final _controller = StreamController<DynamicIslandEvent>.broadcast();
  Stream<DynamicIslandEvent> get events => _controller.stream;

  Future<bool> hasOverlayPermission() async {
    try {
      final res = await _channel.invokeMethod<bool>('hasOverlayPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestOverlayPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
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
      await _channel.invokeMethod('showDynamicIsland', {
        'title': title,
        'amount': amount,
        'isExpense': isExpense,
        'subtitle': subtitle,
      });
    } catch (_) {}
  }
}
