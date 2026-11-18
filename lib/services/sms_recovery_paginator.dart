import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/logging/app_logger.dart';

/// Represents a single decoded native recovery inbox page.
class SmsRecoveryPage {
  final List<dynamic> messages;
  final bool hasMore;
  final int? nextBeforeId;

  const SmsRecoveryPage({
    required this.messages,
    required this.hasMore,
    this.nextBeforeId,
  });

  factory SmsRecoveryPage.fromMap(Map<dynamic, dynamic>? map) {
    final raw = map?['messages'];
    final next = map?['nextBeforeId'];
    return SmsRecoveryPage(
      messages: raw is List ? List<dynamic>.from(raw) : const [],
      hasMore: map?['hasMore'] == true,
      nextBeforeId: next is num ? next.toInt() : null,
    );
  }
}

/// Durable checkpoint for the Phase 1.4 recovery scan.
///
/// Ensures crash-safety and interruption recovery:
/// - [startMaxId] is captured once at the start of a recovery pass and remains immutable.
/// - [sevenDayThresholdMs] is the fixed lower timestamp boundary for the active pass.
/// - [lastProcessedId] is the continuation cursor (`_id < lastProcessedId`), advanced
///   only after messages on a page are successfully processed.
/// - [isComplete] indicates whether the recovery pass reached the terminal page.
class SmsRecoveryCheckpoint {
  final int startMaxId;
  final int sevenDayThresholdMs;
  final int? lastProcessedId;
  final bool isComplete;
  final int? lastScanAtMs;

  const SmsRecoveryCheckpoint({
    required this.startMaxId,
    required this.sevenDayThresholdMs,
    this.lastProcessedId,
    this.isComplete = false,
    this.lastScanAtMs,
  });

  Map<String, dynamic> toJson() => {
    'startMaxId': startMaxId,
    'sevenDayThresholdMs': sevenDayThresholdMs,
    'lastProcessedId': lastProcessedId,
    'isComplete': isComplete,
    'lastScanAtMs': lastScanAtMs,
  };

  factory SmsRecoveryCheckpoint.fromJson(Map<String, dynamic> json) {
    return SmsRecoveryCheckpoint(
      startMaxId: (json['startMaxId'] as num).toInt(),
      sevenDayThresholdMs: (json['sevenDayThresholdMs'] as num).toInt(),
      lastProcessedId: (json['lastProcessedId'] as num?)?.toInt(),
      isComplete: json['isComplete'] == true,
      lastScanAtMs: (json['lastScanAtMs'] as num?)?.toInt(),
    );
  }

  SmsRecoveryCheckpoint copyWith({
    int? startMaxId,
    int? sevenDayThresholdMs,
    int? lastProcessedId,
    bool? isComplete,
    int? lastScanAtMs,
  }) {
    return SmsRecoveryCheckpoint(
      startMaxId: startMaxId ?? this.startMaxId,
      sevenDayThresholdMs: sevenDayThresholdMs ?? this.sevenDayThresholdMs,
      lastProcessedId: lastProcessedId ?? this.lastProcessedId,
      isComplete: isComplete ?? this.isComplete,
      lastScanAtMs: lastScanAtMs ?? this.lastScanAtMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SmsRecoveryCheckpoint &&
          runtimeType == other.runtimeType &&
          startMaxId == other.startMaxId &&
          sevenDayThresholdMs == other.sevenDayThresholdMs &&
          lastProcessedId == other.lastProcessedId &&
          isComplete == other.isComplete;

  @override
  int get hashCode =>
      startMaxId.hashCode ^
      sevenDayThresholdMs.hashCode ^
      lastProcessedId.hashCode ^
      isComplete.hashCode;

  @override
  String toString() =>
      'SmsRecoveryCheckpoint(startMaxId: $startMaxId, 7dThresh: $sevenDayThresholdMs, lastId: $lastProcessedId, complete: $isComplete)';
}

/// SharedPreferences-backed storage for Phase 1.4 recovery checkpoints.
/// Completely decoupled from Phase 1.3 `SmsInboxWatermarkStore`.
class SmsRecoveryCheckpointStore {
  static const String defaultKey = 'spendx.sms.recovery_checkpoint';

  static String? _testKeyOverride;

  /// Test-only hook to override the checkpoint key in isolated test environments.
  /// Strictly prohibited in release builds.
  static void setTestKeyOverride(String? key) {
    if (const bool.fromEnvironment('dart.vm.product')) {
      throw UnsupportedError('setTestKeyOverride is strictly prohibited in release builds');
    }
    _testKeyOverride = key;
  }

  /// The active key used for recovery checkpoint persistence.
  static String get activeKey => _testKeyOverride ?? defaultKey;

  final String key;

  SmsRecoveryCheckpointStore({String? key}) : key = key ?? activeKey;

  /// Test hook used to simulate storage failures or interruptions.
  @visibleForTesting
  static Future<bool> Function(
    SharedPreferences prefs,
    String key,
    String value,
  )? testSaveInterceptor;

  Future<SmsRecoveryCheckpoint?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      return SmsRecoveryCheckpoint.fromJson(jsonDecode(raw));
    } catch (e) {
      AppLogger.w('[SmsRecoveryCheckpointStore] Could not load checkpoint: $e');
      return null;
    }
  }

