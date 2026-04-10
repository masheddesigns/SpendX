import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/service_providers.dart';
import '../data/alert_service.dart';
import '../data/app_alert.dart';

final alertServiceProvider = Provider<AlertService>((ref) {
  final service = AlertService(
    databaseService: ref.watch(databaseServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final activeAlertsProvider = StreamProvider.autoDispose<List<AppAlert>>((ref) {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), link.close);
  ref.onDispose(timer.cancel);
  return ref.watch(alertServiceProvider).watchActiveAlerts();
});

final activeAlertsSnapshotProvider = FutureProvider.autoDispose<List<AppAlert>>(
  (ref) {
    final link = ref.keepAlive();
    final timer = Timer(const Duration(minutes: 5), link.close);
    ref.onDispose(timer.cancel);
    return ref.watch(alertServiceProvider).getActiveAlerts();
  },
);
