import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/logging/app_logger.dart';
import 'sms_inbox_paginator.dart';

/// A position in the Android SMS inbox ordered by `(date DESC, _id DESC)`.
///
/// The cursor is deliberately a tuple. A timestamp alone is not sufficient:
/// Android may contain many messages with the same millisecond `DATE`, so the
/// `_id` tie-breaker is what makes resume deterministic and non-repeating.
class SmsInboxCursor implements Comparable<SmsInboxCursor> {
  final int date;
  final int id;

  const SmsInboxCursor({required this.date, required this.id});

  /// Extracts a cursor from a native inbox page row.
  ///
  /// The native side returns `id`/`date` for every row. Rows without both
  /// fields are not positionable and are ignored rather than guessed at.
  static SmsInboxCursor? tryFromMessage(dynamic raw) {
    if (raw is! Map) return null;
    final rawDate = raw['date'];
    final rawId = raw['id'];
    if (rawDate is! num || rawId is! num) return null;
    return SmsInboxCursor(date: rawDate.toInt(), id: rawId.toInt());
  }

  String get key => '$date:$id';

  /// Descending inbox order: negative means this cursor is **newer** (appears
  /// earlier) than [other]. This mirrors the native
  /// `ORDER BY date DESC, _id DESC` clause.
  @override
  int compareTo(SmsInboxCursor other) {
    if (date != other.date) return other.date.compareTo(date);
    return other.id.compareTo(id);
  }

  /// Ascending processing order used for ledger ingestion.
  static int compareAscending(SmsInboxCursor a, SmsInboxCursor b) =>
      b.compareTo(a);

  bool isNewerThan(SmsInboxCursor other) => compareTo(other) < 0;
  bool isAtOrNewerThan(SmsInboxCursor other) => compareTo(other) <= 0;
  bool isOlderThan(SmsInboxCursor other) => compareTo(other) > 0;
  bool isAtOrOlderThan(SmsInboxCursor other) => compareTo(other) >= 0;

  Map<String, dynamic> toJson() => {'date': date, 'id': id};

