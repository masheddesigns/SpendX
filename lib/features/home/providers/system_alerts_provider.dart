import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/data_audit_service.dart';
import '../../review_queue/providers/review_providers.dart';
import '../../sms/services/sms_safe_mode.dart';

/// Aggregated system status for the Home screen.
/// Combines: review queue, drift alerts, safe mode, last sync, data health.
class SystemAlerts {
  final int reviewCount;
  final bool safeModeActive;
  final String? lastSyncAgo;
  final int lastSyncCount;
  final String? driftMessage;
  final int auditIssueCount;

  const SystemAlerts({
    this.reviewCount = 0,
    this.safeModeActive = false,
    this.lastSyncAgo,
    this.lastSyncCount = 0,
    this.driftMessage,
    this.auditIssueCount = 0,
  });

  bool get hasAlerts =>
      reviewCount > 0 || safeModeActive || driftMessage != null ||
      auditIssueCount > 0;

  bool get hasSync => lastSyncAgo != null;
}

final systemAlertsProvider = FutureProvider<SystemAlerts>((ref) async {
  // Review count
  final reviewCount =
      await ref.watch(reviewQueueCountProvider.future).catchError((_) => 0);

  // Safe mode
  final safeModeActive = SmsSafeMode.instance.isEnabled;

  // Audit issues (lightweight count)
  int auditCount = 0;
  try {
    auditCount = await DataAuditService.instance.getIssueCount();
  } catch (_) {}

  // Last sync info
  final prefs = await SharedPreferences.getInstance();
  final lastImportStr = prefs.getString('sms_last_import');
  final lastImportCount = prefs.getInt('sms_last_import_count') ?? 0;

  String? lastSyncAgo;
  if (lastImportStr != null) {
    try {
      final lastDate = DateTime.parse(lastImportStr);
      final diff = DateTime.now().difference(lastDate);
      if (diff.inMinutes < 1) {
        lastSyncAgo = 'Just now';
      } else if (diff.inMinutes < 60) {
        lastSyncAgo = '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        lastSyncAgo = '${diff.inHours}h ago';
      } else {
        lastSyncAgo = '${diff.inDays}d ago';
      }
    } catch (_) {}
  }

  return SystemAlerts(
    reviewCount: reviewCount,
    safeModeActive: safeModeActive,
    lastSyncAgo: lastSyncAgo,
    lastSyncCount: lastImportCount,
    auditIssueCount: auditCount,
  );
});
