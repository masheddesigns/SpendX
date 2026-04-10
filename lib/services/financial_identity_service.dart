import 'package:flutter/material.dart' show Color, Colors;

import 'data_audit_service.dart';
import 'forecast_engine.dart';

/// Financial identity — a persistent behavioral trait label.
///
/// Not a stat. Not a score. A trait that users internalize.
/// "I am Disciplined" is more powerful than "I saved 25%."
enum IdentityType { disciplined, stable, improving, impulsive, atRisk }

class FinancialIdentity {
  final IdentityType type;
  final String label;
  final String emoji;
  final String description;
  final Color color;

  const FinancialIdentity({
    required this.type,
    required this.label,
    required this.emoji,
    required this.description,
    required this.color,
  });
}

class FinancialIdentityService {
  FinancialIdentityService._();
  static final instance = FinancialIdentityService._();

  /// Compute the user's financial identity from current data.
  Future<FinancialIdentity> compute() async {
    final forecast = await ForecastEngine.instance.compute();
    final health = await DataAuditService.instance.getHealthScore();

    final savingsRate = forecast.projectedIncome > 0
        ? forecast.projectedSavings / forecast.projectedIncome
        : 0.0;
    final healthScore = health.score;
    final isOverspending = forecast.isOverspendRisk;
    final negativeSavings = forecast.projectedSavings < 0;

    // ── Identity rules (ordered by priority) ──────────────
    if (negativeSavings) {
      return const FinancialIdentity(
        type: IdentityType.atRisk,
        label: 'At Risk',
        emoji: '\u{1F6A8}',
        description: 'Your spending is outpacing income right now. Let\'s fix this together.',
        color: Colors.red,
      );
    }

    if (isOverspending && savingsRate < 0.10) {
      return const FinancialIdentity(
        type: IdentityType.impulsive,
        label: 'Impulsive',
        emoji: '\u{1F62C}',
        description: 'You\'re spending freely. A small adjustment can make a big difference.',
        color: Colors.orange,
      );
    }

    if (savingsRate >= 0.25 && healthScore >= 80) {
      return const FinancialIdentity(
        type: IdentityType.disciplined,
        label: 'Disciplined',
        emoji: '\u{1F4AA}',
        description: 'You\'re in control of your money right now.',
        color: Colors.green,
      );
    }

    if (savingsRate >= 0.10 && healthScore >= 60) {
      return const FinancialIdentity(
        type: IdentityType.stable,
        label: 'Stable',
        emoji: '\u{1F44D}',
        description: 'Your money habits are solid. Steady wins the race.',
        color: Colors.blue,
      );
    }

    return const FinancialIdentity(
      type: IdentityType.improving,
      label: 'Improving',
      emoji: '\u{1F4C8}',
      description: 'You\'re getting better. Small steps are compounding.',
      color: Colors.teal,
    );
  }
}
