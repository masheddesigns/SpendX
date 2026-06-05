import 'package:flutter/material.dart' show Color, Colors;

import 'adaptive_personality.dart';
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
    IdentityType type;
    if (negativeSavings) {
      type = IdentityType.atRisk;
    } else if (isOverspending && savingsRate < 0.10) {
      type = IdentityType.impulsive;
    } else if (savingsRate >= 0.25 && healthScore >= 80) {
      type = IdentityType.disciplined;
    } else if (savingsRate >= 0.10 && healthScore >= 60) {
      type = IdentityType.stable;
    } else {
      type = IdentityType.improving;
    }

    final personality = AdaptivePersonality(type);

    return FinancialIdentity(
      type: type,
      label: _label(type),
      emoji: _emoji(type),
      description: personality.identityDescription,
      color: _color(type),
    );
  }

  static String _label(IdentityType t) => switch (t) {
        IdentityType.disciplined => 'Disciplined',
        IdentityType.stable => 'Stable',
        IdentityType.improving => 'Improving',
        IdentityType.impulsive => 'Impulsive',
        IdentityType.atRisk => 'At Risk',
      };

  static String _emoji(IdentityType t) => switch (t) {
        IdentityType.disciplined => '\u{1F4AA}',
        IdentityType.stable => '\u{1F44D}',
        IdentityType.improving => '\u{1F4C8}',
        IdentityType.impulsive => '\u{1F62C}',
        IdentityType.atRisk => '\u{1F6A8}',
      };

  static Color _color(IdentityType t) => switch (t) {
        IdentityType.disciplined => Colors.green,
        IdentityType.stable => Colors.blue,
        IdentityType.improving => Colors.teal,
        IdentityType.impulsive => Colors.orange,
        IdentityType.atRisk => Colors.red,
      };
}
