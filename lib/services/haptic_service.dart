import 'dart:async';

import 'package:flutter/services.dart';

enum SpendXHapticType { none, tap, success, critical, selection }

class HapticService {
  HapticService._();

  static final HapticService instance = HapticService._();

  static const Duration _minInterval = Duration(milliseconds: 70);
  DateTime? _lastTriggeredAt;

  void trigger(SpendXHapticType type) {
    if (type == SpendXHapticType.none) return;

    final now = DateTime.now();
    if (_lastTriggeredAt != null &&
        now.difference(_lastTriggeredAt!) < _minInterval) {
      return;
    }
    _lastTriggeredAt = now;

    switch (type) {
      case SpendXHapticType.none:
        return;
      case SpendXHapticType.tap:
        unawaited(HapticFeedback.lightImpact());
        return;
      case SpendXHapticType.success:
        unawaited(HapticFeedback.mediumImpact());
        return;
      case SpendXHapticType.critical:
        unawaited(HapticFeedback.heavyImpact());
        return;
      case SpendXHapticType.selection:
        unawaited(HapticFeedback.selectionClick());
        return;
    }
  }

  void tap() => trigger(SpendXHapticType.tap);

  void medium() => trigger(SpendXHapticType.success);

  void success() => trigger(SpendXHapticType.success);

  void critical() => trigger(SpendXHapticType.critical);

  void selection() => trigger(SpendXHapticType.selection);
}
