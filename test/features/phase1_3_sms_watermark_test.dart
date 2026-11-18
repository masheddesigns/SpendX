import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/services/sms_inbox_watermark.dart';

/// Synthetic native inbox that follows the real `(date DESC, _id DESC)` keyset
/// contract, including the `beforeDate`/`beforeId` continuation cursor.
class _FakeInbox {
  _FakeInbox(this.messages, {this.pageSize = 3});

  List<Map<String, dynamic>> messages;
  int pageSize;
  int fetchCalls = 0;
  int? failOnFetchCall;
  void Function(int fetchCall)? afterFetch;

  Future<Map<dynamic, dynamic>?> fetch({
    required int sinceEpochMs,
    int? beforeDate,
    int? beforeId,
  }) async {
    fetchCalls++;
    if (failOnFetchCall == fetchCalls) {
      throw StateError('simulated provider failure on page $fetchCalls');
    }

    final eligible = messages
        .where((m) => (m['date'] as int) >= sinceEpochMs)
        .toList(growable: false);

    var start = 0;
    if (beforeDate != null && beforeId != null) {
      start = eligible.indexWhere(
        (m) =>
            (m['date'] as int) < beforeDate ||
            ((m['date'] as int) == beforeDate && (m['id'] as int) < beforeId),
      );
      if (start < 0) start = eligible.length;
    }

    final batch = eligible.skip(start).take(pageSize).toList(growable: false);
    final hasMore = start + batch.length < eligible.length;
    final result = <String, dynamic>{
      'messages': batch,
      'hasMore': hasMore,
      'nextCursor': hasMore
          ? {'date': batch.last['date'], 'id': batch.last['id']}
          : null,
    };
    afterFetch?.call(fetchCalls);
    return result;
  }
}

Map<String, dynamic> _msg(int date, int id, [String? body]) => {
      'id': id,
      'date': date,
      'address': 'AD-HDFCBK-T',
      'body': body ?? 'message-$id',
    };

