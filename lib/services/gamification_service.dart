import 'database_helper.dart';

class GamificationService {
  GamificationService._();
  static final GamificationService instance = GamificationService._();

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
  String getDailyQuote() {
    final dayOfYear = DateTime.now().difference(DateTime(DateTime.now().year, 1, 1)).inDays;
    return _motivationQuotes[dayOfYear % _motivationQuotes.length];
  }

  /// Calculate current daily streak (consecutive days with ≥1 transaction)
  Future<int> getCurrentStreak() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    if (txns.isEmpty) return 0;

    // Build a set of unique DATE strings (yyyy-MM-dd)
    final loggedDays = txns
        .map((t) => _dateOnly(t.date))
        .toSet();

    int streak = 0;
    DateTime cursor = _dateOnly(DateTime.now());

    while (loggedDays.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Date of the most recently added transaction
  Future<DateTime?> getLastLoggedDate() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    if (txns.isEmpty) return null;
    // They come back ordered by date DESC
    return txns.first.date;
  }

  /// Total transaction count
  Future<int> getTotalTransactionCount() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    return txns.length;
  }

  /// Calculates user level/tier based on total transactions
  Future<String> getUserLevel() async {
    final count = await getTotalTransactionCount();
    if (count < 10) return 'Bronze Saver 🥉';
    if (count < 50) return 'Silver Saver 🥈';
    if (count < 150) return 'Gold Saver 🥇';
    if (count < 500) return 'Platinum Saver 💎';
    return 'Diamond Saver 🏆';
  }

  /// All-time total spend
  Future<double> getTotalSpentAllTime() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    return txns
        .where((t) => t.type == 'expense')
        .fold<double>(0.0, (double sum, t) => sum + t.amount);
  }

  /// Whether user logged a transaction today
  Future<bool> hasLoggedToday() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    if (txns.isEmpty) return false;
    final today = _dateOnly(DateTime.now());
    return txns.any((t) => _dateOnly(t.date) == today);
  }

  /// App installation / first usage date (approx based on oldest transaction)
  Future<DateTime?> getJoinDate() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    if (txns.isEmpty) return null;
    // Database returns order by date DESC, so the last element is the oldest
    return txns.last.date;
  }

  /// Calculates total active days using the app (unique dates of transactions)
  Future<int> getTotalActiveDays() async {
    final txns = await DatabaseHelper.instance.getAllTransactions();
    if (txns.isEmpty) return 0;
    
    final loggedDays = txns
        .map((t) => _dateOnly(t.date))
        .toSet();
        
    return loggedDays.length;
  }

  DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}
