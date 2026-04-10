import 'package:flutter/foundation.dart';

class DataChangeBus {
  DataChangeBus._();

  static final DataChangeBus instance = DataChangeBus._();

  final Set<VoidCallback> _listeners = <VoidCallback>{};

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void notify() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }
}
