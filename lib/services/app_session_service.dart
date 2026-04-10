import '../core/logging/app_logger.dart';
import '../data/core/app_database.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

class AppSessionService with WidgetsBindingObserver {
  AppSessionService._();
  static final AppSessionService instance = AppSessionService._();
  static const String _table = 'app_sessions';

  String? _currentSessionId;
  DateTime? _sessionStartTime;
  bool _isServiceStarted = false;

  void init() {
    if (_isServiceStarted) return;
    WidgetsBinding.instance.addObserver(this);
    _isServiceStarted = true;
    _startSession();
  }

  void _startSession() {
    _currentSessionId = const Uuid().v4();
    _sessionStartTime = DateTime.now();
  }

  Future<void> _endSession() async {
    try {
      if (_currentSessionId == null || _sessionStartTime == null) return;

      final endTime = DateTime.now();
      final duration = endTime.difference(_sessionStartTime!).inSeconds;

      // Minimum 1 second session
      if (duration < 1) return;

      final db = await AppDatabase.instance.database;
      await db.insert(_table, {
        'id': _currentSessionId,
        'start_time': _sessionStartTime!.toIso8601String(),
        'end_time': endTime.toIso8601String(),
        'duration_seconds': duration,
        'date': _sessionStartTime!.toIso8601String().split('T')[0],
      });

      _currentSessionId = null;
      _sessionStartTime = null;
    } catch (e) {
      AppLogger.d('[SESSION] _endSession error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _endSession();
    } else if (state == AppLifecycleState.resumed) {
      _startSession();
    }
  }

  // --- Metrics ---

  Future<int> getTotalUsageSeconds() async {
    try {
      final db = await AppDatabase.instance.database;
      final table = _table;
      final result = await db.rawQuery(
        'SELECT SUM(duration_seconds) as total FROM $table',
      );
      return (result.first['total'] as num?)?.toInt() ?? 0;
    } catch (e) {
      AppLogger.d('[SESSION] getTotalUsageSeconds error: $e');
      return 0;
    }
  }

  Future<int> getSessionCount() async {
    try {
      final db = await AppDatabase.instance.database;
      final table = _table;
      final result = await db.rawQuery('SELECT COUNT(*) as count FROM $table');
      return (result.first['count'] as num?)?.toInt() ?? 0;
    } catch (e) {
      AppLogger.d('[SESSION] getSessionCount error: $e');
      return 0;
    }
  }

  Future<double> getAverageSessionSeconds() async {
    try {
      final db = await AppDatabase.instance.database;
      final table = _table;
      final result = await db.rawQuery(
        'SELECT AVG(duration_seconds) as avg FROM $table',
      );
      return (result.first['avg'] as num?)?.toDouble() ?? 0.0;
    } catch (e) {
      AppLogger.d('[SESSION] getAverageSessionSeconds error: $e');
      return 0.0;
    }
  }

  Future<int> getActiveUsageDays() async {
    try {
      final db = await AppDatabase.instance.database;
      final table = _table;
      final result = await db.rawQuery(
        'SELECT COUNT(DISTINCT date) as count FROM $table',
      );
      return (result.first['count'] as num?)?.toInt() ?? 0;
    } catch (e) {
      AppLogger.d('[SESSION] getActiveUsageDays error: $e');
      return 0;
    }
  }

  Future<int> getLongestUsageStreak() async {
    try {
      final db = await AppDatabase.instance.database;
      final table = _table;
      final result = await db.rawQuery(
        'SELECT DISTINCT date FROM $table ORDER BY date ASC',
      );
      if (result.isEmpty) return 0;

      final dates = result
          .map((r) => DateTime.parse(r['date'] as String))
          .toList();
      int currentStreak = 1;
      int maxStreak = 1;

      for (int i = 0; i < dates.length - 1; i++) {
        final diff = dates[i + 1].difference(dates[i]).inDays;
        if (diff == 1) {
          currentStreak++;
        } else if (diff > 1) {
          currentStreak = 1;
        }
        if (currentStreak > maxStreak) maxStreak = currentStreak;
      }
      return maxStreak;
    } catch (e) {
      AppLogger.d('[SESSION] getLongestUsageStreak error: $e');
      return 0;
    }
  }

  Future<List<Map<String, dynamic>>> getRecentSessions(int limit) async {
    try {
      final db = await AppDatabase.instance.database;
      return await db.query(_table, orderBy: 'start_time DESC', limit: limit);
    } catch (e) {
      AppLogger.d('[SESSION] getRecentSessions error: $e');
      return [];
    }
  }
}