String _bodyOf(Map<String, dynamic> message) => message['body'] as String;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SmsInboxWatermarkStore store;
  late List<Map<String, dynamic>> ingested;
  late List<List<String>> ingestBatches;
  late List<List<String>> balanceTargets;
  var ingestCalls = 0;
  var balanceCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SmsInboxWatermarkStore.testSaveInterceptor = null;
    _failSecondIngest = false;
    store = SmsInboxWatermarkStore(key: 'test_sms_inbox_watermark');
    ingested = [];
    ingestBatches = [];
    balanceTargets = [];
    ingestCalls = 0;
    balanceCalls = 0;
  });

  tearDown(() {
    SmsInboxWatermarkStore.testSaveInterceptor = null;
  });

  SmsInboxScanRunner runner({
    int pageSize = 3,
    int batchSize = 2,
    SmsInboxScanRunner? instance,
  }) {
    return instance ??
        SmsInboxScanRunner(
          store: store,
          pageSize: pageSize,
          maxPages: 20,
          progressBatchSize: batchSize,
          pageTimeout: const Duration(seconds: 1),
        );
  }

  Future<SmsInboxScanOutcome> runScan(
    _FakeInbox inbox, {
    required SmsInboxScanRunner scanner,
    bool failBalances = false,
  }) {
    return scanner.run(
      cutoffMs: 0,
      fetchPage: inbox.fetch,
      ingestBatch: (messages) async {
        ingestCalls++;
        ingestBatches.add(messages.map((m) => _bodyOf(m)).toList());
        if (ingestCalls == 2 && _failSecondIngest) {
          throw StateError('simulated ingestion failure');
        }
        ingested.addAll(messages.cast<Map<String, dynamic>>());
      },
      applyBalances: (messages) async {
        balanceCalls++;
        balanceTargets.add(messages.map((m) => _bodyOf(m)).toList());
        if (failBalances) throw StateError('simulated balance failure');
      },
    );
  }

  group('Phase 1.3 durable SMS inbox watermark', () {
    test('1. watermark persists and reloads as a cursor tuple', () async {
      const committed = SmsInboxCursor(date: 1700000000000, id: 42);
      const fence = SmsInboxCursor(date: 1700000005000, id: 50);
      const processed = SmsInboxCursor(date: 1700000002000, id: 45);

      final saved = await store.save(
        const SmsInboxScanCheckpoint(
          committed: committed,
          activeFence: fence,
          processedThrough: processed,
          activeCutoffMs: 1690000000000,
          lastScanAtMs: 1,
          lastCompletedAtMs: 2,
        ),
      );
      expect(saved, isTrue);

      final reloaded = await SmsInboxWatermarkStore(
        key: store.key,
      ).load();
      expect(reloaded.committed, committed);
      expect(reloaded.activeFence, fence);
      expect(reloaded.processedThrough, processed);
      expect(reloaded.activeCutoffMs, 1690000000000);
      expect(reloaded.hasActiveScan, isTrue);

      // A malformed value must not block future scans.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(store.key, '{not-json');
      final fallback = await store.load();
      expect(fallback.committed, isNull);
      expect(fallback.hasActiveScan, isFalse);
    });

    test('2. equal timestamps are ordered deterministically by _id', () async {
      final inbox = _FakeInbox([
        _msg(1000, 105),
        _msg(1000, 104),
        _msg(1000, 103),
        _msg(1000, 102),
      ], pageSize: 2);

      final outcome = await runScan(inbox, scanner: runner(pageSize: 2));

      expect(outcome.completed, isTrue);
      expect(outcome.fence, const SmsInboxCursor(date: 1000, id: 105));
      expect(outcome.committed, const SmsInboxCursor(date: 1000, id: 105));
      // Ascending processing order is the exact reverse of the native order.
      expect(ingested.map((m) => m['id']), [102, 103, 104, 105]);

      const newer = SmsInboxCursor(date: 1000, id: 105);
      const older = SmsInboxCursor(date: 1000, id: 104);
      expect(newer.isNewerThan(older), isTrue);
      expect(older.isOlderThan(newer), isTrue);
      expect(SmsInboxCursor.compareAscending(newer, older), greaterThan(0));
    });

    test('3. normal multi-page scan ingests oldest-first and commits', () async {
      final messages = [
        _msg(700, 7),
        _msg(600, 6),
        _msg(500, 5),
        _msg(400, 4),
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ];
      final inbox = _FakeInbox(messages, pageSize: 3);

      final outcome = await runScan(inbox, scanner: runner(pageSize: 3));

      expect(outcome.completed, isTrue);
      expect(outcome.resumed, isFalse);
      expect(outcome.messagesScanned, 7);
      expect(outcome.messagesIngested, 7);
      expect(ingested.map(_bodyOf), [
        'message-1',
        'message-2',
        'message-3',
        'message-4',
        'message-5',
        'message-6',
        'message-7',
      ]);
      // Balance reconciliation sees the same target in native descending order.
      expect(balanceTargets.single, [
        'message-7',
        'message-6',
        'message-5',
        'message-4',
        'message-3',
        'message-2',
        'message-1',
      ]);
      expect(outcome.committed, const SmsInboxCursor(date: 700, id: 7));

      final reloaded = await store.load();
      expect(reloaded.committed, const SmsInboxCursor(date: 700, id: 7));
      expect(reloaded.hasActiveScan, isFalse);
    });

    test('4. interrupted ingestion resumes from durable progress', () async {
      _failSecondIngest = true;
      final inbox = _FakeInbox([
        _msg(600, 6),
        _msg(500, 5),
        _msg(400, 4),
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ], pageSize: 3);

      final first = await runScan(inbox, scanner: runner(pageSize: 3));
      expect(first.completed, isFalse);
      expect(first.committed, isNull);
      expect(ingested.map(_bodyOf), ['message-1', 'message-2']);
      expect(balanceCalls, 0);

      final interrupted = await store.load();
      expect(interrupted.committed, isNull);
      expect(
        interrupted.processedThrough,
        const SmsInboxCursor(date: 200, id: 2),
      );

      _failSecondIngest = false;
      ingested.clear();
      ingestBatches.clear();
      ingestCalls = 0;

      final second = await runScan(
        inbox,
        scanner: runner(pageSize: 3),
      );
      expect(second.completed, isTrue);
      expect(second.resumed, isTrue);
      expect(ingested.map(_bodyOf), [
        'message-3',
        'message-4',
        'message-5',
        'message-6',
      ]);
      // Balance pass still covers the full scan target, including the prefix
      // ingested before the interruption.
      expect(balanceTargets.single, [
        'message-6',
        'message-5',
        'message-4',
        'message-3',
        'message-2',
        'message-1',
      ]);
      expect(second.committed, const SmsInboxCursor(date: 600, id: 6));
    });

    test('5. failed balance reconciliation does not advance the watermark',
        () async {
      final inbox = _FakeInbox([
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ]);

      final first = await runScan(
        inbox,
        scanner: runner(batchSize: 10),
        failBalances: true,
      );
      expect(first.completed, isFalse);
      expect(first.committed, isNull);
      expect(ingested.map(_bodyOf), ['message-1', 'message-2', 'message-3']);

      final paused = await store.load();
      expect(paused.committed, isNull);
      expect(paused.processedThrough, const SmsInboxCursor(date: 300, id: 3));

      ingested.clear();
      ingestCalls = 0;
      final retry = await runScan(inbox, scanner: runner(batchSize: 10));
      expect(retry.completed, isTrue);
      // Ingestion was already durable; only balances are retried.
      expect(ingested, isEmpty);
      expect(balanceCalls, 2);
      expect(retry.committed, const SmsInboxCursor(date: 300, id: 3));
    });

    test('6. failure after processing but before commit does not advance',
        () async {
      var saveCalls = 0;
      SmsInboxWatermarkStore.testSaveInterceptor = (prefs, key, value) async {
        saveCalls++;
        final decoded = jsonDecode(value) as Map<String, dynamic>;
        final isFinalCommit =
            decoded['committed'] != null && decoded['active'] == null;
        if (isFinalCommit) return false;
        return prefs.setString(key, value);
      };

      final inbox = _FakeInbox([_msg(200, 2), _msg(100, 1)]);
      final first = await runScan(inbox, scanner: runner(batchSize: 10));
      expect(first.completed, isFalse);
      expect(first.committed, isNull);
      expect(saveCalls, greaterThanOrEqualTo(3));

      final paused = await store.load();
      expect(paused.committed, isNull);
      expect(paused.processedThrough, const SmsInboxCursor(date: 200, id: 2));

      SmsInboxWatermarkStore.testSaveInterceptor = null;
      ingested.clear();
      ingestCalls = 0;
      final retry = await runScan(inbox, scanner: runner(batchSize: 10));
      expect(retry.completed, isTrue);
      expect(ingested, isEmpty, reason: 'processed messages are not re-ingested');
      expect(balanceCalls, 2, reason: 'balances are re-applied idempotently');
      expect(retry.committed, const SmsInboxCursor(date: 200, id: 2));
    });

    test('7. a new SMS above the fence is caught by the next scan', () async {
      final inbox = _FakeInbox([
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ], pageSize: 1);
      inbox.afterFetch = (call) {
        if (call == 1) {
          // Arrives while the scan is already progressing downwards.
          inbox.messages.insert(0, _msg(400, 4));
        }
      };

      final first = await runScan(inbox, scanner: runner(pageSize: 1));
      expect(first.completed, isTrue);
      expect(ingested.map(_bodyOf), ['message-1', 'message-2', 'message-3']);
      expect(ingested.map(_bodyOf), isNot(contains('message-4')));
      expect(first.committed, const SmsInboxCursor(date: 300, id: 3));

      ingested.clear();
      ingestBatches.clear();
      ingestCalls = 0;
      final second = await runScan(inbox, scanner: runner(pageSize: 1));
      expect(second.completed, isTrue);
      expect(ingested.map(_bodyOf), ['message-4']);
      expect(second.committed, const SmsInboxCursor(date: 400, id: 4));
    });

    test('8. multiple new SMS during a scan are all caught next time', () async {
      final inbox = _FakeInbox([
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ], pageSize: 1);
      inbox.afterFetch = (call) {
        if (call == 1) {
          inbox.messages.insertAll(0, [
            _msg(500, 5),
            _msg(400, 4),
          ]);
        }
      };

      final first = await runScan(inbox, scanner: runner(pageSize: 1));
      expect(first.completed, isTrue);
      expect(ingested.map(_bodyOf), ['message-1', 'message-2', 'message-3']);

      ingested.clear();
      ingestBatches.clear();
      ingestCalls = 0;
      final second = await runScan(inbox, scanner: runner(pageSize: 1));
      expect(second.completed, isTrue);
      expect(ingested.map(_bodyOf), ['message-4', 'message-5']);
      expect(second.committed, const SmsInboxCursor(date: 500, id: 5));
    });

    test('9. empty inbox and first run are safe', () async {
      final empty = _FakeInbox([]);
      final first = await runScan(empty, scanner: runner());
      expect(first.completed, isTrue);
      expect(first.messagesScanned, 0);
      expect(first.committed, isNull);

      final checkpoint = await store.load();
      expect(checkpoint.committed, isNull);
      expect(checkpoint.lastScanAtMs, isNotNull);
      expect(checkpoint.lastCompletedAtMs, isNotNull);

      // Messages arriving after an empty scan are picked up by the next scan.
      empty.messages = [_msg(200, 2), _msg(100, 1)];
      ingested.clear();
      final second = await runScan(empty, scanner: runner());
      expect(second.completed, isTrue);
      expect(ingested.map(_bodyOf), ['message-1', 'message-2']);
      expect(second.committed, const SmsInboxCursor(date: 200, id: 2));
    });

    test('10. deleted messages do not cause loops or lost progress', () async {
      final inbox = _FakeInbox([
        _msg(500, 5),
        _msg(400, 4),
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ], pageSize: 2);
      inbox.afterFetch = (call) {
        if (call == 1) {
          // The next page's first row is deleted between page queries.
          inbox.messages.removeWhere((m) => m['id'] == 3);
        }
      };

      final first = await runScan(inbox, scanner: runner(pageSize: 2));
      expect(first.completed, isTrue);
      expect(inbox.fetchCalls, 2);
      expect(ingested.map(_bodyOf), [
        'message-1',
        'message-2',
        'message-4',
        'message-5',
      ]);
      expect(first.committed, const SmsInboxCursor(date: 500, id: 5));

      // Even if the committed row itself disappears, the watermark is not
      // regressed and a later arrival is still processed.
      inbox.messages.removeWhere((m) => (m['id'] as int) >= 4);
      ingested.clear();
      ingestCalls = 0;
      final second = await runScan(inbox, scanner: runner(pageSize: 2));
      expect(second.completed, isTrue);
      expect(ingested, isEmpty);
      expect((await store.load()).committed,
          const SmsInboxCursor(date: 500, id: 5));

      inbox.messages.insert(0, _msg(600, 6));
      ingested.clear();
      ingestCalls = 0;
      final third = await runScan(inbox, scanner: runner(pageSize: 2));
      expect(third.completed, isTrue);
      expect(ingested.map(_bodyOf), ['message-6']);
      expect(third.committed, const SmsInboxCursor(date: 600, id: 6));
    });

    test('11. a failed page propagates a partial, retryable result', () async {
      final inbox = _FakeInbox([
        _msg(500, 5),
        _msg(400, 4),
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ], pageSize: 2);
      inbox.failOnFetchCall = 2;

      final first = await runScan(inbox, scanner: runner(pageSize: 2));
      expect(first.completed, isFalse);
      expect(first.error, isNotNull);
      expect(first.messagesScanned, 2);
      expect(ingested, isEmpty, reason: 'partial pages are not committed');
      expect(balanceCalls, 0);
      expect((await store.load()).committed, isNull);

      inbox.failOnFetchCall = null;
      ingested.clear();
      ingestCalls = 0;
      final retry = await runScan(inbox, scanner: runner(pageSize: 2));
      expect(retry.completed, isTrue);
      expect(ingested.map(_bodyOf), [
        'message-1',
        'message-2',
        'message-3',
        'message-4',
        'message-5',
      ]);
      expect(retry.committed, const SmsInboxCursor(date: 500, id: 5));
    });

    test('12. repeated execution neither loses nor duplicates messages',
        () async {
      final inbox = _FakeInbox([
        _msg(400, 4),
        _msg(300, 3),
        _msg(200, 2),
        _msg(100, 1),
      ]);

      final first = await runScan(inbox, scanner: runner(batchSize: 10));
      expect(first.completed, isTrue);
      expect(ingested.map(_bodyOf), [
        'message-1',
        'message-2',
        'message-3',
        'message-4',
      ]);

      ingested.clear();
      ingestBatches.clear();
      ingestCalls = 0;
      final second = await runScan(inbox, scanner: runner(batchSize: 10));
      expect(second.completed, isTrue);
      expect(ingested, isEmpty);
      expect(ingestCalls, 0);
      expect(second.committed, const SmsInboxCursor(date: 400, id: 4));

      inbox.messages.insert(0, _msg(500, 5));
      ingested.clear();
      ingestCalls = 0;
      final third = await runScan(inbox, scanner: runner(batchSize: 10));
      expect(third.completed, isTrue);
      expect(ingested.map(_bodyOf), ['message-5']);
      expect(third.committed, const SmsInboxCursor(date: 500, id: 5));
    });
  });
}

bool _failSecondIngest = false;
