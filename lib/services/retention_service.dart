import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'haptic_service.dart';
import 'money_score_service.dart';
import 'notification_service.dart';

/// Centralized retention system.
///
/// Owns:
///   - Daily streak (breaks after 48h)
///   - Daily completion state ("all set for today")
///   - Micro-reward feedback (+N Money Score toasts)
///   - Weekly accuracy snapshots (for long-term improvement framing)
///
/// Lightweight — pure SharedPreferences, no DB, no background work.
class RetentionService {
  RetentionService._();
  static final instance = RetentionService._();

  static const _kStreak = 'retention_streak_count';
  static const _kStreakDate = 'retention_streak_last_day'; // YYYY-MM-DD
  static const _kAccuracyHistory = 'retention_accuracy_history';
  static const _kLastActiveAt = 'retention_last_active_at';
  static const _kRecoveryShownAt = 'retention_recovery_shown_at';
  static const _kRewardCount = 'retention_reward_count';

  /// Mark today as active. Increments streak if last day was yesterday,
  /// resets if gap >= 48h. Idempotent within the same day.
  Future<int> markActiveToday() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayKey();
    final lastDay = prefs.getString(_kStreakDate);

    int streak = prefs.getInt(_kStreak) ?? 0;

    if (lastDay == today) {
      // Already counted today — no-op
      return streak;
    }

    final yesterday = _dayKeyFor(DateTime.now().subtract(const Duration(days: 1)));
    if (lastDay == yesterday) {
      streak += 1;
    } else {
      // Gap > 1 day → reset (soft — caller can detect via isReturningAfterBreak)
      streak = 1;
    }

