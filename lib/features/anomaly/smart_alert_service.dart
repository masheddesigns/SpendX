import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/notification_service.dart';
import 'anomaly_model.dart';

/// Triggers notifications for high-severity anomalies with 24h dedup.
/// Safe to call on every app open — duplicate alerts are suppressed.
class SmartAlertService {
  static final SmartAlertService instance = SmartAlertService._();
  SmartAlertService._();

  static const _prefix = 'smart_alert_';
  static const _dedupHours = 24;

  /// Check anomalies and fire notifications for high-severity ones.
  /// Each anomaly type + date combo is fired at most once per 24h.
  Future<void> check(List<Anomaly> anomalies) async {
    final highSeverity = anomalies
        .where((a) => a.severity == AnomalySeverity.high)
        .toList();

    if (highSeverity.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    for (final anomaly in highSeverity) {
      final key = '$_prefix${anomaly.type.name}_${now.year}_${now.month}_${now.day}';
      final lastFired = prefs.getString(key);

      if (lastFired != null) {
        final lastTime = DateTime.tryParse(lastFired);
        if (lastTime != null &&
            now.difference(lastTime).inHours < _dedupHours) {
          continue; // Already fired within 24h
        }
      }

      // Fire notification
      await NotificationService.instance.showInstant(
        id: anomaly.type.index + 50000, // Unique ID range for anomaly alerts
        title: anomaly.title,
        body: anomaly.suggestion ?? anomaly.description,
      );

      // Record fire time
      await prefs.setString(key, now.toIso8601String());
      debugPrint('🔔 Smart alert fired: ${anomaly.title}');
    }
  }
}
