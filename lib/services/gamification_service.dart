import 'package:shared_preferences/shared_preferences.dart';
import '../data/repositories/transaction_repo.dart';
import '../data/repositories/salary_repo.dart';

class Achievement {
  final String id;
  final String title;
  final String description;
  final String icon;
  final String category;
  final bool isUnlocked;
  final double progress; // 0.0 to 1.0
  final String progressLabel; // e.g. "63/100"

  Achievement({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.category,
    this.isUnlocked = false,
    this.progress = 0.0,
    this.progressLabel = '',
  });
}

class GamificationService {
  final TransactionRepo transactionRepo;
  final SalaryRepo salaryRepo;

  GamificationService({
    required this.transactionRepo,
    required this.salaryRepo,
  });

  static final GamificationService instance = GamificationService(
    transactionRepo: TransactionRepo(),
    salaryRepo: SalaryRepo(),
  );


  // Weighted XP rewards
  static const int xpPerTransaction = 5;
  static const int xpPerBudgetSuccess = 50;
  static const int xpPerStreakMilestone = 100;
  static const int xpPerIncomeSource = 80;
  static const int xpPerInsightView = 10;

  static const _motivationQuotes = [
    '💰 "Do not save what is left after spending, but spend what is left after saving." - Warren Buffett',
    '📊 Track every rupee — the small ones add up!',
    '🔥 "Beware of little expenses. A small leak will sink a great ship." - Benjamin Franklin',
    '🎯 "A budget is telling your money where to go instead of wondering where it went." - John Maxwell',
    '🌱 Small habits, big wealth. Consistency is the key.',
    '🏆 Financial freedom is available to those who learn about it and work for it.',
    '⚡ "Wealth is not about having a lot of money; it\'s about having a lot of options." - Chris Rock',
    '🧩 Every transaction tells a story. What is yours saying?',
    '🚀 The fastest way to double your money is to fold it over and put it back in your pocket.',
    '💡 Becoming wealthy is a disciplined process. Start today.',
    '🎉 Stop buying things you don\'t need, to impress people you don\'t even like.',
    '🛡️ Rule No. 1: Never lose money. Rule No. 2: Never forget rule No. 1.',
    '🌟 Great job tracking — keep the streak alive and watch your net worth grow!',
    '💪 Time is your friend; impulse is your enemy. Keep saving.',
  ];

  /// Returns today's motivational quote (changes daily)
  Future<String> getDailyQuote() async {
    final now = DateTime.now();
    final dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
    return _motivationQuotes[dayOfYear % _motivationQuotes.length];
  }

