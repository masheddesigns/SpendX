import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal structured event tracker for the retention observation window.
///
/// Local-only (no analytics SDK). Aggregates per local-day in
/// SharedPreferences. Last 14 days kept.
///
/// Measurement contract (LOCKED — do not change mid-window):
///   key: `events_YYYY-MM-DD` (local timezone)
///   value: JSON map { eventName: count }
///
/// Rates (denominators are explicit and frozen):
///   CTA Tap Rate           = dailyDigestCtaClicked / dailyDigestShown
///   Review Completion Rate = (reviewItemApproved + reviewItemRejected) / reviewItemShown
///   Notification Open Rate = notificationOpened / notificationReceived
///
/// Session boundary: foreground or >30min idle starts a new session.
/// Per-session dedupe prevents inflation from rebuilds and quick resumes.
enum RetentionEvent {
  appOpen,
  dailyDigestShown,
  dailyDigestCtaClicked,
  allSetShown,
  recoveryStateShown,
  reviewItemShown,
  reviewItemApproved,
  reviewItemRejected,
  notificationReceived,
  notificationOpened,
}

class RetentionEvents {
  RetentionEvents._();
  static final instance = RetentionEvents._();

  static const _maxDays = 14;
  static const _sessionTimeout = Duration(minutes: 30);

  /// Serializes all writes to prevent lost increments under concurrency.
  Future<void> _writeQueue = Future.value();

  /// In-memory dedupe set for "shown once per session" events.
  /// Keyed as `eventName:identifier` (e.g., `reviewItemShown:abc123`).
  final Set<String> _emittedThisSession = <String>{};

  /// Last activity timestamp — used to compute session boundary.
  DateTime? _lastActivity;

  /// Begin a new session if >30min has passed since last activity.
  /// Clears the per-session dedupe set so "shown once" events can fire again.
  void _maybeRotateSession() {
    final now = DateTime.now();
    if (_lastActivity == null ||
        now.difference(_lastActivity!) > _sessionTimeout) {
      _emittedThisSession.clear();
    }
    _lastActivity = now;
  }

  /// Increment counter for [event]. Best-effort, atomic, never throws.
  ///
  /// [dedupeKey] — when provided, the event is logged at most once per
  /// session for that key. Use for "shown" events to prevent rebuild inflation.
  /// Examples:
  ///   - `reviewItemShown` with dedupeKey = item.id
  ///   - `dailyDigestShown` with dedupeKey = 'digest'
  ///   - `allSetShown` with dedupeKey = 'allset'
  Future<void> log(RetentionEvent event, {String? dedupeKey}) async {
    _maybeRotateSession();

    if (dedupeKey != null) {
      final key = '${event.name}:$dedupeKey';
      if (_emittedThisSession.contains(key)) return;
      _emittedThisSession.add(key);
    }

    // Serialize the read-modify-write to prevent lost increments
    _writeQueue = _writeQueue.then((_) => _atomicIncrement(event));
    await _writeQueue;
  }

