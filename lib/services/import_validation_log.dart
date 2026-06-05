import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// Local validation telemetry for the Smart Import accuracy window.
///
/// Captures only what's needed to compute the four success metrics
/// without bias:
///   - Amount accuracy   = (total - amountEdits) / total
///   - Merchant accuracy = (total - merchantEdits) / total
///   - Correction rate   = corrected / total
///   - Avg latency       = average ms (share → preview shown)
///
/// Single source of truth — no manual tracking, no analytics SDK.
class ImportValidationLog {
  ImportValidationLog._();
  static final instance = ImportValidationLog._();

  static const _kCounters = 'import_validation_counters';
  static const _kLatencies = 'import_validation_latencies_ms';
  static const _kPendingStart = 'import_validation_pending_start';

  // Single in-flight session: each share starts a timer and ends when the
  // preview is shown. Only one can be open at a time (same as our pipeline).
  DateTime? _sessionStart;
  // Snapshot of the parsed values at preview-shown time, so save() can
  // detect what the user changed.
  double? _parsedAmount;
  String? _parsedMerchant;

  /// Call when share intent / image / text is received — starts the timer.
  void shareReceived() {
    _sessionStart = DateTime.now();
  }

  /// Call when the preview screen first becomes visible.
  /// Records latency + the parsed values to compare against on save.
  Future<void> previewShown({
    required double parsedAmount,
    required String? parsedMerchant,
  }) async {
    _parsedAmount = parsedAmount;
    _parsedMerchant = parsedMerchant?.trim();
    if (_sessionStart != null) {
      final ms = DateTime.now().difference(_sessionStart!).inMilliseconds;
      await _appendLatency(ms);
      _sessionStart = null;
    }
    await _bumpCounter('total');
  }

  /// Call right before the transaction is saved with the FINAL values.
  /// Records what (if anything) the user changed.
  Future<void> recordSave({
    required double finalAmount,
    required String? finalMerchant,
  }) async {
    final snapshotAmount = _parsedAmount;
    final snapshotMerchant = _parsedMerchant ?? '';
    final final_ = finalMerchant?.trim() ?? '';

    bool corrected = false;

    if (snapshotAmount != null &&
        (snapshotAmount - finalAmount).abs() >= 0.01) {
      await _bumpCounter('amountEdits');
      corrected = true;
    }
    if (snapshotMerchant.toLowerCase() != final_.toLowerCase()) {
      await _bumpCounter('merchantEdits');
      corrected = true;
    }
    if (corrected) {
      await _bumpCounter('corrected');
    }

    _parsedAmount = null;
    _parsedMerchant = null;
  }

  /// Returns a snapshot of accumulated metrics for the debug panel.
  Future<ImportValidationStats> snapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kCounters);
    final c = raw == null
        ? <String, int>{}
        : (jsonDecode(raw) as Map).cast<String, dynamic>().map(
              (k, v) => MapEntry(k, (v as num).toInt()),
            );
    final lats = (prefs.getStringList(_kLatencies) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toList();

    final total = c['total'] ?? 0;
    final amountEdits = c['amountEdits'] ?? 0;
    final merchantEdits = c['merchantEdits'] ?? 0;
    final corrected = c['corrected'] ?? 0;

    int? rate(int correct, int total) =>
        total == 0 ? null : ((correct / total) * 100).round();
    final amountCorrect = total - amountEdits;
    final merchantCorrect = total - merchantEdits;

    final avgLatency = lats.isEmpty
        ? null
        : (lats.reduce((a, b) => a + b) / lats.length).round();

    return ImportValidationStats(
      total: total,
      amountEdits: amountEdits,
      merchantEdits: merchantEdits,
      corrected: corrected,
      amountAccuracy: rate(amountCorrect, total),
      merchantAccuracy: rate(merchantCorrect, total),
      correctionRate: total == 0 ? null : ((corrected / total) * 100).round(),
      avgLatencyMs: avgLatency,
      sampleSize: lats.length,
    );
  }

  /// Reset all counters — used between validation runs.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCounters);
    await prefs.remove(_kLatencies);
    await prefs.remove(_kPendingStart);
    _sessionStart = null;
    _parsedAmount = null;
    _parsedMerchant = null;
  }

  // ── Internals ─────────────────────────────────────────────────────

  Future<void> _bumpCounter(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCounters);
      final map = raw == null
          ? <String, int>{}
          : (jsonDecode(raw) as Map).cast<String, dynamic>().map(
                (k, v) => MapEntry(k, (v as num).toInt()),
              );
      map[key] = (map[key] ?? 0) + 1;
      await prefs.setString(_kCounters, jsonEncode(map));
    } catch (e) {
      debugPrint('[ImportValidationLog] bump failed: $e');
    }
  }

  Future<void> _appendLatency(int ms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = (prefs.getStringList(_kLatencies) ?? <String>[]).toList();
      list.add(ms.toString());
      // Keep last 200 samples — enough for stable average, bounded memory
      while (list.length > 200) {
        list.removeAt(0);
      }
      await prefs.setStringList(_kLatencies, list);
    } catch (e) {
      debugPrint('[ImportValidationLog] latency failed: $e');
    }
  }
}

class ImportValidationStats {
  final int total;
  final int amountEdits;
  final int merchantEdits;
  final int corrected;
  final int? amountAccuracy; // %
  final int? merchantAccuracy; // %
  final int? correctionRate; // %
  final int? avgLatencyMs;
  final int sampleSize;

  const ImportValidationStats({
    required this.total,
    required this.amountEdits,
    required this.merchantEdits,
    required this.corrected,
    required this.amountAccuracy,
    required this.merchantAccuracy,
    required this.correctionRate,
    required this.avgLatencyMs,
    required this.sampleSize,
  });
}
