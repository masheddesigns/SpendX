import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../features/transactions/providers/transaction_providers.dart';
import '../models/wrapped_summary.dart';
import '../services/wrapped_service.dart';

/// Singleton wrapped service with caching.
final wrappedServiceProvider = Provider<WrappedService>((ref) {
  return WrappedService(ref.watch(transactionRepoProvider));
});

/// Fetch a wrapped summary for a specific period.
/// Period = "2026-03" (monthly) or "2025" (yearly).
final wrappedSummaryProvider =
    FutureProvider.family<WrappedSummary?, String>((ref, period) {
  return ref.read(wrappedServiceProvider).getSummary(period);
});

/// Available periods that have transaction data (latest first, max 6).
final availableWrappedPeriodsProvider =
    FutureProvider<List<String>>((ref) async {
  return ref.read(wrappedServiceProvider).getAvailablePeriods();
});
