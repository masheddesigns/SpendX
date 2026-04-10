/// Computed progress for a single goal.
class GoalProgress {
  /// 0.0–1.0 (can exceed 1.0 for overspending, clamped in display).
  final double progressPct;

  /// Amount remaining to reach target.
  final double remaining;

  /// Days until goal deadline.
  final int daysLeft;

  /// For savings: required saving per day.
  /// For spending: available budget per remaining day.
  /// For debt: required payoff per day.
  final double requiredDaily;

  /// Whether the goal target has been reached.
  final bool isCompleted;

  /// For spending limits: whether spending exceeds the target.
  final bool isOverBudget;

  /// For spending limits: actual amount spent so far.
  final double? currentSpent;

  const GoalProgress({
    required this.progressPct,
    required this.remaining,
    required this.daysLeft,
    required this.requiredDaily,
    required this.isCompleted,
    required this.isOverBudget,
    this.currentSpent,
  });

  /// Whether the user is behind their expected pace.
  /// For savings: required daily rate is high relative to remaining time.
  /// For spending: already used most of the budget early.
  bool get isBehindSchedule => !isCompleted && remaining > 0 && daysLeft < 7;

  /// Whether this goal is at risk of not being met.
  bool get isAtRisk => isOverBudget || (daysLeft < 3 && progressPct < 0.8);
}
