import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../accounts/providers/account_providers.dart';
import '../dashboard/insights_providers.dart';
import 'forecast_engine.dart';

export 'forecast_engine.dart' show Forecast;

final forecastProvider = FutureProvider<Forecast>((ref) async {
  final stats = await ref.watch(monthlyStatsProvider.future);
  final accounts = await ref.watch(accountsProvider.future);

  final currentBalance = accounts
      .where((a) => a.isAsset)
      .fold<double>(0, (sum, a) => sum + a.balance);

  return ForecastEngine().predict(
    monthlyStats: stats,
    currentBalance: currentBalance,
  );
});
