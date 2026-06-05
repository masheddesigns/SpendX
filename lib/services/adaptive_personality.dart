import 'financial_identity_service.dart';

/// Personality-aware copy engine.
///
/// Takes the user's financial identity and returns tone-adjusted
/// messages for every system signal. No state — pure functions.
///
/// Tone spectrum:
/// - Disciplined → minimal, trusting, short
/// - Stable → calm, data-forward
/// - Improving → encouraging, momentum-focused
/// - Impulsive → structured, specific next steps
/// - At Risk → supportive, one clear action
class AdaptivePersonality {
  final IdentityType identity;
  const AdaptivePersonality(this.identity);

  // ═══════════════════════════════════════════════════════════
  // IDENTITY BANNER
  // ═══════════════════════════════════════════════════════════

  String get identityDescription => switch (identity) {
        IdentityType.disciplined =>
          'You\'re in control of your money right now.',
        IdentityType.stable =>
          'Your money habits are solid. Steady wins the race.',
        IdentityType.improving =>
          'You\'re getting better. Small steps are compounding.',
        IdentityType.impulsive =>
          'You\'re spending freely. A small adjustment can make a big difference.',
        IdentityType.atRisk =>
          'Your spending is outpacing income. Let\'s fix this together.',
      };

  // ═══════════════════════════════════════════════════════════
  // DECISION ENGINE — OVERSPEND
  // ═══════════════════════════════════════════════════════════

  String get overspendTitle => switch (identity) {
        IdentityType.disciplined => 'Spending crept up',
        IdentityType.stable => 'Spending is above average',
        IdentityType.improving => 'Watch your spending this week',
        IdentityType.impulsive => 'You\'re spending faster than usual',
        IdentityType.atRisk => 'Spending is outpacing income',
      };

  String overspendBody(String amount) => switch (identity) {
        IdentityType.disciplined => '$amount above last month.',
        IdentityType.stable =>
          'About $amount more than usual this month.',
        IdentityType.improving =>
          'You\'ve been doing well — $amount above last month, but you can adjust.',
        IdentityType.impulsive =>
          'At this pace, $amount more than last month. Try pausing non-essentials for a few days.',
        IdentityType.atRisk =>
          'About $amount over. Focus on essentials this week — one step at a time.',
      };

  // ═══════════════════════════════════════════════════════════
  // DECISION ENGINE — ON TRACK
  // ═══════════════════════════════════════════════════════════

  String get onTrackTitle => switch (identity) {
        IdentityType.disciplined => 'Smooth month',
        IdentityType.stable => 'On track',
        IdentityType.improving => 'Great momentum',
        IdentityType.impulsive => 'You\'re staying on track',
        IdentityType.atRisk => 'Things are stabilizing',
      };

  String onTrackBody(String savings) => switch (identity) {
        IdentityType.disciplined => '$savings projected savings.',
        IdentityType.stable =>
          'Heading towards $savings in savings.',
        IdentityType.improving =>
          'You\'re building towards $savings — keep this up.',
        IdentityType.impulsive =>
          'You\'re heading for $savings in savings. This is a good rhythm — stick with it.',
        IdentityType.atRisk =>
          'Projected savings: $savings. This is real progress.',
      };

  // ═══════════════════════════════════════════════════════════
  // GOAL NUDGES — MILESTONE
  // ═══════════════════════════════════════════════════════════

  String milestoneBody(String remaining) => switch (identity) {
        IdentityType.disciplined => '$remaining to go.',
        IdentityType.stable => 'Almost there — $remaining left.',
        IdentityType.improving =>
          'You\'re almost there — $remaining to go!',
        IdentityType.impulsive =>
          'Only $remaining left! Stay focused and you\'ll make it.',
        IdentityType.atRisk => '$remaining to go. Every bit counts.',
      };

  // ═══════════════════════════════════════════════════════════
  // GOAL NUDGES — DELAY WARNING
  // ═══════════════════════════════════════════════════════════

  String delayWarningBody(String goal, int deficit, String requiredPerMonth) =>
      switch (identity) {
        IdentityType.disciplined =>
          'Behind by $deficit month${_s(deficit)}. Need $requiredPerMonth/month.',
        IdentityType.stable =>
          'May miss by $deficit month${_s(deficit)}. Need $requiredPerMonth/month to stay on track.',
        IdentityType.improving =>
          'Need to pick up pace — $deficit month${_s(deficit)} behind. $requiredPerMonth/month gets you there.',
        IdentityType.impulsive =>
          'At current pace, $deficit month${_s(deficit)} behind. Need $requiredPerMonth/month — consider cutting one category.',
        IdentityType.atRisk =>
          'Behind by $deficit month${_s(deficit)}. Focus: save $requiredPerMonth this month.',
      };

  // ═══════════════════════════════════════════════════════════
  // GOAL NUDGES — STALLED
  // ═══════════════════════════════════════════════════════════

  String stalledBody(String goal, String remaining) => switch (identity) {
        IdentityType.disciplined =>
          'Savings paused. $remaining still needed for $goal.',
        IdentityType.stable =>
          'Spending exceeds income this month. $remaining still needed.',
        IdentityType.improving =>
          'A tough stretch — $remaining still needed. You\'ve recovered before.',
        IdentityType.impulsive =>
          'Spending is above income. $remaining still needed for $goal. Try one spending freeze day this week.',
        IdentityType.atRisk =>
          '$remaining still needed. Focus on reducing one expense today.',
      };

  // ═══════════════════════════════════════════════════════════
  // DATA HEALTH
  // ═══════════════════════════════════════════════════════════

  String dataIssueTitle(int count) => switch (identity) {
        IdentityType.disciplined => '$count to clean up',
        IdentityType.stable => '$count data issue${_s(count)} found',
        IdentityType.improving =>
          '$count issue${_s(count)} — quick fixes available',
        IdentityType.impulsive =>
          '$count thing${_s(count)} need fixing — this affects your reports',
        IdentityType.atRisk =>
          '$count issue${_s(count)} affecting accuracy. Fix the top one now.',
      };

  // ═══════════════════════════════════════════════════════════
  // SCORE MOMENTUM
  // ═══════════════════════════════════════════════════════════

  String scoreMomentumUp(int delta) => switch (identity) {
        IdentityType.disciplined => '↑ $delta',
        IdentityType.stable => '↑ $delta this week',
        IdentityType.improving => '↑ $delta — you\'re building momentum',
        IdentityType.impulsive => '↑ $delta this week — nice work',
        IdentityType.atRisk => '↑ $delta — things are turning around',
      };

  String scoreMomentumDown(int delta) => switch (identity) {
        IdentityType.disciplined => '↓ ${delta.abs()}',
        IdentityType.stable => '↓ ${delta.abs()} this week',
        IdentityType.improving =>
          '↓ ${delta.abs()} — small dip, you\'ll recover',
        IdentityType.impulsive =>
          '↓ ${delta.abs()} this week — a few quick fixes can turn this around',
        IdentityType.atRisk =>
          '↓ ${delta.abs()} — focus on one thing today',
      };

  // ═══════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════

  static String _s(int count) => count == 1 ? '' : 's';
}
