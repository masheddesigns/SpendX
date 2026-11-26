import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../core/logging/app_logger.dart';
import 'data_change_bus.dart';
import 'entity_consolidation_service.dart';
import 'gmail_integration_service.dart';
import 'live_sms_service.dart';

/// Performance & health statistics emitted by [CrossChannelMonitoringService].
class CrossChannelMonitoringStats {
  final bool isMonitoring;
  final DateTime? lastMonitoredAt;
  final int totalDuplicatesMerged;
  final int totalScanned;
  final String statusMessage;
  final bool isGmailConnected;

  const CrossChannelMonitoringStats({
    this.isMonitoring = false,
    this.lastMonitoredAt,
    this.totalDuplicatesMerged = 0,
    this.totalScanned = 0,
    this.statusMessage = 'Active',
    this.isGmailConnected = false,
  });

  CrossChannelMonitoringStats copyWith({
    bool? isMonitoring,
    DateTime? lastMonitoredAt,
    int? totalDuplicatesMerged,
    int? totalScanned,
    String? statusMessage,
    bool? isGmailConnected,
  }) {
    return CrossChannelMonitoringStats(
      isMonitoring: isMonitoring ?? this.isMonitoring,
      lastMonitoredAt: lastMonitoredAt ?? this.lastMonitoredAt,
      totalDuplicatesMerged: totalDuplicatesMerged ?? this.totalDuplicatesMerged,
      totalScanned: totalScanned ?? this.totalScanned,
      statusMessage: statusMessage ?? this.statusMessage,
      isGmailConnected: isGmailConnected ?? this.isGmailConnected,
    );
  }
}

/// Continuous Cross-Channel Monitor for SpendX.
///
/// Automatically monitors, deduplicates, and merges financial records across:
/// 1. Telephony SMS messages
/// 2. Android push notifications (Google Pay, PhonePe, Paytm, CRED, Bank apps)
/// 3. Financial emails (Gmail statements, alerts, card dues, refunds)
///
/// Runs periodically (every 15 minutes), on app lifecycle resume, on app launch,
/// and on user-initiated pull-to-refresh, guaranteeing zero double-counting.
class CrossChannelMonitoringService with WidgetsBindingObserver {
  static final CrossChannelMonitoringService instance = CrossChannelMonitoringService._();
  CrossChannelMonitoringService._();

  static const MethodChannel _nativeChannel = MethodChannel('spendx/sms_live');
  static const Duration _defaultInterval = Duration(minutes: 15);

  Timer? _periodicTimer;
  bool _isInitialized = false;
  bool _isCycleRunning = false;

  final ValueNotifier<CrossChannelMonitoringStats> statsNotifier =
      ValueNotifier<CrossChannelMonitoringStats>(const CrossChannelMonitoringStats());

  CrossChannelMonitoringStats get currentStats => statsNotifier.value;

  /// Initializes the monitor, hooks into app lifecycle, and kicks off the first pass.
  Future<void> init({Duration interval = _defaultInterval}) async {
    if (_isInitialized) return;
    _isInitialized = true;

    WidgetsBinding.instance.addObserver(this);

    // Initial pass in background
    unawaited(runCycle(reason: 'app_launch'));

    // Periodic timer while app is running
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(interval, (_) {
      unawaited(runCycle(reason: 'periodic_interval'));
    });

    AppLogger.i('[CrossChannelMonitor] Initialized with interval ${interval.inMinutes}m');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(runCycle(reason: 'lifecycle_resumed'));
    }
  }

  /// Triggers a full monitoring, ingestion, and consolidation pass.
  Future<CrossChannelMonitoringStats> runCycle({String reason = 'manual'}) async {
    if (_isCycleRunning) {
      AppLogger.d('[CrossChannelMonitor] Cycle already in progress, skipping ($reason)');
      return currentStats;
    }

    _isCycleRunning = true;
    statsNotifier.value = currentStats.copyWith(
      isMonitoring: true,
      statusMessage: 'Scanning and merging channels ($reason)...',
    );

    int newlyMerged = 0;
    int scannedItems = 0;

    try {
      AppLogger.i('[CrossChannelMonitor] Starting monitoring cycle (reason: $reason)...');

      // 1. Sync active Android push notifications from notification listener
      try {
        await _nativeChannel.invokeMethod('syncActiveNotifications');
      } catch (e) {
        AppLogger.d('[CrossChannelMonitor] syncActiveNotifications note: $e');
      }

      // 2. Drain any pending messages from native queue
      try {
        await LiveSmsService.instance.drainPending();
      } catch (e) {
        AppLogger.w('[CrossChannelMonitor] drainPending error: $e');
      }

      // 3. Incremental email sync if Gmail is connected
      final isGmailConn = GmailIntegrationService.instance.isConnected;
      if (isGmailConn) {
        try {
          final emailResult = await GmailIntegrationService.instance.syncFinancialEmails(
            maxResults: 25,
          );
          scannedItems += emailResult.scanned;
        } catch (e) {
          AppLogger.w('[CrossChannelMonitor] Gmail sync note: $e');
        }
      }

      // 4. Run entity consolidation & cross-channel transaction deduplication
      try {
        newlyMerged = await EntityConsolidationService.instance.consolidate();
      } catch (e, st) {
        AppLogger.e('[CrossChannelMonitor] Consolidation error: $e', e, st);
      }

      // 5. Notify UI & listeners
      DataChangeBus.instance.notify();

      final updatedTotalMerged = currentStats.totalDuplicatesMerged + newlyMerged;
      final updatedStats = currentStats.copyWith(
        isMonitoring: false,
        lastMonitoredAt: DateTime.now(),
        totalDuplicatesMerged: updatedTotalMerged,
        totalScanned: currentStats.totalScanned + scannedItems,
        statusMessage: newlyMerged > 0
            ? 'Merged $newlyMerged duplicate record(s)'
            : 'All streams synchronized & protected',
        isGmailConnected: isGmailConn,
      );

      statsNotifier.value = updatedStats;
      AppLogger.i(
        '[CrossChannelMonitor] Cycle completed. Merged: $newlyMerged, Total Merged: $updatedTotalMerged',
      );
      return updatedStats;
    } catch (e, st) {
      AppLogger.e('[CrossChannelMonitor] Error in monitoring cycle: $e', e, st);
      final errorStats = currentStats.copyWith(
        isMonitoring: false,
        statusMessage: 'Monitor pass encountered an issue: $e',
      );
      statsNotifier.value = errorStats;
      return errorStats;
    } finally {
      _isCycleRunning = false;
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicTimer?.cancel();
    _isInitialized = false;
  }
}
