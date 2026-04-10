import 'dart:math' as math;

/// User XP and level state.
class UserXP {
  final int xp;
  final int level;
  final int xpForNextLevel;
  final String levelName;

  const UserXP({
    required this.xp,
    required this.level,
    required this.xpForNextLevel,
    required this.levelName,
  });

  double get levelProgress {
    final currentLevelXp = _xpForLevel(level);
    final nextLevelXp = _xpForLevel(level + 1);
    final range = nextLevelXp - currentLevelXp;
    if (range <= 0) return 1.0;
    return ((xp - currentLevelXp) / range).clamp(0.0, 1.0);
  }

  static int _xpForLevel(int level) => (level * level * 50);
}

/// Achievement definition.
class Achievement {
  final String id;
  final String title;
  final String description;
  final String icon;
  final bool unlocked;

  const Achievement({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.unlocked,
  });
}

/// Computes XP from user activity signals.
/// Pure computation — no DB.
class XPEngine {
  /// Calculate total XP from activity counters.
  UserXP compute({
    required int totalTransactions,
    required int currentStreak,
    required int bestStreak,
    required int goalsCompleted,
    required int daysWithNoAnomalies,
    required int budgetsRespected,
  }) {
    int xp = 0;

    // Transactions: 2 XP each
    xp += totalTransactions * 2;

    // Streak: 5 XP per day of current streak
    xp += currentStreak * 5;

    // Best streak bonus: 3 XP per day
    xp += bestStreak * 3;

    // Goals completed: 20 XP each
    xp += goalsCompleted * 20;

    // Clean days (no high anomalies): 10 XP each
    xp += daysWithNoAnomalies * 10;

    // Budgets respected: 8 XP each
    xp += budgetsRespected * 8;

    // Level = sqrt(xp / 50), minimum 1
    final level = math.max(1, math.sqrt(xp / 50).floor());

    // XP needed for next level
    final xpForNext = UserXP._xpForLevel(level + 1);

    // Level name
    final String levelName;
    if (level >= 20) {
      levelName = 'Diamond';
    } else if (level >= 15) {
      levelName = 'Platinum';
    } else if (level >= 10) {
      levelName = 'Gold';
    } else if (level >= 5) {
      levelName = 'Silver';
    } else {
      levelName = 'Bronze';
    }

    return UserXP(
      xp: xp,
      level: level,
      xpForNextLevel: xpForNext,
      levelName: levelName,
    );
  }

  /// Generate achievements from activity.
  List<Achievement> achievements({
    required int totalTransactions,
    required int bestStreak,
    required int goalsCompleted,
    required double totalSaved,
  }) {
    return [
      Achievement(
        id: 'first_transaction',
        title: 'First Step',
        description: 'Add your first transaction',
        icon: 'start',
        unlocked: totalTransactions >= 1,
      ),
      Achievement(
        id: 'fifty_transactions',
        title: 'Tracker',
        description: 'Log 50 transactions',
        icon: 'list',
        unlocked: totalTransactions >= 50,
      ),
      Achievement(
        id: 'streak_7',
        title: 'Week Warrior',
        description: 'Maintain a 7-day streak',
        icon: 'fire',
        unlocked: bestStreak >= 7,
      ),
      Achievement(
        id: 'streak_30',
        title: 'Monthly Master',
        description: 'Maintain a 30-day streak',
        icon: 'trophy',
        unlocked: bestStreak >= 30,
      ),
      Achievement(
        id: 'first_goal',
        title: 'Goal Setter',
        description: 'Complete your first goal',
        icon: 'flag',
        unlocked: goalsCompleted >= 1,
      ),
      Achievement(
        id: 'saved_10k',
        title: 'Saver',
        description: 'Save 10,000 total',
        icon: 'savings',
        unlocked: totalSaved >= 10000,
      ),
      Achievement(
        id: 'saved_100k',
        title: 'Wealth Builder',
        description: 'Save 1,00,000 total',
        icon: 'diamond',
        unlocked: totalSaved >= 100000,
      ),
    ];
  }
}
