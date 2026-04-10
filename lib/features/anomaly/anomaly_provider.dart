import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/providers/account_providers.dart';
import '../dashboard/insights_providers.dart';
import '../liabilities/providers/credit_health_providers.dart';
import '../transactions/providers/transaction_providers.dart';
import 'anomaly_detection_service.dart';
import 'anomaly_model.dart';

/// Detected anomalies based on current financial state.
/// Async to avoid blocking the UI thread during heavy computation.
final anomalyProvider = FutureProvider<List<Anomaly>>((ref) async {
  final monthly = await ref.watch(monthlyStatsProvider.future);
  final categories = await ref.watch(topCategoriesProvider.future);
  final pressure = await ref.watch(financialPressureProvider.future);
  final credit = await ref.watch(creditHealthProvider.future);
  final txns = await ref.watch(transactionsProvider.future);
  final accounts = await ref.watch(accountsProvider.future);

  return AnomalyDetectionService().detect(
    monthly: monthly,
    categories: categories,
    pressure: pressure,
    credit: credit,
    transactions: txns,
    accounts: accounts,
  );
});

/// Only high-severity anomalies (for notifications).
final highSeverityAnomalyProvider = FutureProvider<List<Anomaly>>((ref) async {
  final all = await ref.watch(anomalyProvider.future);
  return all.where((a) => a.severity == AnomalySeverity.high).toList();
});
