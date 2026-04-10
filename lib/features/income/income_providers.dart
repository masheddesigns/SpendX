import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dashboard/insights_providers.dart';
import 'income_intelligence.dart';

export 'income_intelligence.dart'
    show IncomeIntelligence, IncomeStabilityLevel, SalaryPrediction, EmployerReliability;

/// Income stability analysis.
final incomeStabilityProvider = FutureProvider<IncomeIntelligence>((ref) async {
  final stats = await ref.watch(monthlyStatsProvider.future);
  return IncomeIntelligenceEngine().computeStability(stats);
});

/// Next salary prediction.
final salaryPredictionProvider = FutureProvider<SalaryPrediction>((ref) async {
  final stats = await ref.watch(monthlyStatsProvider.future);
  // Default payday 5 — will be overridden when salary config exists
  return IncomeIntelligenceEngine().predictNextSalary(
    stats: stats,
    expectedPayday: 5,
  );
});
