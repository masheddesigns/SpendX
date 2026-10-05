import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart' show canonicalForecast30DaysProvider;
import 'runway_engine.dart';

export 'runway_engine.dart' show Runway, RunwayStatus;

/// Canonical predicted cashflow runway provider.
///
/// Derives runway exclusively from [CanonicalForecastEngine], taking into account
/// authoritative liquid balance, contractual obligations (loans/cards/rent),
/// and median daily variable burn.
final runwayProvider = FutureProvider<Runway>((ref) async {
  final canonicalForecast =
      await ref.watch(canonicalForecast30DaysProvider.future);

  return Runway.fromCanonical(canonicalForecast);
});
