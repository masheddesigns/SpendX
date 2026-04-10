import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight structured logging for the SMS pipeline.
///
/// Logs are stored in-memory (last 200) for debug screen access.
/// Production: logs only failures + skips (not every success).
/// Debug mode: logs everything.
class SmsPipelineLogger {
  SmsPipelineLogger._();
  static final instance = SmsPipelineLogger._();

  static const _maxLogs = 200;
  final List<PipelineLogEntry> _logs = [];
  bool _debugMode = false;

  /// Pipeline stats for current session.
  int totalProcessed = 0;
  int totalInserted = 0;
  int totalSkipped = 0;
  int totalFailed = 0;
  int totalReview = 0;

  List<PipelineLogEntry> get logs => List.unmodifiable(_logs);

  void setDebugMode(bool enabled) => _debugMode = enabled;

  /// Log a pipeline event. In production, only logs non-success events.
  void log({
    required String stage,
    required PipelineResult result,
    String? smsId,
    String? reason,
    double? amount,
    String? merchant,
    String? type,
    double? confidence,
    int? durationMs,
  }) {
    totalProcessed++;
    switch (result) {
      case PipelineResult.success:
        totalInserted++;
      case PipelineResult.skipped:
        totalSkipped++;
      case PipelineResult.failed:
        totalFailed++;
      case PipelineResult.review:
        totalReview++;
    }

    // Production: only log failures, skips, and reviews
    // Debug: log everything
    if (!_debugMode && result == PipelineResult.success) return;

    final entry = PipelineLogEntry(
      timestamp: DateTime.now(),
      stage: stage,
      result: result,
      smsId: smsId,
      reason: reason,
      amount: amount,
      merchant: merchant,
      type: type,
      confidence: confidence,
      durationMs: durationMs,
    );

    _logs.add(entry);
    if (_logs.length > _maxLogs) _logs.removeAt(0);

    // Also print to debug console
    debugPrint('\u{1F4CA} [$stage] ${result.name}'
        '${reason != null ? " ($reason)" : ""}'
        '${amount != null ? " \u{20B9}$amount" : ""}'
        '${merchant != null ? " [$merchant]" : ""}');
  }

  /// Get session stats as a map (for display).
  Map<String, int> get stats => {
    'Processed': totalProcessed,
    'Inserted': totalInserted,
    'Skipped': totalSkipped,
    'Review': totalReview,
    'Failed': totalFailed,
  };

  /// Reset session stats.
  void resetStats() {
    totalProcessed = 0;
    totalInserted = 0;
    totalSkipped = 0;
    totalFailed = 0;
    totalReview = 0;
    _logs.clear();
  }

  /// Persist import history (last import timestamp + counts).
  Future<void> saveImportHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sms_last_import', DateTime.now().toIso8601String());
    await prefs.setInt('sms_last_import_count', totalInserted);
    await prefs.setInt('sms_last_import_skipped', totalSkipped);
    await prefs.setInt('sms_last_import_failed', totalFailed);
  }

  /// Get last import info for UI display.
  static Future<Map<String, dynamic>> getLastImportInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'lastImport': prefs.getString('sms_last_import'),
      'count': prefs.getInt('sms_last_import_count') ?? 0,
      'skipped': prefs.getInt('sms_last_import_skipped') ?? 0,
      'failed': prefs.getInt('sms_last_import_failed') ?? 0,
    };
  }
}

enum PipelineResult { success, skipped, failed, review }

class PipelineLogEntry {
  final DateTime timestamp;
  final String stage;
  final PipelineResult result;
  final String? smsId;
  final String? reason;
  final double? amount;
  final String? merchant;
  final String? type;
  final double? confidence;
  final int? durationMs;

  const PipelineLogEntry({
    required this.timestamp,
    required this.stage,
    required this.result,
    this.smsId,
    this.reason,
    this.amount,
    this.merchant,
    this.type,
    this.confidence,
    this.durationMs,
  });
}
