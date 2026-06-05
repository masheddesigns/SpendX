import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/data_audit_service.dart';
import '../../services/decision_engine.dart';
import '../../services/financial_identity_service.dart';
import '../../services/forecast_engine.dart';
import '../../services/goal_nudge_engine.dart';
import '../../services/money_score_service.dart';
import '../wrapped/models/wrapped_summary.dart';
import '../wrapped/services/wrapped_service.dart';
import '../transactions/providers/transaction_providers.dart';

/// Complete unified view: Identity → Past → Present → Future → Decision.
class FinancialTimeline {
  final FinancialIdentity identity;
  final MoneyScore moneyScore;
  final WrappedSummary? weeklyWrapped;
  final DataHealthScore health;
  final Forecast forecast;
  final List<Nudge> nudges;
  final DecisionInsight? topInsight;

  const FinancialTimeline({
    required this.identity,
    required this.moneyScore,
    this.weeklyWrapped,
    required this.health,
    required this.forecast,
    required this.nudges,
    this.topInsight,
  });
}

final financialTimelineProvider = FutureProvider<FinancialTimeline>((ref) async {
  ref.watch(transactionsProvider);

  // Phase 1: compute identity (fast — reads forecast + health)
  final identity = await FinancialIdentityService.instance.compute();

  // Phase 2: load everything else in parallel, passing identity for tone
  final results = await Future.wait([
    MoneyScoreService.instance.getScore(),
    _getWeeklyWrapped(ref),
    DataAuditService.instance.getHealthScore(),
    ForecastEngine.instance.compute(),
    GoalNudgeEngine.instance.generate(identity: identity.type),
    DecisionEngine.instance.getTopInsight(identity: identity.type),
  ]);

  return FinancialTimeline(
    identity: identity,
    moneyScore: results[0] as MoneyScore,
    weeklyWrapped: results[1] as WrappedSummary?,
    health: results[2] as DataHealthScore,
    forecast: results[3] as Forecast,
    nudges: results[4] as List<Nudge>,
    topInsight: results[5] as DecisionInsight?,
  );
});

Future<WrappedSummary?> _getWeeklyWrapped(Ref ref) async {
  try {
    final now = DateTime.now();
    final weekNum = ((now.difference(DateTime(now.year, 1, 1)).inDays -
                now.weekday + 10) / 7)
        .floor();
    final weekKey = '${now.year}-W${weekNum.toString().padLeft(2, '0')}';
    final service = WrappedService(ref.read(transactionRepoProvider));
    return await service.getSummary(weekKey);
  } catch (_) {
    return null;
  }
}