  static SmsInboxCursor? fromJson(dynamic value) {
    if (value is! Map) return null;
    final date = value['date'];
    final id = value['id'];
    if (date is! num || id is! num) return null;
    return SmsInboxCursor(date: date.toInt(), id: id.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is SmsInboxCursor && other.date == date && other.id == id;

  @override
  int get hashCode => Object.hash(date, id);

  @override
  String toString() => 'SmsInboxCursor($date, $id)';
}

/// Durable progress for the paginated SMS inbox scan.
///
/// [committed] is the newest inbox tuple that has been fully processed by a
/// successful scan. Everything newer than it is picked up by a later scan.
///
/// An *active* scan records the boundary that the scan may not cross
/// ([activeFence]) and how far ingestion has progressed in ascending order
/// ([processedThrough]). The active fields are cleared only after balance
/// reconciliation succeeds, at which point [activeFence] becomes [committed].
class SmsInboxScanCheckpoint {
  final SmsInboxCursor? committed;
  final SmsInboxCursor? activeFence;
  final SmsInboxCursor? processedThrough;
  final int? activeCutoffMs;
  final int? lastScanAtMs;
  final int? lastCompletedAtMs;

  const SmsInboxScanCheckpoint({
    this.committed,
    this.activeFence,
    this.processedThrough,
    this.activeCutoffMs,
    this.lastScanAtMs,
    this.lastCompletedAtMs,
  });

  static const SmsInboxScanCheckpoint empty = SmsInboxScanCheckpoint();

  bool get hasActiveScan => activeFence != null && activeCutoffMs != null;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'committed': committed?.toJson(),
    'active': hasActiveScan
        ? {
            'fence': activeFence!.toJson(),
            'processedThrough': processedThrough?.toJson(),
            'cutoffMs': activeCutoffMs,
          }
        : null,
    'lastScanAtMs': lastScanAtMs,
    'lastCompletedAtMs': lastCompletedAtMs,
  };

  static SmsInboxScanCheckpoint fromJson(dynamic value) {
    if (value is! Map) return empty;
    final active = value['active'];
    final activeMap = active is Map ? active : null;
    return SmsInboxScanCheckpoint(
      committed: SmsInboxCursor.fromJson(value['committed']),
      activeFence: SmsInboxCursor.fromJson(activeMap?['fence']),
      processedThrough: SmsInboxCursor.fromJson(activeMap?['processedThrough']),
      activeCutoffMs: (activeMap?['cutoffMs'] as num?)?.toInt(),
      lastScanAtMs: (value['lastScanAtMs'] as num?)?.toInt(),
      lastCompletedAtMs: (value['lastCompletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// SharedPreferences-backed watermark storage.
///
/// This uses the existing application-private preference store, so no database
/// migration is required. A malformed value is treated as an empty checkpoint:
/// losing the watermark costs one idempotent rescan, whereas throwing would
/// block all future SMS processing.
class SmsInboxWatermarkStore {
  static const String defaultKey = 'spendx_sms_inbox_watermark_v1';

  static String? _testKeyOverride;

  /// Test-only hook to override the watermark key in isolated test environments.
  /// Strictly prohibited in release builds.
  static void setTestKeyOverride(String? key) {
    if (const bool.fromEnvironment('dart.vm.product')) {
      throw UnsupportedError('setTestKeyOverride is strictly prohibited in release builds');
    }
    _testKeyOverride = key;
  }

  /// The active key used for inbox watermark persistence.
  static String get activeKey => _testKeyOverride ?? defaultKey;

  final String key;

  SmsInboxWatermarkStore({String? key}) : key = key ?? activeKey;

  /// Test hook used to simulate a failed preference write.
  @visibleForTesting
  static Future<bool> Function(
    SharedPreferences prefs,
    String key,
    String value,
  )?
  testSaveInterceptor;

  Future<SmsInboxScanCheckpoint> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return SmsInboxScanCheckpoint.empty;
      return SmsInboxScanCheckpoint.fromJson(jsonDecode(raw));
    } catch (e) {
      AppLogger.w(
        '[SmsInboxWatermark] Could not read checkpoint; starting from an '
        'empty watermark: $e',
      );
      return SmsInboxScanCheckpoint.empty;
    }
  }

  Future<bool> save(SmsInboxScanCheckpoint checkpoint) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(checkpoint.toJson());
      if (testSaveInterceptor != null) {
        return await testSaveInterceptor!(prefs, key, encoded);
      }
      return await prefs.setString(key, encoded);
    } catch (e) {
      AppLogger.w('[SmsInboxWatermark] Could not persist checkpoint: $e');
      return false;
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (e) {
      AppLogger.w('[SmsInboxWatermark] Could not clear checkpoint: $e');
    }
  }
}

/// Fetches one native inbox page.
typedef SmsInboxPageFetcher =
    Future<Map<dynamic, dynamic>?> Function({
      required int sinceEpochMs,
      int? beforeDate,
      int? beforeId,
    });

/// Result of one watermark-driven inbox scan.
class SmsInboxScanOutcome {
  final int messagesScanned;
  final int messagesIngested;
  final bool completed;
  final bool resumed;
  final SmsInboxCursor? fence;
  final SmsInboxCursor? committed;
  final String? error;

  const SmsInboxScanOutcome({
    required this.messagesScanned,
    required this.messagesIngested,
    required this.completed,
    required this.resumed,
    this.fence,
    this.committed,
    this.error,
  });
}

/// Runs the durable, bounded SMS inbox scan.
///
/// Ordering and boundary contract:
/// - The inbox is fetched in native `(date DESC, _id DESC)` pages, then
///   ingested in ascending `(date ASC, _id ASC)` order so ledger/synthetic
///   reference ordering is preserved.
/// - [fence] is the newest tuple seen when the scan begins. Messages that
///   arrive above the fence while the scan is running are deliberately left
///   for the next scan; the next scan captures a fresh fence.
/// - [committed] is advanced only after ingestion **and** balance
///   reconciliation succeed. The active fence then becomes [committed], so a
///   message that arrived after the fence is newer than the new watermark and
///   cannot be skipped.
class SmsInboxScanRunner {
  SmsInboxScanRunner({
    SmsInboxWatermarkStore? store,
    this.pageSize = SmsInboxPaginator.defaultPageSize,
    this.maxPages = SmsInboxPaginator.defaultMaxPages,
    this.progressBatchSize = 100,
    this.pageTimeout = const Duration(seconds: 15),
  }) : store = store ?? SmsInboxWatermarkStore();

  final SmsInboxWatermarkStore store;
  final int pageSize;
  final int maxPages;
  final int progressBatchSize;
  final Duration pageTimeout;

  Future<void> _lock = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<SmsInboxScanOutcome> run({
    required int cutoffMs,
    required SmsInboxPageFetcher fetchPage,
    required Future<void> Function(List<dynamic> ascendingMessages) ingestBatch,
    required Future<void> Function(List<dynamic> descendingMessages)
    applyBalances,
    void Function(int fetchedCount)? onTargetFetched,
    void Function(int pendingIngest)? onIngestStarting,
    void Function(String message)? onLog,
  }) {
    return _synchronized(
      () => _run(
        cutoffMs: cutoffMs,
        fetchPage: fetchPage,
        ingestBatch: ingestBatch,
        applyBalances: applyBalances,
        onTargetFetched: onTargetFetched,
        onIngestStarting: onIngestStarting,
        onLog: onLog,
      ),
    );
  }

  Future<SmsInboxScanOutcome> _run({
    required int cutoffMs,
    required SmsInboxPageFetcher fetchPage,
    required Future<void> Function(List<dynamic> ascendingMessages) ingestBatch,
    required Future<void> Function(List<dynamic> descendingMessages)
    applyBalances,
    void Function(int fetchedCount)? onTargetFetched,
    void Function(int pendingIngest)? onIngestStarting,
    void Function(String message)? onLog,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final loaded = await store.load();
    final committed = loaded.committed;
    final resumed = loaded.hasActiveScan;
    final scanCutoffMs = loaded.activeCutoffMs ?? cutoffMs;
    SmsInboxCursor? fence = loaded.activeFence;
    SmsInboxCursor? processedThrough = loaded.processedThrough;

    final target = <dynamic>[];
    var completed = true;
    String? error;
    var pages = 0;
    var hasMore = true;
    var reachedCommitted = false;
    int? beforeDate;
    int? beforeId;

    // ---------------------------------------------------------------
    // 1. Fetch the bounded target in native descending order.
    // ---------------------------------------------------------------
    while (hasMore && pages < maxPages) {
      SmsInboxPage page;
      try {
        final raw = await fetchPage(
          sinceEpochMs: scanCutoffMs,
          beforeDate: beforeDate,
          beforeId: beforeId,
        ).timeout(pageTimeout);
        page = SmsInboxPage.fromMap(raw);
      } catch (e) {
        completed = false;
        error = 'SMS inbox page $pages could not be read: $e';
        break;
      }

      for (final raw in page.messages) {
        final cursor = SmsInboxCursor.tryFromMessage(raw);
        if (cursor == null) continue;

        // The first positionable message of a fresh scan sets the boundary.
        // On a resumed scan the stored active fence is authoritative.
        fence ??= cursor;

        if (committed != null && cursor.isAtOrOlderThan(committed)) {
          // Descending order means every later row is also committed.
          reachedCommitted = true;
          continue;
        }
        if (cursor.isNewerThan(fence)) {
          // Arrived after the scan boundary. The next scan captures it.
          continue;
        }
        target.add(raw);
      }

      hasMore = page.hasMore;
      beforeDate = page.nextDate;
      beforeId = page.nextId;
      pages++;

      if (reachedCommitted) break;
      if (hasMore && (beforeDate == null || beforeId == null)) {
        completed = false;
        error = 'SMS inbox page $pages did not return a next cursor';
        break;
      }
    }

    if (completed && hasMore && pages >= maxPages) {
      completed = false;
      error = 'SMS inbox scan stopped after $maxPages pages';
    }

    // ---------------------------------------------------------------
    // 2. Empty inbox / no positionable messages.
    // ---------------------------------------------------------------
    if (fence == null) {
      final saved = await _save(
        SmsInboxScanCheckpoint(
          committed: committed,
          lastScanAtMs: nowMs,
          lastCompletedAtMs: completed ? nowMs : loaded.lastCompletedAtMs,
        ),
      );
      if (!saved) {
        completed = false;
        error ??= 'Could not persist the empty-inbox checkpoint';
      }
      return SmsInboxScanOutcome(
        messagesScanned: 0,
        messagesIngested: 0,
        completed: completed,
        resumed: resumed,
        committed: committed,
        error: error,
      );
    }

    processedThrough ??= committed;

    // Persist the active fence before doing any downstream work. A restart
    // can then resume inside the same boundary instead of redefining it.
    if (completed) {
      final saved = await _save(
        SmsInboxScanCheckpoint(
          committed: committed,
          activeFence: fence,
          activeCutoffMs: scanCutoffMs,
          processedThrough: processedThrough,
          lastScanAtMs: nowMs,
          lastCompletedAtMs: loaded.lastCompletedAtMs,
        ),
      );
      if (!saved) {
        completed = false;
        error = 'Could not persist the SMS inbox scan boundary';
      }
    }

    if (!completed) {
      return SmsInboxScanOutcome(
        messagesScanned: target.length,
        messagesIngested: 0,
        completed: false,
        resumed: resumed,
        fence: fence,
        committed: committed,
        error: error,
      );
    }

    onTargetFetched?.call(target.length);

    // ---------------------------------------------------------------
    // 3. Ingest ascending, checkpointing only after a batch succeeds.
    // ---------------------------------------------------------------
    final ascending = target.reversed.toList(growable: false);
    final pending = <dynamic>[];
    for (final raw in ascending) {
      final cursor = SmsInboxCursor.tryFromMessage(raw);
      if (cursor != null &&
          processedThrough != null &&
          !cursor.isNewerThan(processedThrough)) {
        continue;
      }
      pending.add(raw);
    }
    onIngestStarting?.call(pending.length);

    var ingested = 0;
    for (var start = 0; start < pending.length; start += progressBatchSize) {
      final end = math.min(start + progressBatchSize, pending.length);
      final batch = pending.sublist(start, end);
      try {
        await ingestBatch(batch);
      } catch (e) {
        completed = false;
        error = 'SMS ingestion failed: $e';
        break;
      }

      ingested += batch.length;
      final last = SmsInboxCursor.tryFromMessage(batch.last);
      if (last != null) processedThrough = last;

      final saved = await _save(
        SmsInboxScanCheckpoint(
          committed: committed,
          activeFence: fence,
          activeCutoffMs: scanCutoffMs,
          processedThrough: processedThrough,
          lastScanAtMs: nowMs,
          lastCompletedAtMs: loaded.lastCompletedAtMs,
        ),
      );
      if (!saved) {
        completed = false;
        error = 'Could not persist SMS inbox progress';
        break;
      }
    }

    if (!completed) {
      return SmsInboxScanOutcome(
        messagesScanned: target.length,
        messagesIngested: ingested,
        completed: false,
        resumed: resumed,
        fence: fence,
        committed: committed,
        error: error,
      );
    }

    // ---------------------------------------------------------------
    // 4. Reconcile balances over the *whole* target. On a resumed scan this
    //    intentionally includes the already-ingested prefix so
    //    latest-per-key balance selection is identical to a single pass.
    // ---------------------------------------------------------------
    if (target.isNotEmpty) {
      try {
        await applyBalances(target);
      } catch (e) {
        completed = false;
        error = 'SMS balance reconciliation failed: $e';
        return SmsInboxScanOutcome(
          messagesScanned: target.length,
          messagesIngested: ingested,
          completed: false,
          resumed: resumed,
          fence: fence,
          committed: committed,
          error: error,
        );
      }
    }

    // ---------------------------------------------------------------
    // 5. Commit only after ingestion and balance reconciliation succeeded.
    // ---------------------------------------------------------------
    final newCommitted = committed == null || fence.isNewerThan(committed)
        ? fence
        : committed;
    final saved = await _save(
      SmsInboxScanCheckpoint(
        committed: newCommitted,
        lastScanAtMs: nowMs,
        lastCompletedAtMs: nowMs,
      ),
    );
    if (!saved) {
      completed = false;
      error = 'Could not persist the SMS inbox watermark';
    }

    onLog?.call(
      '[SmsInboxWatermark] scan ${completed ? 'committed' : 'incomplete'}: '
      'scanned=${target.length} ingested=$ingested '
      'fence=${fence.key} committed=${(completed ? newCommitted : committed)?.key}',
    );

    return SmsInboxScanOutcome(
      messagesScanned: target.length,
      messagesIngested: ingested,
      completed: completed,
      resumed: resumed,
      fence: fence,
      committed: completed ? newCommitted : committed,
      error: error,
    );
  }

  Future<bool> _save(SmsInboxScanCheckpoint checkpoint) async {
    try {
      return await store.save(checkpoint);
    } catch (_) {
      return false;
    }
  }
}
