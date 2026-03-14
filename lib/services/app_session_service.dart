import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'database_helper.dart';
import 'dart:async';

class AppSessionService with WidgetsBindingObserver {
  AppSessionService._();
  static final AppSessionService instance = AppSessionService._();

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
    if (_currentSessionId == null || _sessionStartTime == null) return;

    final endTime = DateTime.now();
    final duration = endTime.difference(_sessionStartTime!).inSeconds;

    // Minimum 1 second session
    if (duration < 1) return;

    final db = await DatabaseHelper.instance.database;
    await db.insert(
      DatabaseHelper.tableAppSessions,
      {
        'id': _currentSessionId,
        'start_time': _sessionStartTime!.toIso8601String(),
        'end_time': endTime.toIso8601String(),
        'duration_seconds': duration,
        'date': _sessionStartTime!.toIso8601String().split('T')[0],
      },
    );

    _currentSessionId = null;
    _sessionStartTime = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _endSession();
    } else if (state == AppLifecycleState.resumed) {
      _startSession();
    }
  }

  // --- Metrics ---

  Future<int> getTotalUsageSeconds() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery('SELECT SUM(duration_seconds) as total FROM ${DatabaseHelper.tableAppSessions}');
    return (result.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<int> getSessionCount() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM ${DatabaseHelper.tableAppSessions}');
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<double> getAverageSessionSeconds() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery('SELECT AVG(duration_seconds) as avg FROM ${DatabaseHelper.tableAppSessions}');
    return (result.first['avg'] as num?)?.toDouble() ?? 0.0;
  }

  Future<int> getActiveUsageDays() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery('SELECT COUNT(DISTINCT date) as count FROM ${DatabaseHelper.tableAppSessions}');
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<int> getLongestUsageStreak() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery('SELECT DISTINCT date FROM ${DatabaseHelper.tableAppSessions} ORDER BY date ASC');
    if (result.isEmpty) return 0;

    final dates = result.map((r) => DateTime.parse(r['date'] as String)).toList();
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
  }

  Future<List<Map<String, dynamic>>> getRecentSessions(int limit) async {
    final db = await DatabaseHelper.instance.database;
    return await db.query(
      DatabaseHelper.tableAppSessions,
      orderBy: 'start_time DESC',
      limit: limit,
    );
  }
}