  Future<void> _atomicIncrement(RetentionEvent event) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _todayKey();
      final raw = prefs.getString(key);
      final map = raw == null
          ? <String, int>{}
          : (jsonDecode(raw) as Map).cast<String, dynamic>().map(
                (k, v) => MapEntry(k, (v as num).toInt()),
              );
      map[event.name] = (map[event.name] ?? 0) + 1;
      await prefs.setString(key, jsonEncode(map));
      await _pruneOldDays(prefs);
    } catch (e) {
      debugPrint('[RetentionEvents] log failed: $e');
    }
  }

  /// Counts for [day] (defaults to today). Day is in LOCAL timezone.
  Future<Map<String, int>> countsFor({DateTime? day}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _keyFor(day ?? DateTime.now());
    final raw = prefs.getString(key);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).cast<String, dynamic>().map(
          (k, v) => MapEntry(k, (v as num).toInt()),
        );
  }

  /// Last N days of counts as ordered map (newest → oldest) of dayKey → counts.
  Future<Map<String, Map<String, int>>> recent({int days = 7}) async {
    final result = <String, Map<String, int>>{};
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      final d = now.subtract(Duration(days: i));
      final counts = await countsFor(day: d);
      if (counts.isNotEmpty) result[_keyFor(d)] = counts;
    }
    return result;
  }

  /// Derived rates for a single day (defaults to today).
  /// Uses the LOCKED denominator definitions documented at the top.
  Future<RetentionRates> ratesFor({DateTime? day}) async {
    final counts = await countsFor(day: day);
    return _computeRates(counts);
  }

  /// 7-day average rates — what to compare today against.
  /// Aggregates raw counts across the window, then computes rates.
  /// (This avoids averaging-of-averages distortion.)
  Future<RetentionRates> sevenDayAverage() async {
    final history = await recent(days: 7);
    final totals = <String, int>{};
    for (final dayCounts in history.values) {
      for (final entry in dayCounts.entries) {
        totals[entry.key] = (totals[entry.key] ?? 0) + entry.value;
      }
    }
    return _computeRates(totals);
  }

  RetentionRates _computeRates(Map<String, int> counts) {
    int? rate(int n, int d) => d == 0 ? null : ((n / d) * 100).round();
    final approved = counts[RetentionEvent.reviewItemApproved.name] ?? 0;
    final rejected = counts[RetentionEvent.reviewItemRejected.name] ?? 0;
    return RetentionRates(
      digestShown: counts[RetentionEvent.dailyDigestShown.name] ?? 0,
      ctaClicked: counts[RetentionEvent.dailyDigestCtaClicked.name] ?? 0,
      reviewShown: counts[RetentionEvent.reviewItemShown.name] ?? 0,
      reviewApproved: approved,
      reviewRejected: rejected,
      notifReceived: counts[RetentionEvent.notificationReceived.name] ?? 0,
      notifOpened: counts[RetentionEvent.notificationOpened.name] ?? 0,
      appOpens: counts[RetentionEvent.appOpen.name] ?? 0,
      allSetShown: counts[RetentionEvent.allSetShown.name] ?? 0,
      recoveryShown: counts[RetentionEvent.recoveryStateShown.name] ?? 0,
      ctaClickRate: rate(
        counts[RetentionEvent.dailyDigestCtaClicked.name] ?? 0,
        counts[RetentionEvent.dailyDigestShown.name] ?? 0,
      ),
      // Resolution rate: approved + rejected over shown
      reviewCompletionRate: rate(
        approved + rejected,
        counts[RetentionEvent.reviewItemShown.name] ?? 0,
      ),
      notifOpenRate: rate(
        counts[RetentionEvent.notificationOpened.name] ?? 0,
        counts[RetentionEvent.notificationReceived.name] ?? 0,
      ),
    );
  }

  Future<void> _pruneOldDays(SharedPreferences prefs) async {
    final keys = prefs.getKeys().where((k) => k.startsWith('events_')).toList();
    if (keys.length <= _maxDays) return;
    keys.sort();
    final toRemove = keys.take(keys.length - _maxDays);
    for (final k in toRemove) {
      await prefs.remove(k);
    }
  }

  // ── Local-date keys (timezone consistency) ────────────────────
  // We always use the device's LOCAL timezone for day boundaries.
  // No UTC conversions — this avoids midnight skew.
  String _todayKey() => _keyFor(DateTime.now());
  String _keyFor(DateTime d) {
    final local = d.isUtc ? d.toLocal() : d;
    return 'events_${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}

/// Derived rates for the debug panel.
class RetentionRates {
  final int digestShown;
  final int ctaClicked;
  final int reviewShown;
  final int reviewApproved;
  final int reviewRejected;
  final int notifReceived;
  final int notifOpened;
  final int appOpens;
  final int allSetShown;
  final int recoveryShown;
  final int? ctaClickRate;
  final int? reviewCompletionRate;
  final int? notifOpenRate;

  const RetentionRates({
    required this.digestShown,
    required this.ctaClicked,
    required this.reviewShown,
    required this.reviewApproved,
    required this.reviewRejected,
    required this.notifReceived,
    required this.notifOpened,
    required this.appOpens,
    required this.allSetShown,
    required this.recoveryShown,
    required this.ctaClickRate,
    required this.reviewCompletionRate,
    required this.notifOpenRate,
  });
}
