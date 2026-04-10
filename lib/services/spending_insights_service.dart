import 'package:flutter/foundation.dart' show debugPrint;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/transaction_repo.dart';
import '../utils/app_format.dart';
import 'notification_service.dart';

/// Generates smart spending insights and sends notifications.
/// - Daily: "You spent X today" (evening summary)
/// - Weekly: "Your spending is up/down X% this week vs last week"
class SpendingInsightsService {
  SpendingInsightsService._();
  static final instance = SpendingInsightsService._();

  static const _dailyNotifId = 42001;
  static const _weeklyNotifId = 42002;

  /// Check and send daily spending summary (call in evening ~9pm).
  /// Only sends if user had transactions today.
  Future<void> checkDailySummary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastDaily = prefs.getString('spending_insight_last_daily');
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // Already sent today
      if (lastDaily == today) return;

      final repo = TransactionRepo();
      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);

      // Get today's transactions
      final todayTxns = await repo.getAll();
      final todayExpenses = todayTxns.where((t) =>
          t.type == 'expense' &&
          !t.date.isBefore(startOfDay) &&
          t.date.isBefore(startOfDay.add(const Duration(days: 1))),
      ).toList();

      if (todayExpenses.isEmpty) {
        // No spending today — send a positive message
        await NotificationService.instance.showInstant(
          id: _dailyNotifId,
          title: 'Zero spending today!',
          body: 'Great discipline. Keep it up!',
        );
        await prefs.setString('spending_insight_last_daily', today);
        return;
      }

      final todayTotal = todayExpenses.fold<double>(0, (s, t) => s + t.amount);
      final txnCount = todayExpenses.length;

      // Get average daily spending (last 30 days)
      final avgDaily = await repo.getAvgDailySpending(30);

      // Build insight message
      String body;
      if (avgDaily > 0 && todayTotal > avgDaily * 1.5) {
        final overBy = ((todayTotal / avgDaily - 1) * 100).round();
        body = '${AppFormat.currency(todayTotal)} across $txnCount transactions. '
            'That\'s $overBy% above your daily average.';
      } else if (avgDaily > 0 && todayTotal < avgDaily * 0.5) {
        body = '${AppFormat.currency(todayTotal)} across $txnCount transactions. '
            'Well below your daily average — nice!';
      } else {
        body = '${AppFormat.currency(todayTotal)} across $txnCount transactions today.';
      }

      // Find top category
      final categoryTotals = <String, double>{};
      for (final t in todayExpenses) {
        final cat = t.categoryId ?? 'others';
        categoryTotals[cat] = (categoryTotals[cat] ?? 0) + t.amount;
      }
      if (categoryTotals.length > 1) {
        final topEntry = categoryTotals.entries.reduce(
            (a, b) => a.value > b.value ? a : b);
        final topPct = (topEntry.value / todayTotal * 100).round();
        if (topPct >= 40) {
          body += ' Biggest category: $topPct% of today\'s spending.';
        }
      }

      await NotificationService.instance.showInstant(
        id: _dailyNotifId,
        title: 'Today\'s Spending: ${AppFormat.currency(todayTotal)}',
        body: body,
      );

      await prefs.setString('spending_insight_last_daily', today);
      debugPrint('\u{1F4CA} Daily spending insight sent: $todayTotal');
    } catch (e) {
      debugPrint('\u26A0\uFE0F Daily insight error: $e');
    }
  }

  /// Check and send weekly spending comparison (call on Monday morning).
  Future<void> checkWeeklySummary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastWeekly = prefs.getString('spending_insight_last_weekly');
      final now = DateTime.now();
      final weekKey = '${now.year}-W${_isoWeekNumber(now)}';

      // Already sent this week
      if (lastWeekly == weekKey) return;

      final repo = TransactionRepo();

      // This week (Mon-Sun)
      final daysFromMonday = (now.weekday - 1) % 7;
      final thisMonday = DateTime(now.year, now.month, now.day - daysFromMonday);
      final lastMonday = thisMonday.subtract(const Duration(days: 7));

      final allTxns = await repo.getAll();

      final thisWeekExpenses = allTxns.where((t) =>
          t.type == 'expense' && !t.date.isBefore(thisMonday)).toList();
      final lastWeekExpenses = allTxns.where((t) =>
          t.type == 'expense' &&
          !t.date.isBefore(lastMonday) &&
          t.date.isBefore(thisMonday)).toList();

      final thisWeekTotal = thisWeekExpenses.fold<double>(0, (s, t) => s + t.amount);
      final lastWeekTotal = lastWeekExpenses.fold<double>(0, (s, t) => s + t.amount);

      if (thisWeekTotal == 0 && lastWeekTotal == 0) return;

      String title;
      String body;

      if (lastWeekTotal == 0) {
        title = 'This Week: ${AppFormat.currency(thisWeekTotal)}';
        body = '${thisWeekExpenses.length} transactions this week. '
            'No data from last week to compare.';
      } else {
        final change = ((thisWeekTotal - lastWeekTotal) / lastWeekTotal * 100).round();
        final isUp = change > 0;

        if (change.abs() <= 5) {
          title = 'Spending steady this week';
          body = '${AppFormat.currency(thisWeekTotal)} — about the same as last week '
              '(${AppFormat.currency(lastWeekTotal)}).';
        } else if (isUp) {
          title = 'Spending up $change% this week';
          body = '${AppFormat.currency(thisWeekTotal)} vs ${AppFormat.currency(lastWeekTotal)} '
              'last week. ${thisWeekExpenses.length} transactions.';
        } else {
          title = 'Spending down ${change.abs()}% this week';
          body = '${AppFormat.currency(thisWeekTotal)} vs ${AppFormat.currency(lastWeekTotal)} '
              'last week. Nice savings!';
        }
      }

      await NotificationService.instance.showInstant(
        id: _weeklyNotifId,
        title: title,
        body: body,
      );

      await prefs.setString('spending_insight_last_weekly', weekKey);
      debugPrint('\u{1F4CA} Weekly spending insight sent');
    } catch (e) {
      debugPrint('\u26A0\uFE0F Weekly insight error: $e');
    }
  }

  /// ISO 8601 week number.
  int _isoWeekNumber(DateTime date) {
    final dayOfYear = date.difference(DateTime(date.year, 1, 1)).inDays + 1;
    final weekday = date.weekday;
    return ((dayOfYear - weekday + 10) / 7).floor();
  }
}
