import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart' show canonicalForecast30DaysProvider;
import 'forecast_engine.dart';

export 'forecast_engine.dart' show Forecast;

/// Canonical deterministic forecast provider.
///
/// Adapts the single authoritative [CanonicalForecastEngine] for UI consumption
/// with backward-compatible properties.
final forecastProvider = FutureProvider<Forecast>((ref) async {
  final canonicalForecast =
      await ref.watch(canonicalForecast30DaysProvider.future);

  return Forecast.fromCanonical(canonicalForecast);
});
