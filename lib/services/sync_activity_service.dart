import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum SyncStage {
  idle,
  scanning,
  processing,
  reconciling,
  completed,
  error,
}

class SyncActivityState {
  final SyncStage stage;
  final String title;
  final String subtitle;
  final double? progress; // 0.0 to 1.0, or null for indeterminate
  final int itemsCount;
  final DateTime timestamp;

  const SyncActivityState({
    required this.stage,
    this.title = '',
    this.subtitle = '',
    this.progress,
    this.itemsCount = 0,
    required this.timestamp,
  });

  bool get isActive =>
      stage != SyncStage.idle &&
      stage != SyncStage.completed &&
      stage != SyncStage.error;

  bool get isVisible => stage != SyncStage.idle;

  static SyncActivityState idle() => SyncActivityState(
        stage: SyncStage.idle,
        timestamp: DateTime.now(),
      );

  SyncActivityState copyWith({
    SyncStage? stage,
    String? title,
    String? subtitle,
    double? progress,
    int? itemsCount,
    DateTime? timestamp,
  }) {
    return SyncActivityState(
      stage: stage ?? this.stage,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      progress: progress ?? this.progress,
      itemsCount: itemsCount ?? this.itemsCount,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}

/// Central state manager for live sync, SMS loading, and background operations.
class SyncActivityService extends ChangeNotifier {
  SyncActivityService._();
  static final SyncActivityService instance = SyncActivityService._();

  SyncActivityState _state = SyncActivityState.idle();
  SyncActivityState get state => _state;

  Timer? _autoDismissTimer;

  void startSync({
    required String title,
    String subtitle = 'Syncing data...',
    double? progress,
  }) {
    _autoDismissTimer?.cancel();
    _state = SyncActivityState(
      stage: SyncStage.scanning,
      title: title,
      subtitle: subtitle,
      progress: progress,
      timestamp: DateTime.now(),
    );
    notifyListeners();
  }

  void updateProgress({
    required String title,
    String? subtitle,
    double? progress,
    int? count,
    SyncStage stage = SyncStage.processing,
  }) {
    _autoDismissTimer?.cancel();
    _state = _state.copyWith(
      stage: stage,
      title: title,
      subtitle: subtitle ?? _state.subtitle,
      progress: progress,
      itemsCount: count ?? _state.itemsCount,
      timestamp: DateTime.now(),
    );
    notifyListeners();
  }

  void complete({
    String title = 'All Caught Up',
    String? subtitle,
    int? count,
    Duration displayDuration = const Duration(seconds: 3),
  }) {
    _autoDismissTimer?.cancel();
    _state = _state.copyWith(
      stage: SyncStage.completed,
      title: title,
      subtitle: subtitle ?? (count != null && count > 0 ? '$count items updated' : 'Accounts and cards are in sync'),
      progress: 1.0,
      itemsCount: count ?? _state.itemsCount,
      timestamp: DateTime.now(),
    );
    notifyListeners();

    _autoDismissTimer = Timer(displayDuration, () {
      dismiss();
    });
  }

  void reportError(String message) {
    _autoDismissTimer?.cancel();
    _state = _state.copyWith(
      stage: SyncStage.error,
      title: 'Sync Interrupted',
      subtitle: message,
      progress: null,
      timestamp: DateTime.now(),
    );
    notifyListeners();

    _autoDismissTimer = Timer(const Duration(seconds: 4), () {
      dismiss();
    });
  }

  void dismiss() {
    _autoDismissTimer?.cancel();
    if (_state.stage != SyncStage.idle) {
      _state = SyncActivityState.idle();
      notifyListeners();
    }
  }
}
