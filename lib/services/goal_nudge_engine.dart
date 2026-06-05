import '../data/repositories/goal_repo.dart';
import '../utils/app_format.dart';
import 'adaptive_personality.dart';
import 'financial_identity_service.dart';
import 'forecast_engine.dart';

/// A goal-aware nudge — connects spending behavior to personal goals.
class Nudge {
  final String title;
  final String body;
  final NudgeType type;
  final String? goalId;

  const Nudge({
    required this.title,
    required this.body,
    required this.type,
    this.goalId,
  });
}

enum NudgeType {
  acceleration,  // "Add ₹3K → reach goal 2 months earlier"
  delayWarning,  // "At current pace, you'll miss by 3 months"
  opportunity,   // "Cut 1 subscription → save ₹500/month"
  milestone,     // "You're 82% there — keep going"
}

/// Generates goal-aware nudges from spending data + goals.
class GoalNudgeEngine {
  GoalNudgeEngine._();
  static final instance = GoalNudgeEngine._();

  /// Generate nudges based on current goals and forecast.
  Future<List<Nudge>> generate({IdentityType? identity}) async {
    final nudges = <Nudge>[];
    final p = AdaptivePersonality(identity ?? IdentityType.stable);

    try {
      final goalRepo = GoalRepo();
      final goals = await goalRepo.getAll();
      final forecast = await ForecastEngine.instance.compute();

      if (goals.isEmpty) return nudges;

      final monthlySavings = forecast.projectedSavings;

      for (final goal in goals) {
        final remaining = goal.targetAmount - goal.currentAmount;
        if (remaining <= 0) continue; // already achieved

        final progress = goal.targetAmount > 0
            ? (goal.currentAmount / goal.targetAmount * 100)
            : 0.0;

        // ── Milestone push (>75% complete) ─────────────────
        if (progress >= 75) {
          nudges.add(Nudge(
            title: '${progress.toStringAsFixed(0)}% to ${goal.title}',
            body: p.milestoneBody(AppFormat.currency(remaining)),
            type: NudgeType.milestone,
            goalId: goal.id,
          ));
          continue;
        }

        // ── Time-to-goal calculation ───────────────────────
        if (monthlySavings > 0) {
          final monthsNeeded = remaining / monthlySavings;

          // Check deadline timeline
          final monthsLeft = goal.endDate.difference(DateTime.now()).inDays / 30;

          if (monthsLeft > 0 && monthsNeeded > monthsLeft) {
            // Delay warning
            final deficit = (monthsNeeded - monthsLeft).ceil();
            nudges.add(Nudge(
              title: '${goal.title} at risk',
              body: p.delayWarningBody(
                goal.title,
                deficit,
                AppFormat.currency(remaining / monthsLeft),
              ),
              type: NudgeType.delayWarning,
              goalId: goal.id,
            ));
          } else {
            // On track — suggest acceleration
            final extraPerMonth = 2000.0;
            final newMonths = remaining / (monthlySavings + extraPerMonth);
            final saved = (monthsNeeded - newMonths).round();
            if (saved >= 1) {
              nudges.add(Nudge(
                title: 'Accelerate ${goal.title}',
                body: 'Add ${AppFormat.currency(extraPerMonth)}/month → reach goal $saved month${saved == 1 ? "" : "s"} earlier.',
                type: NudgeType.acceleration,
                goalId: goal.id,
              ));
            }
          }
        } else {
          // Negative savings — warning
          nudges.add(Nudge(
            title: '${goal.title} stalled',
            body: p.stalledBody(goal.title, AppFormat.currency(remaining)),
            type: NudgeType.delayWarning,
            goalId: goal.id,
          ));
        }
      }

      // ── Opportunity nudge (from forecast category drift) ──
      final driftingCats = forecast.categoryForecasts.values
          .where((c) => c.isTrendingUp)
          .toList()
        ..sort((a, b) => b.driftPercent.compareTo(a.driftPercent));

      if (driftingCats.isNotEmpty && goals.isNotEmpty) {
        final top = driftingCats.first;
        final potential = (top.projected - top.previousMonthTotal).abs();
        if (potential > 500) {
          nudges.add(Nudge(
            title: 'Spending opportunity',
            body: 'Reduce ${top.categoryName} to last month\'s level '
                '→ save ${AppFormat.currency(potential)}/month towards ${goals.first.title}.',
            type: NudgeType.opportunity,
          ));
        }
      }
    } catch (e) {
      // Non-fatal — goals may not exist
    }

    return nudges;
  }
}