  Future<bool> save(SmsRecoveryCheckpoint checkpoint) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(checkpoint.toJson());
      if (testSaveInterceptor != null) {
        return await testSaveInterceptor!(prefs, key, encoded);
      }
      return await prefs.setString(key, encoded);
    } catch (e) {
      AppLogger.e('[SmsRecoveryCheckpointStore] Could not save checkpoint', e);
      return false;
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (e) {
      AppLogger.w('[SmsRecoveryCheckpointStore] Could not clear checkpoint: $e');
    }
  }
}

/// Recovery keyset paginator implementing monotonic `_id DESC` scanning.
///
/// Guaranteed Properties:
/// 1. Immutable snapshot ceiling: captures `startMaxId` once and retains it until completion.
/// 2. Monotonic keyset progression: `_id < beforeId` with no offset calculation.
/// 3. Inclusive 7-day timestamp boundary: `date >= sevenDayThresholdMs`.
/// 4. Interruption resilience: resumes using the exact `startMaxId` and `lastProcessedId`.
class SmsRecoveryPaginator {
  final SmsRecoveryCheckpointStore store;

  SmsRecoveryPaginator({SmsRecoveryCheckpointStore? store})
      : store = store ?? SmsRecoveryCheckpointStore();

  static const int defaultPageSize = 300;
  static const int maxPageSize = 500;
  static const Duration defaultLookbackWindow = Duration(days: 7);

  /// Executes a recovery scan loop.
  ///
  /// Parameters:
  /// - [fetchMaxInboxId]: Retrieves current maximum telephony ID to establish a new snapshot.
  /// - [fetchPage]: Calls native `queryRecoveryInboxPage(startMaxId, limit, beforeId, sevenDayThresholdMs)`.
  /// - [processMessage]: Ingestion callback invoked for each eligible recovered message.
  /// - [pageSize]: Clamped between 1 and 500.
  /// - [nowEpochMs]: Current timestamp for calculating 7-day lookback window if starting fresh.
  Future<int> runRecoveryScan({
    required Future<int?> Function() fetchMaxInboxId,
    required Future<Map<dynamic, dynamic>?> Function({
      required int startMaxId,
      required int limit,
      int? beforeId,
      required int sevenDayThresholdMs,
    }) fetchPage,
    required Future<void> Function(dynamic message) processMessage,
    int pageSize = defaultPageSize,
    int? nowEpochMs,
    void Function(Object error, int pageIndex)? onPageError,
  }) async {
    final clampedLimit = pageSize.clamp(1, maxPageSize);
    final now = nowEpochMs ?? DateTime.now().millisecondsSinceEpoch;

    // 1. Check for active uncompleted checkpoint to resume
    var checkpoint = await store.load();
    final int activeStartMaxId;
    final int activeThreshold;
    int? currentBeforeId;

    if (checkpoint != null && !checkpoint.isComplete) {
      // RESUME: retain the original startMaxId, threshold, and continuation cursor.
      activeStartMaxId = checkpoint.startMaxId;
      activeThreshold = checkpoint.sevenDayThresholdMs;
      currentBeforeId = checkpoint.lastProcessedId;
    } else {
      // FRESH SCAN: capture startMaxId snapshot
      final maxId = await fetchMaxInboxId();
      if (maxId == null || maxId <= 0) {
        return 0; // Inbox is empty
      }
      activeStartMaxId = maxId;
      activeThreshold = now - defaultLookbackWindow.inMilliseconds;
      currentBeforeId = null;

      checkpoint = SmsRecoveryCheckpoint(
        startMaxId: activeStartMaxId,
        sevenDayThresholdMs: activeThreshold,
        lastProcessedId: null,
        isComplete: false,
        lastScanAtMs: now,
      );
      await store.save(checkpoint);
    }

    var totalProcessed = 0;
    var pageIndex = 0;
    var hasMore = true;

    while (hasMore) {
      final SmsRecoveryPage page;
      try {
        final raw = await fetchPage(
          startMaxId: activeStartMaxId,
          limit: clampedLimit,
          beforeId: currentBeforeId,
          sevenDayThresholdMs: activeThreshold,
        );
        page = SmsRecoveryPage.fromMap(raw);
      } catch (e) {
        onPageError?.call(e, pageIndex);
        break; // Interruption: preserve durable checkpoint for next run
      }

      // Process messages on this page in descending ID order
      for (final msg in page.messages) {
        await processMessage(msg);
        totalProcessed++;
      }

      hasMore = page.hasMore;
      pageIndex++;

      if (page.messages.isNotEmpty) {
        final lastMsgId = (page.messages.last['id'] as num).toInt();
        currentBeforeId = page.nextBeforeId ?? lastMsgId;

        // Durable checkpoint advancement: cursor advances only after processing succeeds
        checkpoint = checkpoint!.copyWith(
          lastProcessedId: currentBeforeId,
          isComplete: !hasMore,
          lastScanAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        await store.save(checkpoint);
      } else {
        // Empty page received -> terminal
        checkpoint = checkpoint!.copyWith(
          isComplete: true,
          lastScanAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        await store.save(checkpoint);
        break;
      }
    }

    return totalProcessed;
  }
}