  /// Calculate current daily streak (consecutive days with ≥1 transaction)
  Future<int> getCurrentStreak() async {
    final txns = await transactionRepo.getAll();

    if (txns.isEmpty) return 0;

    final loggedDays = txns.map((t) => _dateOnly(t.date)).toSet();

    int streak = 0;
    DateTime cursor = _dateOnly(DateTime.now());

    // If not logged today, check if logged yesterday to keep streak alive
    if (!loggedDays.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }

    while (loggedDays.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  Future<bool> hasLoggedToday() async {
    final txns = await transactionRepo.getAll();

    final today = _dateOnly(DateTime.now());
    return txns.any((t) => _dateOnly(t.date) == today);
  }

  Future<DateTime?> getLastLoggedDate() async {
    final txns = await transactionRepo.getAll();

    if (txns.isEmpty) return null;
    return txns.map((t) => t.date).reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Future<int> getTotalTransactionCount() async {
    final txns = await transactionRepo.getAll();

    return txns.length;
  }

  Future<String> getUserLevel() async {
    final xp = await getXP();
    if (xp < 100) return 'Bronze Saver 🥉';
    if (xp < 500) return 'Silver Saver 🥈';
    if (xp < 2000) return 'Gold Saver 🥇';
    if (xp < 5000) return 'Platinum Saver 💎';
    return 'Diamond Saver 🏆';
  }

  Future<double> getXPProgressToNextLevel() async {
    final xp = await getXP();
    if (xp < 100) return xp / 100;
    if (xp < 500) return (xp - 100) / 400;
    if (xp < 2000) return (xp - 500) / 1500;
    if (xp < 5000) return (xp - 2000) / 3000;
    return 1.0;
  }

  Future<double> getLevelProgress() => getXPProgressToNextLevel();

  DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  static const String _xpKey = 'user_xp_score_v2';
  static const String _unlockedAchievementsKey = 'unlocked_achievements';
  static const String _todayXpKey = 'today_xp_earned';
  static const String _lastXpDateKey = 'last_xp_date';
  static const String _todayTxnCountKey = 'today_txn_count';

  static const int dailyXpCap = 100;

  Future<int> getXP() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_xpKey) ?? 0;
  }

  Future<void> addXP(int amount, {bool isTransaction = false}) async {
    if (amount <= 0) return;
    final prefs = await SharedPreferences.getInstance();

    final now = DateTime.now();
    final todayStr = '${now.year}-${now.month}-${now.day}';
    final lastDate = prefs.getString(_lastXpDateKey) ?? '';

    int todayXp = prefs.getInt(_todayXpKey) ?? 0;
    int todayTxns = prefs.getInt(_todayTxnCountKey) ?? 0;

    // Reset daily counters if date changed
    if (lastDate != todayStr) {
      todayXp = 0;
      todayTxns = 0;
      await prefs.setString(_lastXpDateKey, todayStr);
    }

    // DIMINISHING RETURNS logic for transactions
    int adjustedAmount = amount;
    if (isTransaction) {
      todayTxns++;
      await prefs.setInt(_todayTxnCountKey, todayTxns);
      if (todayTxns > 10) {
        adjustedAmount = 0; // Cap at 10 transactions per day
      } else if (todayTxns > 5) {
        adjustedAmount = (amount / 2).floor(); // 50% reward after 5 txns
      }
    }

    // DAILY XP CAP logic
    if (todayXp >= dailyXpCap) return;
    if (todayXp + adjustedAmount > dailyXpCap) {
      adjustedAmount = dailyXpCap - todayXp;
    }

    if (adjustedAmount <= 0) return;

    final currentTotal = prefs.getInt(_xpKey) ?? 0;
    await prefs.setInt(_xpKey, currentTotal + adjustedAmount);
    await prefs.setInt(_todayXpKey, todayXp + adjustedAmount);
    
    await checkAchievements();
  }

  // Reward specific actions
  Future<void> rewardTransaction() => addXP(xpPerTransaction, isTransaction: true);
  Future<void> rewardBudgetSuccess() => addXP(xpPerBudgetSuccess);
  Future<void> rewardStreakMilestone() => addXP(xpPerStreakMilestone);
  Future<void> rewardIncomeSource() => addXP(xpPerIncomeSource);
  Future<void> rewardInsightView() => addXP(xpPerInsightView);
  Future<void> rewardChallengeCompletion() => addXP(50); // High reward for behavioral discipline
  Future<void> rewardTrajectoryCorrection() => addXP(30); // Reward for responding to risk alerts
  Future<void> rewardCommitment() => addXP(20); // Reward for committing to a simulation
  Future<void> rewardAccuracyImprovement() => addXP(40); // Reward for reducing behavioral drift

  Future<List<Achievement>> getAchievements() async {
    final prefs = await SharedPreferences.getInstance();
    final unlocked = prefs.getStringList(_unlockedAchievementsKey) ?? [];

    final streak = await getCurrentStreak();
    final count = await getTotalTransactionCount();

    // Check if income exists
    final salaries = await salaryRepo.getAll();
    final incomeCount = salaries.length;


    return [
      Achievement(
        id: 'streak_7',
        title: 'Consistency I',
        description: 'Maintain a 7-day streak',
        icon: '🔥',
        category: 'Consistency',
        isUnlocked: unlocked.contains('streak_7') || streak >= 7,
        progress: (streak / 7).clamp(0.0, 1.0),
        progressLabel: '$streak/7 days',
      ),
      Achievement(
        id: 'streak_30',
        title: 'Consistency II',
        description: 'Maintain a 30-day streak',
        icon: '🏔️',
        category: 'Consistency',
        isUnlocked: unlocked.contains('streak_30') || streak >= 30,
        progress: (streak / 30).clamp(0.0, 1.0),
        progressLabel: '$streak/30 days',
      ),
      Achievement(
        id: 'txn_100',
        title: 'Century Logger',
        description: 'Log 100 transactions',
        icon: '🎯',
        category: 'Consistency',
        isUnlocked: unlocked.contains('txn_100') || count >= 100,
        progress: (count / 100).clamp(0.0, 1.0),
        progressLabel: '$count/100 logs',
      ),
      Achievement(
        id: 'income_added',
        title: 'Income Source',
        description: 'Add an income source',
        icon: '🌱',
        category: 'Growth',
        isUnlocked: unlocked.contains('income_added') || incomeCount > 0,
        progress: incomeCount > 0 ? 1.0 : 0.0,
        progressLabel: incomeCount > 0 ? 'Done' : 'Pending',
      ),
      Achievement(
        id: 'ai_chat',
        title: 'Exploration',
        description: 'Use AI Insights',
        icon: '🧠',
        category: 'Exploration',
        isUnlocked: unlocked.contains('ai_chat'),
        progress: unlocked.contains('ai_chat') ? 1.0 : 0.0,
        progressLabel: unlocked.contains('ai_chat') ? 'Unlocked' : '0/1',
      ),
    ];
  }

  Future<void> checkAchievements() async {
    final prefs = await SharedPreferences.getInstance();
    final unlocked = prefs.getStringList(_unlockedAchievementsKey) ?? [];
    final newUnlocks = List<String>.from(unlocked);

    final streak = await getCurrentStreak();
    final count = await getTotalTransactionCount();

    if (streak >= 7 && !newUnlocks.contains('streak_7')) {
      newUnlocks.add('streak_7');
      await rewardStreakMilestone();
    }
    if (streak >= 30 && !newUnlocks.contains('streak_30')) {
      newUnlocks.add('streak_30');
      await rewardStreakMilestone();
    }
    if (count >= 100 && !newUnlocks.contains('txn_100')) {
      newUnlocks.add('txn_100');
      await rewardStreakMilestone();
    }

    if (newUnlocks.length > unlocked.length) {
      await prefs.setStringList(_unlockedAchievementsKey, newUnlocks);
    }
  }

  Future<void> markAchievementUnlocked(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final unlocked = prefs.getStringList(_unlockedAchievementsKey) ?? [];
    if (!unlocked.contains(id)) {
      unlocked.add(id);
      await prefs.setStringList(_unlockedAchievementsKey, unlocked);
      await addXP(30); // Bonus for manual discoveries
    }
  }
}
