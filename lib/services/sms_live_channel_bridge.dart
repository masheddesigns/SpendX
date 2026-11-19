import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/logging/app_logger.dart';

typedef SmsReceivedCallback = FutureOr<void> Function(List<dynamic>? args);
typedef IslandEventCallback = FutureOr<void> Function(Map<dynamic, dynamic>? args);

/// Centralized MethodChannel dispatcher for 'spendx/sms_live'.
///
/// Prevents multiple services (e.g. LiveSmsService, DynamicIslandService)
/// from overwriting `_channel.setMethodCallHandler` and dropping callbacks.
///
/// It also buffers incoming `onSmsReceived` or `onIslandCardClicked` calls
/// received before the destination service has finished initializing,
/// guaranteeing zero dropped SMS or island tap events during cold-start windows.
class SmsLiveChannelBridge {
  static const MethodChannel _channel = MethodChannel('spendx/sms_live');

  SmsLiveChannelBridge._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final SmsLiveChannelBridge instance = SmsLiveChannelBridge._();

  MethodChannel get channel => _channel;

  SmsReceivedCallback? _smsReceivedCallback;
  final List<List<dynamic>?> _pendingSmsList = [];

  IslandEventCallback? _islandCardClickCallback;
  final List<Map<dynamic, dynamic>?> _pendingCardClicks = [];

  IslandEventCallback? _dynamicIslandEventCallback;

  @visibleForTesting
  void resetForTesting() {
    _smsReceivedCallback = null;
    _pendingSmsList.clear();
    _islandCardClickCallback = null;
    _pendingCardClicks.clear();
    _dynamicIslandEventCallback = null;
  }

  void registerSmsHandler(SmsReceivedCallback callback) {
    _smsReceivedCallback = callback;
    if (_pendingSmsList.isNotEmpty) {
      final queued = List<List<dynamic>?>.from(_pendingSmsList);
      _pendingSmsList.clear();
      for (final args in queued) {
        try {
          callback(args);
        } catch (e, st) {
          AppLogger.e('[SmsLiveChannelBridge] Error draining pending SMS: $e', e, st);
        }
      }
    }
  }

  void registerIslandCardClickHandler(IslandEventCallback callback) {
    _islandCardClickCallback = callback;
    if (_pendingCardClicks.isNotEmpty) {
      final queued = List<Map<dynamic, dynamic>?>.from(_pendingCardClicks);
      _pendingCardClicks.clear();
      for (final args in queued) {
        try {
          callback(args);
        } catch (e, st) {
          AppLogger.e('[SmsLiveChannelBridge] Error draining pending island card click: $e', e, st);
        }
      }
    }
  }

  void registerDynamicIslandEventHandler(IslandEventCallback callback) {
    _dynamicIslandEventCallback = callback;
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onSmsReceived':
        final args = call.arguments as List?;
        if (_smsReceivedCallback != null) {
          return await _smsReceivedCallback!(args);
        } else {
          AppLogger.i('[SmsLiveChannelBridge] Buffering incoming SMS until LiveSmsService registers.');
          _pendingSmsList.add(args);
          return null;
        }

      case 'onIslandCardClicked':
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (_islandCardClickCallback != null) {
          return await _islandCardClickCallback!(args);
        } else {
          AppLogger.i('[SmsLiveChannelBridge] Buffering island card click until DynamicIslandService registers.');
          _pendingCardClicks.add(args);
          return null;
        }

      case 'onDynamicIslandEvent':
        final args = call.arguments as Map<dynamic, dynamic>?;
        if (_dynamicIslandEventCallback != null) {
          return await _dynamicIslandEventCallback!(args);
        }
        return null;

      default:
        AppLogger.w('[SmsLiveChannelBridge] Unhandled method: ${call.method}');
        return null;
    }
  }

  /// Expose method channel invocation through the bridge
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) {
    return _channel.invokeMethod<T>(method, arguments);
  }
}
