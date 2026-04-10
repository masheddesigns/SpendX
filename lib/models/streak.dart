class Streak {
  final int current;
  final int best;
  final DateTime? lastEvaluated;

  const Streak({
    this.current = 0,
    this.best = 0,
    this.lastEvaluated,
  });

  Streak increment() {
    final next = current + 1;
    return Streak(
      current: next,
      best: next > best ? next : best,
      lastEvaluated: DateTime.now(),
    );
  }

  Streak reset() => Streak(
    current: 0,
    best: best,
    lastEvaluated: DateTime.now(),
  );

  /// Whether the streak was already evaluated today.
  bool get evaluatedToday {
    if (lastEvaluated == null) return false;
    final now = DateTime.now();
    return lastEvaluated!.year == now.year &&
        lastEvaluated!.month == now.month &&
        lastEvaluated!.day == now.day;
  }

  /// Milestone message based on current streak.
  String? get milestoneMessage {
    if (current >= 30) return 'Legendary discipline!';
    if (current >= 14) return 'Elite financial control';
    if (current >= 7) return 'Strong discipline';
    if (current >= 3) return 'Good start!';
    return null;
  }

  Map<String, dynamic> toMap() => {
    'id': 'user_streak',
    'current_streak': current,
    'best_streak': best,
    'last_evaluated': lastEvaluated?.toIso8601String(),
  };

  factory Streak.fromMap(Map<String, dynamic> map) => Streak(
    current: (map['current_streak'] as int?) ?? 0,
    best: (map['best_streak'] as int?) ?? 0,
    lastEvaluated: map['last_evaluated'] != null
        ? DateTime.tryParse(map['last_evaluated'] as String)
        : null,
  );
}
