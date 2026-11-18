import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/services/sms_inbox_paginator.dart';
import 'package:spend_x/services/sms_recovery_paginator.dart';

/// Simulated native Android telephony inbox provider implementing the exact
/// selection and sorting semantics of `queryRecoveryInboxPage` and `queryInboxPage`.
class _SimulatedTelephonyProvider {
  final List<Map<String, dynamic>> messages;

  _SimulatedTelephonyProvider(this.messages);

  /// Implements native `queryRecoveryInboxPage(startMaxId, limit, beforeId, sevenDayThresholdMs)`
  /// using SQL selection:
  /// `date >= ? AND _id <= ? [AND _id < ?] ORDER BY _id DESC LIMIT ?`
  Map<String, dynamic> queryRecoveryInboxPage({
    required int startMaxId,
    required int limit,
    int? beforeId,
    required int sevenDayThresholdMs,
  }) {
    final clampedLimit = limit.clamp(1, 500);

    // Filter strictly matching SQLite query clauses
    final eligible = messages.where((m) {
      final date = m['date'] as int;
      final id = m['id'] as int;

      // 1. date >= sevenDayThresholdMs
      if (date < sevenDayThresholdMs) return false;

      // 2. _id <= startMaxId
      if (id > startMaxId) return false;

      // 3. _id < beforeId (if provided)
      if (beforeId != null && id >= beforeId) return false;

      return true;
    }).toList();

    // Sort: _id DESC
    eligible.sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));

    final pageMessages = eligible.take(clampedLimit).toList();
    final hasMore = eligible.length > clampedLimit;
    final nextBeforeId = (hasMore && pageMessages.isNotEmpty)
        ? (pageMessages.last['id'] as int)
        : null;

    return {
      'messages': pageMessages,
      'hasMore': hasMore,
      'nextBeforeId': nextBeforeId,
    };
  }

  /// Implements native `getMaxInboxId()`
  int? getMaxInboxId() {
    if (messages.isEmpty) return null;
    return messages.map((m) => m['id'] as int).reduce((a, b) => a > b ? a : b);
  }

  /// Implements Phase 1.3 `queryInboxPage(sinceEpochMs, limit, beforeDate, beforeId)`
  /// using compound cursor `(date, _id)` in `date DESC, _id DESC` order.
  Map<String, dynamic> queryInboxPage({
    int? sinceEpochMs,
    required int limit,
    int? beforeDate,
    int? beforeId,
  }) {
    final clampedLimit = limit.clamp(1, 500);
    final eligible = messages.where((m) {
      final date = m['date'] as int;
      final id = m['id'] as int;

      if (sinceEpochMs != null && sinceEpochMs > 0 && date < sinceEpochMs) {
        return false;
      }
      if (beforeDate != null && beforeId != null) {
        if (!(date < beforeDate || (date == beforeDate && id < beforeId))) {
          return false;
        }
      }
      return true;
    }).toList();

    eligible.sort((a, b) {
      final dateCmp = (b['date'] as int).compareTo(a['date'] as int);
      if (dateCmp != 0) return dateCmp;
      return (b['id'] as int).compareTo(a['id'] as int);
    });

    final pageMessages = eligible.take(clampedLimit).toList();
    final hasMore = eligible.length > clampedLimit;
    final nextCursor = (hasMore && pageMessages.isNotEmpty)
        ? {'date': pageMessages.last['date'], 'id': pageMessages.last['id']}
        : null;

    return {
      'messages': pageMessages,
      'hasMore': hasMore,
      'nextCursor': nextCursor,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Stage 3 — Android Recovery Keyset Pagination', () {
    test('Test A — Multi-page continuation with _id DESC ordering and strict beforeId', () async {
      final now = 1700000000000;
      final sevenDaysAgo = now - const Duration(days: 7).inMilliseconds;

      // 8 eligible messages with IDs 101 through 108
      final rawMessages = List.generate(8, (i) {
        final id = 101 + i;
        return {
          'id': id,
          'thread_id': 1,
          'address': 'VM-HDFCBK',
          'body': 'Txn $id',
          'date': sevenDaysAgo + (i * 10000),
          'date_sent': sevenDaysAgo + (i * 10000),
        };
      });

      final provider = _SimulatedTelephonyProvider(rawMessages);
      final store = SmsRecoveryCheckpointStore();
      final paginator = SmsRecoveryPaginator(store: store);

      final processedIds = <int>[];
      final requestedPages = <Map<String, dynamic>>[];

      final total = await paginator.runRecoveryScan(
        pageSize: 3, // 8 messages across pages of 3 -> pages: [108,107,106], [105,104,103], [102,101]
        nowEpochMs: now,
        fetchMaxInboxId: () async => provider.getMaxInboxId(),
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          requestedPages.add({
            'startMaxId': startMaxId,
            'limit': limit,
            'beforeId': beforeId,
            'threshold': sevenDayThresholdMs,
          });
          return provider.queryRecoveryInboxPage(
            startMaxId: startMaxId,
            limit: limit,
            beforeId: beforeId,
            sevenDayThresholdMs: sevenDayThresholdMs,
          );
        },
        processMessage: (msg) async {
          processedIds.add(msg['id'] as int);
        },
      );

      // 1. Total count
      expect(total, 8);

      // 2. Strict _id DESC ordering
      expect(processedIds, [108, 107, 106, 105, 104, 103, 102, 101]);

      // 3. Page request parameters & progression
      expect(requestedPages.length, 3);
      // Page 1: beforeId is null, startMaxId is 108
      expect(requestedPages[0]['beforeId'], isNull);
      expect(requestedPages[0]['startMaxId'], 108);
      // Page 2: beforeId is 106
      expect(requestedPages[1]['beforeId'], 106);
      expect(requestedPages[1]['startMaxId'], 108);
      // Page 3: beforeId is 103 (terminal page)
      expect(requestedPages[2]['beforeId'], 103);
      expect(requestedPages[2]['startMaxId'], 108);

      // 4. Checkpoint marked complete
      final checkpoint = await store.load();
      expect(checkpoint, isNotNull);
      expect(checkpoint!.isComplete, isTrue);
      expect(checkpoint.lastProcessedId, 101);
      expect(checkpoint.startMaxId, 108);
    });

    test('Test B — Concurrent SMS arrival with _id > startMaxId is strictly excluded', () async {
      final now = 1700000000000;
      final sevenDaysAgo = now - const Duration(days: 7).inMilliseconds;

      // Initial messages: IDs 201..205
      final messages = List<Map<String, dynamic>>.generate(5, (i) {
        final id = 201 + i;
        return {
          'id': id,
          'thread_id': 1,
          'address': 'VM-HDFCBK',
          'body': 'Txn $id',
          'date': sevenDaysAgo + (i * 10000),
          'date_sent': sevenDaysAgo + (i * 10000),
        };
      });

      final provider = _SimulatedTelephonyProvider(messages);
      final store = SmsRecoveryCheckpointStore();
      final paginator = SmsRecoveryPaginator(store: store);

      final processedIds = <int>[];
      var pageCount = 0;

      final total = await paginator.runRecoveryScan(
        pageSize: 2, // 5 messages across pages: [205, 204], [203, 202], [201]
        nowEpochMs: now,
        fetchMaxInboxId: () async => provider.getMaxInboxId(),
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          pageCount++;
          // Concurrent arrival simulation: after page 1 is requested, new SMS arrives with ID 206 and 207!
          if (pageCount == 2) {
            provider.messages.add({
              'id': 206,
              'thread_id': 1,
              'address': 'VM-HDFCBK',
              'body': 'Txn 206 (Arrived concurrently)',
              'date': now,
              'date_sent': now,
            });
            provider.messages.add({
              'id': 207,
              'thread_id': 1,
              'address': 'VM-HDFCBK',
              'body': 'Txn 207 (Arrived concurrently)',
              'date': now,
              'date_sent': now,
            });
          }

          return provider.queryRecoveryInboxPage(
            startMaxId: startMaxId,
            limit: limit,
            beforeId: beforeId,
            sevenDayThresholdMs: sevenDayThresholdMs,
          );
        },
        processMessage: (msg) async {
          processedIds.add(msg['id'] as int);
        },
      );

      // Newer messages (206, 207) MUST be strictly excluded by startMaxId ceiling
      expect(processedIds.contains(206), isFalse);
      expect(processedIds.contains(207), isFalse);

      // All older eligible messages (201..205) MUST be fully processed
      expect(processedIds, [205, 204, 203, 202, 201]);
      expect(total, 5);
    });

    test('Test C — Interruption and resumption retains startMaxId and resumes from cursor', () async {
      final now = 1700000000000;
      final sevenDaysAgo = now - const Duration(days: 7).inMilliseconds;

      // 6 messages: IDs 301..306
      final messages = List<Map<String, dynamic>>.generate(6, (i) {
        final id = 301 + i;
        return {
          'id': id,
          'thread_id': 1,
          'address': 'VM-ICICIB',
          'body': 'Txn $id',
          'date': sevenDaysAgo + (i * 10000),
          'date_sent': sevenDaysAgo + (i * 10000),
        };
      });

      final provider = _SimulatedTelephonyProvider(messages);
      final store = SmsRecoveryCheckpointStore();
      final paginator = SmsRecoveryPaginator(store: store);

      final processedInPass1 = <int>[];
      var pass1CallCount = 0;

      // Pass 1: Simulate crash/interruption after processing page 1 ([306, 305])
      await paginator.runRecoveryScan(
        pageSize: 2,
        nowEpochMs: now,
        fetchMaxInboxId: () async => provider.getMaxInboxId(),
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          pass1CallCount++;
          if (pass1CallCount == 2) {
            throw Exception('SIMULATED_PROCESS_CRASH_OR_INTERRUPTION');
          }
          return provider.queryRecoveryInboxPage(
            startMaxId: startMaxId,
            limit: limit,
            beforeId: beforeId,
            sevenDayThresholdMs: sevenDayThresholdMs,
          );
        },
        processMessage: (msg) async {
          processedInPass1.add(msg['id'] as int);
        },
        onPageError: (err, idx) {
          // Handled
        },
      );

      expect(processedInPass1, [306, 305]);

      // Verify checkpoint in store: startMaxId is 306, lastProcessedId is 305, isComplete is false
      final checkpointAfterCrash = await store.load();
      expect(checkpointAfterCrash, isNotNull);
      expect(checkpointAfterCrash!.isComplete, isFalse);
      expect(checkpointAfterCrash.startMaxId, 306);
      expect(checkpointAfterCrash.lastProcessedId, 305);

      // Now add a newer SMS (ID 307) during downtime before resumption
      provider.messages.add({
        'id': 307,
        'thread_id': 1,
        'address': 'VM-ICICIB',
        'body': 'Txn 307 (arrived during downtime)',
        'date': now,
        'date_sent': now,
      });

      // Pass 2: Resume scan
      final processedInPass2 = <int>[];
      var fetchMaxIdCalledOnResume = false;

      final totalPass2 = await paginator.runRecoveryScan(
        pageSize: 2,
        nowEpochMs: now + 50000,
        fetchMaxInboxId: () async {
          fetchMaxIdCalledOnResume = true;
          return provider.getMaxInboxId();
        },
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          return provider.queryRecoveryInboxPage(
            startMaxId: startMaxId,
            limit: limit,
            beforeId: beforeId,
            sevenDayThresholdMs: sevenDayThresholdMs,
          );
        },
        processMessage: (msg) async {
          processedInPass2.add(msg['id'] as int);
        },
      );

      // 1. fetchMaxInboxId must NOT be called on resumption (retains original snapshot ceiling)
      expect(fetchMaxIdCalledOnResume, isFalse);

      // 2. Resumed pass starts from 305 and processes remaining messages [304, 303, 302, 301]
      expect(processedInPass2, [304, 303, 302, 301]);
      expect(totalPass2, 4);

      // 3. ID 307 was NOT included in resumption
      expect(processedInPass2.contains(307), isFalse);

      // 4. Combined passes processed all original messages exactly once with zero duplicates or skips
      final combined = [...processedInPass1, ...processedInPass2];
      expect(combined, [306, 305, 304, 303, 302, 301]);

      // 5. Final checkpoint is marked complete
      final finalCheckpoint = await store.load();
      expect(finalCheckpoint!.isComplete, isTrue);
      expect(finalCheckpoint.startMaxId, 306);
    });

    test('Test D — Exact seven-day boundary is inclusive (date >= sevenDayThresholdMs)', () async {
      final now = 1700000000000;
      final sevenDaysAgo = now - const Duration(days: 7).inMilliseconds;

      final messages = [
        // Message exactly at boundary (date == sevenDaysAgo) -> MUST BE INCLUDED
        {
          'id': 401,
          'thread_id': 1,
          'address': 'VM-TEST',
          'body': 'Exact boundary message',
          'date': sevenDaysAgo,
          'date_sent': sevenDaysAgo,
        },
        // Message 1 ms after boundary -> MUST BE INCLUDED
        {
          'id': 402,
          'thread_id': 1,
          'address': 'VM-TEST',
          'body': 'Inside window message',
          'date': sevenDaysAgo + 1,
          'date_sent': sevenDaysAgo + 1,
        },
        // Message 1 ms before boundary -> MUST BE EXCLUDED
        {
          'id': 400,
          'thread_id': 1,
          'address': 'VM-TEST',
          'body': 'Outside window message',
          'date': sevenDaysAgo - 1,
          'date_sent': sevenDaysAgo - 1,
        },
      ];

      final provider = _SimulatedTelephonyProvider(messages);
      final store = SmsRecoveryCheckpointStore();
      final paginator = SmsRecoveryPaginator(store: store);

      final processedIds = <int>[];

      await paginator.runRecoveryScan(
        pageSize: 10,
        nowEpochMs: now,
        fetchMaxInboxId: () async => 402,
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          expect(sevenDayThresholdMs, sevenDaysAgo);
          return provider.queryRecoveryInboxPage(
            startMaxId: startMaxId,
            limit: limit,
            beforeId: beforeId,
            sevenDayThresholdMs: sevenDayThresholdMs,
          );
        },
        processMessage: (msg) async {
          processedIds.add(msg['id'] as int);
        },
      );

      // Exactly at boundary (401) and inside (402) are processed
      expect(processedIds, contains(401));
      expect(processedIds, contains(402));

      // 1 ms older (400) is excluded
      expect(processedIds.contains(400), isFalse);
    });

    test('Test E — Regression protection: Phase 1.3 queryInboxPage remains unchanged', () async {
      // Multiple messages sharing the same millisecond timestamp
      final timestamp = 1700000000000;
      final messages = [
        {'id': 503, 'date': timestamp, 'body': 'm503'},
        {'id': 502, 'date': timestamp, 'body': 'm502'},
        {'id': 501, 'date': timestamp, 'body': 'm501'},
        {'id': 500, 'date': timestamp - 5000, 'body': 'm500'},
      ];

      final provider = _SimulatedTelephonyProvider(messages);

      // Page 1 with limit 2 using Phase 1.3 queryInboxPage contract
      final page1 = provider.queryInboxPage(
        sinceEpochMs: timestamp - 10000,
        limit: 2,
        beforeDate: null,
        beforeId: null,
      );

      final inboxPage1 = SmsInboxPage.fromMap(page1);
      expect(inboxPage1.messages.length, 2);
      expect(inboxPage1.hasMore, isTrue);
      expect(inboxPage1.nextDate, timestamp);
      expect(inboxPage1.nextId, 502);

      // Page 2 continuation with beforeDate & beforeId
      final page2 = provider.queryInboxPage(
        sinceEpochMs: timestamp - 10000,
        limit: 2,
        beforeDate: inboxPage1.nextDate,
        beforeId: inboxPage1.nextId,
      );

      final inboxPage2 = SmsInboxPage.fromMap(page2);
      expect(inboxPage2.messages.length, 2);
      expect(inboxPage2.messages.map((m) => m['id']).toList(), [501, 500]);
      expect(inboxPage2.hasMore, isFalse);
    });

    test('Test F — Page size clamping: default (300), minimum (1), maximum (500), and invalid handling', () async {
      final now = 1700000000000;
      final sevenDaysAgo = now - const Duration(days: 7).inMilliseconds;

      final messages = List<Map<String, dynamic>>.generate(600, (i) {
        final id = 1 + i;
        return {
          'id': id,
          'thread_id': 1,
          'address': 'VM-TEST',
          'body': 'Txn $id',
          'date': sevenDaysAgo + (i * 1000),
          'date_sent': sevenDaysAgo + (i * 1000),
        };
      });

      final provider = _SimulatedTelephonyProvider(messages);
      final store = SmsRecoveryCheckpointStore();
      final paginator = SmsRecoveryPaginator(store: store);

      // 1. Default page size (300)
      final requestedLimits = <int>[];
      await paginator.runRecoveryScan(
        nowEpochMs: now,
        fetchMaxInboxId: () async => 600,
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          requestedLimits.add(limit);
          // Return terminal empty to stop after checking limit
          return {'messages': [], 'hasMore': false, 'nextBeforeId': null};
        },
        processMessage: (msg) async {},
      );
      expect(requestedLimits.first, 300);

      // 2. Minimum page size (clamp <= 0 to 1)
      await store.clear();
      requestedLimits.clear();
      await paginator.runRecoveryScan(
        pageSize: 0, // invalid <= 0
        nowEpochMs: now,
        fetchMaxInboxId: () async => 600,
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          requestedLimits.add(limit);
          return {'messages': [], 'hasMore': false, 'nextBeforeId': null};
        },
        processMessage: (msg) async {},
      );
      expect(requestedLimits.first, 1);

      // 3. Negative page size (clamp < 0 to 1)
      await store.clear();
      requestedLimits.clear();
      await paginator.runRecoveryScan(
        pageSize: -50, // invalid negative
        nowEpochMs: now,
        fetchMaxInboxId: () async => 600,
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          requestedLimits.add(limit);
          return {'messages': [], 'hasMore': false, 'nextBeforeId': null};
        },
        processMessage: (msg) async {},
      );
      expect(requestedLimits.first, 1);

      // 4. Maximum page size (clamp > 500 to 500)
      await store.clear();
      requestedLimits.clear();
      await paginator.runRecoveryScan(
        pageSize: 1000, // exceeds max 500
        nowEpochMs: now,
        fetchMaxInboxId: () async => 600,
        fetchPage: ({
          required int startMaxId,
          required int limit,
          int? beforeId,
          required int sevenDayThresholdMs,
        }) async {
          requestedLimits.add(limit);
          return {'messages': [], 'hasMore': false, 'nextBeforeId': null};
        },
        processMessage: (msg) async {},
      );
      expect(requestedLimits.first, 500);

      // 5. Native query provider clamping verification
      final resMin = provider.queryRecoveryInboxPage(
        startMaxId: 600,
        limit: -10,
        sevenDayThresholdMs: sevenDaysAgo,
      );
      expect(resMin['messages'].length, 1); // clamped to 1

      final resMax = provider.queryRecoveryInboxPage(
        startMaxId: 600,
        limit: 9999,
        sevenDayThresholdMs: sevenDaysAgo,
      );
      expect(resMax['messages'].length, 500); // clamped to 500
    });

    test('Test G — Inconsistent beforeId cannot bypass startMaxId', () async {
      final now = 1700000000000;
      final sevenDaysAgo = now - const Duration(days: 7).inMilliseconds;

      final messages = [
        {'id': 100, 'date': now, 'body': 'm100'},
        {'id': 200, 'date': now, 'body': 'm200'},
        {'id': 300, 'date': now, 'body': 'm300'},
        {'id': 400, 'date': now, 'body': 'm400'},
        {'id': 500, 'date': now, 'body': 'm500'},
        {'id': 600, 'date': now, 'body': 'm600'}, // > startMaxId
      ];

      final provider = _SimulatedTelephonyProvider(messages);

      // Caller attempts to pass beforeId = 9999 with startMaxId = 500
      final result1 = provider.queryRecoveryInboxPage(
        startMaxId: 500,
        limit: 10,
        beforeId: 9999, // Inconsistent large beforeId
        sevenDayThresholdMs: sevenDaysAgo,
      );
      final ids1 = (result1['messages'] as List).map((m) => m['id']).toList();
      // ID 600 must NOT be returned!
      expect(ids1.contains(600), isFalse);
      expect(ids1, [500, 400, 300, 200, 100]);

      // Caller passes negative or zero beforeId
      final result2 = provider.queryRecoveryInboxPage(
        startMaxId: 500,
        limit: 10,
        beforeId: 0, // Invalid beforeId <= 0
        sevenDayThresholdMs: sevenDaysAgo,
      );
      expect(result2['messages'], isEmpty);
      expect(result2['hasMore'], isFalse);
      expect(result2['nextBeforeId'], isNull);
    });

    test('Test H — Empty and terminal pages return correct hasMore and nextBeforeId', () async {
      final now = 1700000000000;
      final sevenDaysAgo = now - const Duration(days: 7).inMilliseconds;

      // 1. Completely empty inbox
      final emptyProvider = _SimulatedTelephonyProvider([]);
      final emptyResult = emptyProvider.queryRecoveryInboxPage(
        startMaxId: 100,
        limit: 10,
        sevenDayThresholdMs: sevenDaysAgo,
      );
      expect(emptyResult['messages'], isEmpty);
      expect(emptyResult['hasMore'], isFalse);
      expect(emptyResult['nextBeforeId'], isNull);

      // 2. Terminal page with exactly 2 items when limit is 5
      final terminalProvider = _SimulatedTelephonyProvider([
        {'id': 102, 'date': now, 'body': 'm102'},
        {'id': 101, 'date': now, 'body': 'm101'},
      ]);
      final terminalResult = terminalProvider.queryRecoveryInboxPage(
        startMaxId: 102,
        limit: 5,
        sevenDayThresholdMs: sevenDaysAgo,
      );
      final msgs = terminalResult['messages'] as List;
      expect(msgs.length, 2);
      expect(terminalResult['hasMore'], isFalse);
      expect(terminalResult['nextBeforeId'], isNull);

      // 3. Exact boundary: exactly 2 items with limit 2 (hasMore is false, nextBeforeId is null)
      final exactResult = terminalProvider.queryRecoveryInboxPage(
        startMaxId: 102,
        limit: 2,
        sevenDayThresholdMs: sevenDaysAgo,
      );
      expect((exactResult['messages'] as List).length, 2);
      expect(exactResult['hasMore'], isFalse);
      expect(exactResult['nextBeforeId'], isNull);
    });
  });
}