    await prefs.setInt(_kStreak, streak);
    await prefs.setString(_kStreakDate, today);
    await prefs.setString(_kLastActiveAt, DateTime.now().toIso8601String());
    return streak;
  }

  /// True if the user is returning after 2+ days of inactivity AND we
  /// haven't already shown them the recovery prompt today.
  /// Used by DailyDigestCard for the soft "welcome back" state.
  Future<bool> isReturningAfterBreak() async {
    final prefs = await SharedPreferences.getInstance();
    final lastActiveIso = prefs.getString(_kLastActiveAt);
    if (lastActiveIso == null) return false;
    final lastActive = DateTime.tryParse(lastActiveIso);
    if (lastActive == null) return false;
    final daysSince = DateTime.now().difference(lastActive).inHours / 24;
    if (daysSince < 2) return false;

    // Suppress repeat shows on the same day
    final shownAt = prefs.getString(_kRecoveryShownAt);
    if (shownAt == _todayKey()) return false;

    await prefs.setString(_kRecoveryShownAt, _todayKey());
    return true;
  }

  /// Current streak count (0 if no recent activity).
  Future<int> getStreak() async {
    final prefs = await SharedPreferences.getInstance();
    final lastDay = prefs.getString(_kStreakDate);
    if (lastDay == null) return 0;
    final lastDate = DateTime.tryParse('${lastDay}T00:00:00');
    if (lastDate == null) return 0;
    final daysSince = DateTime.now().difference(lastDate).inHours / 24;
    if (daysSince > 2) return 0; // 48h break
    return prefs.getInt(_kStreak) ?? 0;
  }

  /// Last active time (for re-engagement decisions).
  Future<DateTime?> getLastActive() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString(_kLastActiveAt);
    return iso == null ? null : DateTime.tryParse(iso);
  }

  /// Whether the user has been inactive for >24h.
  Future<bool> isInactive() async {
    final last = await getLastActive();
    if (last == null) return false;
    return DateTime.now().difference(last).inHours >= 24;
  }

  /// Snapshot today's parser accuracy. Keeps last 14 days.
  /// Format: "YYYY-MM-DD:NN" entries comma-separated.
  Future<void> snapshotAccuracy(double accuracy) async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayKey();
    final entries = (prefs.getStringList(_kAccuracyHistory) ?? <String>[])
        .where((e) => !e.startsWith('$today:'))
        .toList();
    entries.add('$today:${accuracy.toStringAsFixed(0)}');
    if (entries.length > 14) entries.removeRange(0, entries.length - 14);
    await prefs.setStringList(_kAccuracyHistory, entries);
  }

  /// Returns (oldestAccuracy, latestAccuracy) over last 7 days.
  /// null if not enough data.
  Future<(int oldest, int latest)?> accuracyDelta() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = prefs.getStringList(_kAccuracyHistory) ?? <String>[];
    if (entries.length < 2) return null;
    int? oldest;
    int? latest;
    for (final e in entries) {
      final parts = e.split(':');
      if (parts.length != 2) continue;
      final v = int.tryParse(parts[1]);
      if (v == null) continue;
      oldest ??= v;
      latest = v;
    }
    if (oldest == null || latest == null) return null;
    return (oldest, latest);
  }

  /// Awards money score points + shows a micro-reward toast.
  /// Called after a meaningful user action (review, correction, fix, approve).
  ///
  /// Evolves over time:
  ///   - First ~30 actions → numeric badge (+3) builds the habit
  ///   - After 30 actions → meaning-only ("Helps me recognize Zomato faster")
  ///
  /// [hint] — short merchant/category hint for personalised meaning copy.
  static Future<void> rewardAction({
    required BuildContext context,
    required int points,
    required String message,
    String? hint,
  }) async {
    // Persist score change (best-effort, don't block UI)
    if (points > 0) {
      MoneyScoreService.instance.reward(points);
    } else if (points < 0) {
      MoneyScoreService.instance.penalize(-points);
    }
    HapticService.instance.tap();

    // Track reward count for language evolution
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(_kRewardCount) ?? 0) + 1;
    await prefs.setInt(_kRewardCount, count);
    final isMature = count >= 30;

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 2),
        content: Row(
          children: [
            if (!isMature) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  points >= 0 ? '+$points' : '$points',
                  style: const TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ] else ...[
              const Icon(Icons.auto_awesome, color: Colors.green, size: 16),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                isMature ? _maturedMessage(message, hint) : message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mature reward copy — meaning, not points.
  /// Rotates so it doesn't feel scripted.
  static String _maturedMessage(String fallback, String? hint) {
    final pool = <String>[
      if (hint != null) 'Nice — that helps me recognize $hint faster',
      'You\'re training the system well',
      'Got it — I\'ll remember this pattern',
      'Each correction makes the system smarter',
    ];
    final index = DateTime.now().minute % pool.length;
    return pool[index];
  }

  /// Schedule a single re-engagement notification for ~24h from now.
  /// Idempotent — calling repeatedly only re-arms it (no spam).
  ///
  /// IMPORTANT: only schedules if something is actually actionable.
  /// "Just checking in" notifications degrade trust — we skip them.
  ///
  /// Send when:
  ///   - pendingReviews > 0, OR
  ///   - hasCriticalSignal == true
  Future<void> scheduleReengagementCheck({
    int pendingReviews = 0,
    bool hasCriticalSignal = false,
  }) async {
    if (pendingReviews <= 0 && !hasCriticalSignal) {
      // Nothing actionable — don't notify. Cancel any previously scheduled.
      await NotificationService.instance.cancel(51001);
      return;
    }

    final body = pendingReviews > 0
        ? '$pendingReviews transaction${pendingReviews == 1 ? '' : 's'} need your confirmation'
        : 'You\'re drifting above your usual spending';

    final at = DateTime.now().add(const Duration(hours: 24));
    await NotificationService.instance.scheduleNotification(
      id: 51001,
      title: 'SpendX',
      body: body,
      scheduledDate: at,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────
  static String _todayKey() => _dayKeyFor(DateTime.now());
  static String _dayKeyFor(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
