import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../data/providers.dart';
import '../../../services/gmail_integration_service.dart';
import '../../../services/live_sms_service.dart';
import '../../../services/settings_service.dart';
import '../../review_queue/providers/review_providers.dart';

/// Represents the real-time health and permission status of all automated ingestion pipelines.
class AutomaticIngestionStatus {
  final bool isLiveSmsEnabled;
  final bool hasSmsPermission;
  final bool isNotificationListenerEnabled;
  final bool isBatteryOptimizationIgnored;
  final bool isWhatsAppEnabled;
  final bool isGmailConnected;
  final bool isGmailNotificationEnabled;
  final DateTime? gmailLastSync;
  final int todayIngestedCount;
  final int pendingReviewCount;

  const AutomaticIngestionStatus({
    this.isLiveSmsEnabled = false,
    this.hasSmsPermission = false,
    this.isNotificationListenerEnabled = false,
    this.isBatteryOptimizationIgnored = false,
    this.isWhatsAppEnabled = false,
    this.isGmailConnected = false,
    this.isGmailNotificationEnabled = false,
    this.gmailLastSync,
    this.todayIngestedCount = 0,
    this.pendingReviewCount = 0,
  });

  bool get isFullyActive =>
      isLiveSmsEnabled && hasSmsPermission && isNotificationListenerEnabled;

  bool get needsAttention =>
      !isNotificationListenerEnabled || !hasSmsPermission || !isLiveSmsEnabled;

  String get statusTitle {
    if (isFullyActive) return 'Active & Listening';
    if (!isNotificationListenerEnabled && !hasSmsPermission) {
      return 'Setup Required';
    }
    if (!isNotificationListenerEnabled) {
      return 'Notification Access Needed';
    }
    if (!hasSmsPermission) return 'SMS Permission Needed';
    return 'Ingestion Paused';
  }

  String get statusSubtitle {
    if (isFullyActive) {
      if (todayIngestedCount > 0) {
        return '$todayIngestedCount transaction${todayIngestedCount == 1 ? '' : 's'} auto-captured today';
      }
      return 'Listening for Bank SMS & App Notifications in real-time';
    }
    if (!isNotificationListenerEnabled) {
      return 'Enable Notification Access to capture UPI & banking app alerts';
    }
    if (!hasSmsPermission) {
      return 'Grant SMS permission to auto-detect bank transaction messages';
    }
    return 'Turn on Live SMS to resume automatic tracking';
  }
}

class IngestionStatusNotifier extends AsyncNotifier<AutomaticIngestionStatus> {
  @override
  Future<AutomaticIngestionStatus> build() async {
    return _fetchStatus();
  }

  Future<AutomaticIngestionStatus> _fetchStatus() async {
    final liveSms = await LiveSmsService.instance.enabled;
    final hasSmsPerm = await Permission.sms.isGranted;
    final notifListener =
        await LiveSmsService.instance.isNotificationListenerEnabled();
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    final wa = SettingsService.instance.whatsappIngestionEnabled;
    final gmConnected = GmailIntegrationService.instance.isConnected;
    final gmNotif = SettingsService.instance.gmailPreviewEnabled;
    final gmLastSync = await GmailIntegrationService.instance.getLastSyncTime();
    final reviewCount = ref.watch(reviewQueueCountProvider).valueOrNull ?? 0;

    // Calculate today's auto-ingested transactions
    final allTxns = ref.watch(transactionsProvider).valueOrNull ?? const [];
    final now = DateTime.now();
    int count = 0;
    for (final t in allTxns) {
      if (t.date.year == now.year &&
          t.date.month == now.month &&
          t.date.day == now.day) {
        if (t.source == 'sms' ||
            t.source == 'push' ||
            t.source == 'notification' ||
            t.source == 'auto') {
          count++;
        }
      }
    }

    return AutomaticIngestionStatus(
      isLiveSmsEnabled: liveSms,
      hasSmsPermission: hasSmsPerm,
      isNotificationListenerEnabled: notifListener,
      isBatteryOptimizationIgnored: battery,
      isWhatsAppEnabled: wa,
      isGmailConnected: gmConnected,
      isGmailNotificationEnabled: gmNotif,
      gmailLastSync: gmLastSync,
      todayIngestedCount: count,
      pendingReviewCount: reviewCount,
    );
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _fetchStatus());
  }
}

final ingestionStatusProvider =
    AsyncNotifierProvider<IngestionStatusNotifier, AutomaticIngestionStatus>(
      IngestionStatusNotifier.new,
    );
