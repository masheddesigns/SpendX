import 'package:shared_preferences/shared_preferences.dart';

/// Live Money Score — real-time financial behavior signal (0-100).
///
/// Event-driven: updates instantly after user actions.
/// Feels alive, not static like Data Health.
///
/// Actions:
///   +1  categorized transaction added
///   +3  audit issue fixed
///   +1  daily app open
///   -2  overspend detected
///   -5  duplicate found
class MoneyScore {
  final int value;
  final int deltaToday;
  final int? lastWeekScore;

  const MoneyScore({
    required this.value,
    required this.deltaToday,
    this.lastWeekScore,
  });

  /// Weekly momentum: positive = improving, negative = declining.
  int? get weeklyDelta => lastWeekScore != null ? value - lastWeekScore! : null;
  bool get isImproving => weeklyDelta != null && weeklyDelta! > 0;
}

class MoneyScoreService {
  MoneyScoreService._();
  static final instance = MoneyScoreService._();

  static const _scoreKey = 'money_score';
  static const _deltaKey = 'money_score_delta';
  static const _dateKey = 'money_score_date';

  static const _weeklyKey = 'money_score_weekly';

  /// Get current score with weekly momentum.
  Future<MoneyScore> getScore() async {
    final prefs = await SharedPreferences.getInstance();
    final score = prefs.getInt(_scoreKey) ?? 70;
    final delta = _getTodayDelta(prefs);
    final lastWeek = prefs.getInt(_weeklyKey);

    // Snapshot weekly score every Sunday
    if (DateTime.now().weekday == DateTime.sunday) {
      final lastSnapshot = prefs.getString('money_score_weekly_date');
      final today = DateTime.now().toIso8601String().substring(0, 10);
      if (lastSnapshot != today) {
        await prefs.setInt(_weeklyKey, score);
        await prefs.setString('money_score_weekly_date', today);
      }
    }

    return MoneyScore(
      value: score.clamp(0, 100),
      deltaToday: delta,
      lastWeekScore: lastWeek,
    );
  }

  /// Record a positive event.
  Future<MoneyScore> reward(int points) async {
    final prefs = await SharedPreferences.getInstance();
    _resetDayIfNeeded(prefs);
    final current = prefs.getInt(_scoreKey) ?? 70;
    final newScore = (current + points).clamp(0, 100);
    final delta = _getTodayDelta(prefs) + points;
    await prefs.setInt(_scoreKey, newScore);
    await prefs.setInt(_deltaKey, delta);
    return MoneyScore(value: newScore, deltaToday: delta);
  }

  /// Record a negative event.
  Future<MoneyScore> penalize(int points) async {
    final prefs = await SharedPreferences.getInstance();
    _resetDayIfNeeded(prefs);
    final current = prefs.getInt(_scoreKey) ?? 70;
    final newScore = (current - points).clamp(0, 100);
    final delta = _getTodayDelta(prefs) - points;
    await prefs.setInt(_scoreKey, newScore);
    await prefs.setInt(_deltaKey, delta);
    return MoneyScore(value: newScore, deltaToday: delta);
  }

  // ── Convenience methods ────────────────────────────────
  Future<MoneyScore> onTransactionAdded() => reward(1);
  Future<MoneyScore> onAuditFixed() => reward(3);
  Future<MoneyScore> onDailyOpen() => reward(1);
  Future<MoneyScore> onOverspendDetected() => penalize(2);
  Future<MoneyScore> onDuplicateFound() => penalize(5);
  Future<MoneyScore> onCategoryAssigned() => reward(2);

  // ── Daily reset helper ─────────────────────────────────
  int _getTodayDelta(SharedPreferences prefs) {
    _resetDayIfNeeded(prefs);
    return prefs.getInt(_deltaKey) ?? 0;
  }

  void _resetDayIfNeeded(SharedPreferences prefs) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final stored = prefs.getString(_dateKey);
    if (stored != today) {
      prefs.setString(_dateKey, today);
      prefs.setInt(_deltaKey, 0);
    }
  }
}
