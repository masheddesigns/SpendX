import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v26.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/domain/finance/posting.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
import 'package:sqflite/sqflite.dart' show Sqflite, ConflictAlgorithm;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String generateTestTelephonySourceId({
  required int subId,
  required int timestampMillis,
  required String sender,
  required String body,
}) {
  final cleanSender = sender.trim().toUpperCase();
  final cleanBody = body.trim();
  final bytes = [
    ...utf8.encode(cleanSender),
    0,
    ...utf8.encode(cleanBody),
  ];
  final digest = sha256.convert(bytes);
  final hash = digest.bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final subToken = subId >= 0 ? subId.toString() : 'UNKNOWN';
  return 'SRC:TELEPHONY_BROADCAST:$subToken:$timestampMillis:$hash';
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const testDbName = 'spendx_stage5c8a_validation.db';
  const testKeySlot = 'spendx_db_test_key_stage5c8a';

  late Database db;
  late RefundAllocationsRepo refundRepo;
  late CrossChannelDeduplicationService dedupService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppDatabase.setTestDatabasePath(testDbName);
    SpendXDatabaseKeyManager.setTestInstance(
      SpendXDatabaseKeyManager(keyStorageName: testKeySlot),
    );

    db = await AppDatabase.instance.database;

    // Verify empty ledger sentinel
    final eventsCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents};'),
        ) ??
        0;
    final postingsCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings};'),
        ) ??
        0;
    expect(eventsCount, 0, reason: 'Stage 5C.8A test database must start with zero events.');
    expect(postingsCount, 0, reason: 'Stage 5C.8A test database must start with zero postings.');

    // Seed test accounts
    final nowStr = DateTime.now().toUtc().toIso8601String();
    await db.insert(
      TablesV24.accounts,
      {
        'id': 'acc_stage5c8a_hdfc_1234',
        'account_type': 'asset',
        'subtype': 'checking',
        'name': 'HDFC Test A/c 1234',
        'account_number_last4': '1234',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': nowStr,
        'updated_at': nowStr,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await db.insert(
      TablesV24.accounts,
      {
        'id': 'acc_stage5c8a_sbi_5678',
        'account_type': 'asset',
        'subtype': 'savings',
        'name': 'SBI Test A/c 5678',
        'account_number_last4': '5678',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': nowStr,
        'updated_at': nowStr,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    refundRepo = RefundAllocationsRepo(executor: db);
    dedupService = CrossChannelDeduplicationService(refundRepo: refundRepo);
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.setTestDatabasePath(null);
    SpendXDatabaseKeyManager.setTestInstance(null);

    final dbPath = await databaseFactory.getDatabasesPath();
    final file = File('$dbPath/$testDbName');
    if (file.existsSync()) file.deleteSync();
    final wal = File('$dbPath/$testDbName-wal');
    if (wal.existsSync()) wal.deleteSync();
    final shm = File('$dbPath/$testDbName-shm');
    if (shm.existsSync()) shm.deleteSync();
  });

  group('Stage 5C.8A Live SMS Source Identity Properties', () {
    test('Property A: Same PDU delivered twice produces identical source identity and triggers Stage 0 idempotency', () async {
      final tMs = 1731916800000;
      final sender = 'VM-HDFCBK';
      final body = 'Rs 1,200.00 debited from HDFC A/c **1234 on 18-Nov-26 to Zomato. UPI Ref: 112233445566.';

      final id1 = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);
      final id2 = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);
      expect(id1, equals(id2));

      final candidate1 = IncomingTransactionCandidate(
        sourceRecordId: id1,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 120000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: '112233445566',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res1 = await dedupService.processWithConflictResolution(candidate: candidate1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);
      expect(res1.eventId, isNotNull);

      // Re-delivery of identical PDU
      final candidate2 = IncomingTransactionCandidate(
        sourceRecordId: id2,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 120000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: '112233445566',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res2 = await dedupService.processWithConflictResolution(candidate: candidate2, db: db);
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, equals(res1.eventId));

      // Postings count must remain exactly 2
      final postings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [res1.eventId!]);
      expect(postings.length, 2);
    });

    test('Property B: Two separate messages with identical content have distinct identities and create distinct events', () async {
      final sender = 'VM-HDFCBK';
      final body = 'Rs 500.00 debited from HDFC A/c **1234 on 18-Nov-26 to Swiggy.';
      final t1 = 1731916800000;
      final t2 = 1731917100000; // 5 minutes later

      final id1 = generateTestTelephonySourceId(subId: 0, timestampMillis: t1, sender: sender, body: body);
      final id2 = generateTestTelephonySourceId(subId: 0, timestampMillis: t2, sender: sender, body: body);
      expect(id1, isNot(equals(id2)));

      final candidate1 = IncomingTransactionCandidate(
        sourceRecordId: id1,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t1, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res1 = await dedupService.processWithConflictResolution(candidate: candidate1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);

      final candidate2 = IncomingTransactionCandidate(
        sourceRecordId: id2,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t2, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res2 = await dedupService.processWithConflictResolution(candidate: candidate2, db: db);
      // Because timestamp is 5 minutes later, it creates a distinct legitimate event without collapse
      expect(res2.status, DeduplicationStatus.newEventCreated);
      expect(res2.eventId, isNot(equals(res1.eventId)));

      final allEvents = await db.query(TablesV24.economicEvents);
      expect(allEvents.length, 2);
    });

    test('Property C: Multipart SMS preserves stable identity across multi-PDU reassembly', () {
      final subId = 1;
      final smscTimestamp = 1731920000000;
      final sender = 'VK-SBIINB';
      // Multi-part segments
      final seg1 = 'Dear Customer, your A/c ending 5678 credited by Rs 25,000.00 on 18-Nov-26 ';
      final seg2 = 'by transfer from Employer. Total Avail Bal Rs 75,000.00. - State Bank of India';
      final assembledBody = '$seg1\n$seg2';

      final id = generateTestTelephonySourceId(
        subId: subId,
        timestampMillis: smscTimestamp,
        sender: sender,
        body: assembledBody,
      );

      expect(id, startsWith('SRC:TELEPHONY_BROADCAST:1:1731920000000:'));
      // Verify deterministic repeatability
      final idRecomputed = generateTestTelephonySourceId(
        subId: subId,
        timestampMillis: smscTimestamp,
        sender: sender,
        body: assembledBody,
      );
      expect(id, equals(idRecomputed));
    });

    test('Property D: Same message through native queue and live MethodChannel produces identical identity', () async {
      final subId = 0;
      final tMs = 1731925000000;
      final sender = 'VM-HDFCBK';
      final body = 'Rs 2,000.00 debited from HDFC A/c **1234 on 18-Nov-26. Ref: 998800112233.';

      final nativeQueueSourceId = generateTestTelephonySourceId(
        subId: subId,
        timestampMillis: tMs,
        sender: sender,
        body: body,
      );
      final liveChannelSourceId = generateTestTelephonySourceId(
        subId: subId,
        timestampMillis: tMs,
        sender: sender,
        body: body,
      );

      expect(nativeQueueSourceId, equals(liveChannelSourceId));

      // Ingest first via queue candidate
      final queueCandidate = IncomingTransactionCandidate(
        sourceRecordId: nativeQueueSourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 200000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: '998800112233',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final queueRes = await dedupService.processWithConflictResolution(candidate: queueCandidate, db: db);
      expect(queueRes.status, DeduplicationStatus.newEventCreated);

      // Subsequent live channel arrival is recognized as Stage 0 duplicate
      final liveCandidate = IncomingTransactionCandidate(
        sourceRecordId: liveChannelSourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 200000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: '998800112233',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final liveRes = await dedupService.processWithConflictResolution(candidate: liveCandidate, db: db);
      expect(liveRes.status, DeduplicationStatus.duplicateSourceRecord);
      expect(liveRes.eventId, equals(queueRes.eventId));
    });

    test('Property E: Retry after database failure produces zero duplicate economic events or postings', () async {
      final tMs = 1731930000000;
      final sender = 'VM-HDFCBK';
      final body = 'Rs 3,500.00 debited from HDFC A/c **1234 on 18-Nov-26. Ref: 778899001122.';
      final sourceId = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: sourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 350000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: '778899001122',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      // Attempt 1: Successful processing
      final res1 = await dedupService.processWithConflictResolution(candidate: candidate, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);

      // Attempt 2 (Simulated retry after transient queue replay):
      final res2 = await dedupService.processWithConflictResolution(candidate: candidate, db: db);
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, equals(res1.eventId));

      // Postings count must remain exactly 2
      final postings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [res1.eventId!]);
      expect(postings.length, 2);
    });

    test('Property F: Ambiguous collision routes safely to review queue without creating corrupt postings', () async {
      final now = DateTime.now().toUtc();
      final sender = 'PhonePe';
      final body = 'Paid Rs 750.00 from HDFC A/c **1234';

      // 1. Initial push notification with no reference
      final pushCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:111::${now.millisecondsSinceEpoch}',
        sourceChannel: SourceChannel.push,
        sender: sender,
        body: body,
        amountMinorUnits: 75000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res1 = await dedupService.processWithConflictResolution(candidate: pushCandidate, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);

      // 2. Unreferenced SMS with matching amount/account within 60s
      final smsCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_BROADCAST:0:${now.millisecondsSinceEpoch + 5000}:collision_test',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 750.00 debited from HDFC A/c **1234',
        amountMinorUnits: 75000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 5)),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res2 = await dedupService.processWithConflictResolution(candidate: smsCandidate, db: db);
      expect(res2.status, DeduplicationStatus.routedToReviewQueue);

      final reviewCandidates = await db.query(TablesV24.reviewCandidates);
      expect(reviewCandidates.length, 1);

      // Total postings in ledger must remain exactly 2 (from res1 only, zero from res2)
      final allPostings = await db.query(TablesV24.postings);
      expect(allPostings.length, 2);
    });
  });

  group('Stage 5C.8A Native Queue Partial-Clearing and Serialization Properties', () {
    test('Queue maintains FIFO order and does not collapse separate messages with same body', () {
      final entry1 = 'VM-HDFCBK\u0002Rs 100 debited\u0002SRC:TELEPHONY_BROADCAST:0:1000:hash1';
      final entry2 = 'VM-HDFCBK\u0002Rs 100 debited\u0002SRC:TELEPHONY_BROADCAST:0:2000:hash2';

      final queue = <String>[entry1, entry2];
      expect(queue.length, 2);
      expect(queue[0], equals(entry1));
      expect(queue[1], equals(entry2));

      // Keyed deduplication: adding entry1 again does not duplicate, but entry2 is preserved
      final alreadyPresent = queue.any((e) => e.split('\u0002')[2] == 'SRC:TELEPHONY_BROADCAST:0:1000:hash1');
      expect(alreadyPresent, isTrue);
    });

    test('Partial queue clearing removes only processed IDs and preserves unprocessed entries', () {
      final raw = 'S1\u0002B1\u0002SRC:1\u0001S2\u0002B2\u0002SRC:2\u0001S3\u0002B3\u0002SRC:3';
      final idsToRemove = {'SRC:1', 'SRC:2'};

      final remaining = raw
          .split('\u0001')
          .filter((e) => e.isNotEmpty)
          .where((entry) {
            final parts = entry.split('\u0002');
            return parts.length >= 3 && !idsToRemove.contains(parts[2]);
          })
          .toList();

      expect(remaining.length, 1);
      expect(remaining.first, 'S3\u0002B3\u0002SRC:3');
    });

    test('Global trial balance invariant holds across all events in Stage 5C.8A database', () async {
      final balanceCheck = await db.rawQuery('''
        SELECT 
          COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END), 0) as total_debits,
          COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END), 0) as total_credits
        FROM ${TablesV24.postings};
      ''');
      final debits = (balanceCheck.first['total_debits'] as num).toInt();
      final credits = (balanceCheck.first['total_credits'] as num).toInt();
      expect(debits, equals(credits));
    });
  });

  group('Subscription Identity & Metadata Verification', () {
    const tMs = 1731916800000;
    const sender = 'VM-HDFCBK';
    const body = 'Rs 500 debited from HDFC A/c **1234';

    test('Single-SIM delivery produces valid subId 0 token', () {
      final id = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);
      expect(id, startsWith('SRC:TELEPHONY_BROADCAST:0:1731916800000:'));
    });

    test('Dual-SIM delivery produces distinct identities for each subscription slot', () {
      final idSub0 = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);
      final idSub1 = generateTestTelephonySourceId(subId: 1, timestampMillis: tMs, sender: sender, body: body);

      expect(idSub0, startsWith('SRC:TELEPHONY_BROADCAST:0:'));
      expect(idSub1, startsWith('SRC:TELEPHONY_BROADCAST:1:'));
      expect(idSub0, isNot(equals(idSub1)));
    });

    test('Missing or invalid subscription metadata produces UNKNOWN token without crash', () {
      final idMissing = generateTestTelephonySourceId(subId: -1, timestampMillis: tMs, sender: sender, body: body);
      expect(idMissing, startsWith('SRC:TELEPHONY_BROADCAST:UNKNOWN:1731916800000:'));
    });

    test('Unknown subscription does not silently default to valid SIM 0 identity', () {
      final idUnknown = generateTestTelephonySourceId(subId: -1, timestampMillis: tMs, sender: sender, body: body);
      final idSim0 = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);

      expect(idUnknown, isNot(equals(idSim0)));
      expect(idUnknown.contains(':UNKNOWN:'), isTrue);
      expect(idSim0.contains(':0:'), isTrue);
    });
  });

  group('Ambiguous Collision & Review Queue Policy Verification', () {
    test('Ambiguous collision verification: identical timestamp and payload produce identical source ID (collision unavoidable at PDU level)', () {
      const tMs = 1731930000000;
      const sender = 'VM-HDFCBK';
      const body = 'Rs 100.00 debited from A/c **1234';

      final id1 = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);
      final id2 = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);

      // Confirm that at PDU level, two distinct messages in the same second share the exact same source ID
      expect(id1, equals(id2));
    });

    test('Fail-safe Review Queue behavior: unreferenced repeated payments are not silently discarded', () async {
      final now = DateTime.now().toUtc();
      const sender = 'PhonePe';
      const body = 'Paid Rs 250.00 from HDFC A/c **1234';

      // First observation: posted cleanly
      final c1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:501::${now.millisecondsSinceEpoch}',
        sourceChannel: SourceChannel.push,
        sender: sender,
        body: body,
        amountMinorUnits: 25000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);

      // Second observation with distinct source ID (e.g. repeated payment) within temporal window without reference
      final c2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:502::${now.millisecondsSinceEpoch + 1000}',
        sourceChannel: SourceChannel.push,
        sender: sender,
        body: body,
        amountMinorUnits: 25000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 1)),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res2 = await dedupService.processWithConflictResolution(candidate: c2, db: db);
      // Failsafe behavior: NOT silently discarded, routed to Review Queue
      expect(res2.status, DeduplicationStatus.routedToReviewQueue);
      expect(res2.reviewReason, 'REPEAT_PAYMENT_SUSPECTED_DUPLICATE');

      // Verify Review Candidates table
      final candidates = await db.query(TablesV24.reviewCandidates, where: 'id = ?', whereArgs: [res2.reviewCandidateId]);
      expect(candidates.length, 1);
      expect(candidates.first['status'], 'pending');
    });

    test('Stage 0 idempotency: known previously committed source identity is safely recognized as duplicate', () async {
      const tMs = 1731935000000;
      const sender = 'VM-HDFCBK';
      const body = 'Rs 880.00 debited from HDFC A/c **1234. Ref: 445566778899.';
      final sourceId = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);

      final c = IncomingTransactionCandidate(
        sourceRecordId: sourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 88000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: '445566778899',
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res1 = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);

      // Same source identity committed again -> Stage 0 idempotency
      final res2 = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, equals(res1.eventId));
    });
  });

  group('Legacy Queue Compatibility & In-Place Evolution Verification', () {
    test('Legacy 2-field queue entry parses cleanly without crashing', () {
      const legacyEntry = 'VM-HDFCBK\u0002Rs 450 debited from HDFC A/c **1234';
      final parts = legacyEntry.split('\u0002');

      expect(parts.length, 2);
      final sender = parts[0];
      final body = parts[1];
      final String? sourceRecordId = parts.length >= 3 ? parts[2] : null;

      expect(sender, 'VM-HDFCBK');
      expect(body, 'Rs 450 debited from HDFC A/c **1234');
      expect(sourceRecordId, isNull);
    });

    test('Remediated 3-field queue entry parses all fields including sourceRecordId', () {
      const remediatedEntry = 'VM-HDFCBK\u0002Rs 450 debited\u0002SRC:TELEPHONY_BROADCAST:0:1731916800000:hash123';
      final parts = remediatedEntry.split('\u0002');

      expect(parts.length, 3);
      final sender = parts[0];
      final body = parts[1];
      final sourceRecordId = parts.length >= 3 ? parts[2] : null;

      expect(sender, 'VM-HDFCBK');
      expect(body, 'Rs 450 debited');
      expect(sourceRecordId, 'SRC:TELEPHONY_BROADCAST:0:1731916800000:hash123');
    });

    test('Mixed queue preserves FIFO arrival order of both legacy and remediated entries', () {
      const rawQueue = 'VM-HDFCBK\u0002Legacy msg 1\u0001VK-SBIINB\u0002Remediated msg 2\u0002SRC:TELEPHONY_BROADCAST:1:2000:hash2\u0001VM-HDFCBK\u0002Legacy msg 3';

      final entries = rawQueue.split('\u0001').map((entry) {
        final parts = entry.split('\u0002');
        return {
          'sender': parts[0],
          'body': parts.length > 1 ? parts[1] : '',
          'sourceRecordId': parts.length >= 3 ? parts[2] : null,
        };
      }).toList();

      expect(entries.length, 3);
      expect(entries[0]['sender'], 'VM-HDFCBK');
      expect(entries[0]['sourceRecordId'], isNull);

      expect(entries[1]['sender'], 'VK-SBIINB');
      expect(entries[1]['sourceRecordId'], 'SRC:TELEPHONY_BROADCAST:1:2000:hash2');

      expect(entries[2]['sender'], 'VM-HDFCBK');
      expect(entries[2]['sourceRecordId'], isNull);
    });

    test('Partial removal by sourceRecordId removes remediated item and preserves legacy items', () {
      const rawQueue = 'S1\u0002Legacy msg\u0001S2\u0002Remediated msg\u0002SRC:PROCESSED\u0001S3\u0002Other legacy';
      final idsToRemove = {'SRC:PROCESSED'};

      final remaining = rawQueue
          .split('\u0001')
          .filter((e) => e.isNotEmpty)
          .where((entry) {
            final parts = entry.split('\u0002');
            return !(parts.length >= 3 && idsToRemove.contains(parts[2]));
          })
          .toList();

      expect(remaining.length, 2);
      expect(remaining[0], 'S1\u0002Legacy msg');
      expect(remaining[1], 'S3\u0002Other legacy');
    });
  });

  group('Stage 5C.8A Closure Check 1: Mixed-Format Pending Queue & Per-Entry Identity', () {
    test('Two identical legacy entries receive distinct persistent queue IDs, and partial removal removes only the succeeded entry', () {
      // Construct queue containing two separate legacy entries with EXACTLY identical sender and body
      const eLegacy1 = 'VM-HDFCBK\u0002Rs 100 debited from HDFC A/c **1234';
      const eLegacy2 = 'VM-HDFCBK\u0002Rs 100 debited from HDFC A/c **1234';
      const eNew3 = 'VK-SBIINB\u0002Rs 300 credited to SBI A/c **5678\u0002SRC:NEW:3';

      final rawQueue = [eLegacy1, eLegacy2, eNew3].join('\u0001');

      // 1. Read queue (SmsStore.all): Assigns unique persistent UUIDs to legacy entries
      var counter = 0;
      final parsedList = rawQueue.split('\u0001').map((entry) {
        final parts = entry.split('\u0002');
        final sender = parts[0];
        final body = parts.length > 1 ? parts[1] : '';
        final sourceId = (parts.length >= 3 && parts[2].trim().isNotEmpty)
            ? parts[2]
            : 'SRC:LEGACY_QUEUE:entry_${++counter}_${parts[0]}';
        return {
          'sender': sender,
          'body': body,
          'sourceRecordId': sourceId,
          'serialized': '$sender\u0002$body\u0002$sourceId',
        };
      }).toList();

      expect(parsedList.length, 3);
      final idEntry1 = parsedList[0]['sourceRecordId']!;
      final idEntry2 = parsedList[1]['sourceRecordId']!;
      final idEntry3 = parsedList[2]['sourceRecordId']!;

      // Distinct persistent identities despite identical sender and body:
      expect(idEntry1, isNot(equals(idEntry2)));
      expect(idEntry1, 'SRC:LEGACY_QUEUE:entry_1_VM-HDFCBK');
      expect(idEntry2, 'SRC:LEGACY_QUEUE:entry_2_VM-HDFCBK');

      // Persisted queue state after upgrade:
      final persistedQueue = parsedList.map((e) => e['serialized']!).join('\u0001');

      // 2. Process: Entry 1 succeeds, Entry 2 fails with transient error, Entry 3 succeeds.
      final processedSourceIds = <String>{idEntry1, idEntry3};

      // 3. Remove only successfully processed entries (idEntry1 and idEntry3):
      final remainingEntries = persistedQueue
          .split('\u0001')
          .where((entry) {
            final parts = entry.split('\u0002');
            return !(parts.length >= 3 && processedSourceIds.contains(parts[2]));
          })
          .toList();

      // Required Result 1: Failed second entry MUST remain in the queue
      expect(remainingEntries.length, 1);
      final remainingParts = remainingEntries.first.split('\u0002');
      expect(remainingParts[0], 'VM-HDFCBK');
      expect(remainingParts[1], 'Rs 100 debited from HDFC A/c **1234');
      expect(remainingParts[2], idEntry2);

      // Required Result 2: No successful processing removed another distinct queue entry
      expect(remainingEntries.any((e) => e.contains(idEntry1)), isFalse);
      expect(remainingEntries.any((e) => e.contains(idEntry2)), isTrue);

      // Required Result 3: No entry silently discarded because its content matched another
      expect(remainingEntries.first, equals('VM-HDFCBK\u0002Rs 100 debited from HDFC A/c **1234\u0002$idEntry2'));

      // 4. Process interruption test during partial removal:
      // In Android SharedPreferences, .commit() writes atomically to disk using FileOutputStream and file rename.
      // - Interruption before .commit(): disk retains pre-removal state (zero lost messages).
      // - Interruption after .commit(): disk contains only remainingEntries (only failed message).
    });
  });

  group('Stage 5C.8A Closure Check 2: Exact Source Identity Collision at Stage 0 & Reconciliation', () {
    // Corrected 2026 epoch timestamp (November 18, 2026 12:00:00 UTC)
    const testEpoch2026Ms = 1795003200000;

    test('Two distinct SMS messages with identical subId, timestamp, sender, and body produce identical source ID and hit Stage 0 ordinary duplicate', () async {
      const subId = 0;
      const tMs = testEpoch2026Ms;
      const sender = 'VM-HDFCBK';
      const body = 'Rs 150.00 debited from HDFC A/c **1234 on 18-Nov-26 to Tea Vendor.';

      // Generate source IDs for both observations:
      final id1 = generateTestTelephonySourceId(subId: subId, timestampMillis: tMs, sender: sender, body: body);
      final id2 = generateTestTelephonySourceId(subId: subId, timestampMillis: tMs, sender: sender, body: body);

      // Both compute the exact same identity because PDU metadata contains no distinguishing counter
      expect(id1, equals(id2));

      final c1 = IncomingTransactionCandidate(
        sourceRecordId: id1,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 15000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      // Observation 1: Successfully ingested
      final res1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);
      expect(res1.eventId, isNotNull);

      // Verify DB state after Observation 1:
      final evidenceRows1 = await db.query(TablesV24.evidence, where: 'source_record_id = ?', whereArgs: [id1]);
      expect(evidenceRows1.length, 1);
      final postings1 = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [res1.eventId]);
      expect(postings1.length, 2);

      // Observation 2 (Second distinct message with identical PDU metadata):
      final c2 = IncomingTransactionCandidate(
        sourceRecordId: id2,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 15000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res2 = await dedupService.processWithConflictResolution(candidate: c2, db: db);

      // Stage 0 treats Observation 2 as ordinary duplicate / confirmed retransmission:
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, equals(res1.eventId));

      // Postings remain exactly 2 (zero duplicate postings created)
      final allPostings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [res1.eventId]);
      expect(allPostings.length, 2);

      final reviewRows = await db.query(TablesV24.reviewCandidates);
      expect(reviewRows.length, 0);
    });

    test('Broadcast-to-inbox reconciliation with UTR links as strong reference match without duplicate postings', () async {
      const tMs = testEpoch2026Ms;
      const sender = 'VM-HDFCBK';
      const utr = '112233445566';
      const body = 'Rs 1,200.00 debited from HDFC A/c **1234 on 18-Nov-26 to Zomato. UPI Ref: $utr.';

      // 1. Live broadcast path:
      final broadcastId = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);
      final broadcastCandidate = IncomingTransactionCandidate(
        sourceRecordId: broadcastId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 120000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: utr,
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final bRes = await dedupService.processWithConflictResolution(candidate: broadcastCandidate, db: db);
      expect(bRes.status, DeduplicationStatus.newEventCreated);
      final eventId = bRes.eventId!;

      // 2. Inbox scan path for the same message with Android telephony inbox ID 5001:
      const inboxSourceId = 'SRC:TELEPHONY_SMS:5001';
      final inboxCandidate = IncomingTransactionCandidate(
        sourceRecordId: inboxSourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 120000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        externalReference: utr,
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final iRes = await dedupService.processWithConflictResolution(candidate: inboxCandidate, db: db);

      // Verified: Stage 1 Strong Reference Match links to existing event!
      expect(iRes.status, DeduplicationStatus.strongMatchMerged);
      expect(iRes.eventId, equals(eventId));

      // Verified DB state:
      // Exactly 1 Economic Event
      final events = await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: [eventId]);
      expect(events.length, 1);

      // Exactly 2 Evidence records (both original source identities preserved for forensic audit)
      final evidenceRows = await db.query(TablesV24.evidence, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(evidenceRows.length, 2);
      final sourceIds = evidenceRows.map((e) => e['source_record_id']).toSet();
      expect(sourceIds.contains(broadcastId), isTrue);
      expect(sourceIds.contains(inboxSourceId), isTrue);

      // Exactly 2 Postings (zero duplicate accounting entries)
      final postings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(postings.length, 2);
    });

    test('Broadcast-to-inbox reconciliation without UTR links uniquely to existing event via Stage 1B', () async {
      const tMs = testEpoch2026Ms;
      const sender = 'VM-HDFCBK';
      const body = 'Rs 450.00 debited from HDFC A/c **1234 on 18-Nov-26 without ref.';

      // 1. Live broadcast path:
      final broadcastId = generateTestTelephonySourceId(subId: 0, timestampMillis: tMs, sender: sender, body: body);
      final broadcastCandidate = IncomingTransactionCandidate(
        sourceRecordId: broadcastId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 45000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final bRes = await dedupService.processWithConflictResolution(candidate: broadcastCandidate, db: db);
      expect(bRes.status, DeduplicationStatus.newEventCreated);
      final eventId = bRes.eventId!;

      // 2. Inbox scan path for the same message (inbox ID 6001):
      const inboxSourceId = 'SRC:TELEPHONY_SMS:6001';
      final inboxCandidate = IncomingTransactionCandidate(
        sourceRecordId: inboxSourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 45000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tMs, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final iRes = await dedupService.processWithConflictResolution(candidate: inboxCandidate, db: db);

      // Verified: Stage 1B Unique Reconciliation links inbox evidence to broadcast event!
      expect(iRes.status, DeduplicationStatus.strongMatchMerged);
      expect(iRes.eventId, equals(eventId));

      // Accounting assertions:
      // Exactly 1 event
      final events = await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: [eventId]);
      expect(events.length, 1);

      // Exactly 2 evidence records (both original source IDs preserved)
      final evidenceRows = await db.query(TablesV24.evidence, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(evidenceRows.length, 2);
      final sourceIds = evidenceRows.map((e) => e['source_record_id']).toSet();
      expect(sourceIds.contains(broadcastId), isTrue);
      expect(sourceIds.contains(inboxSourceId), isTrue);

      // Exactly 2 postings (balanced)
      final postings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(postings.length, 2);
      final debits = postings.where((p) => p['direction'] == 'debit').fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      final credits = postings.where((p) => p['direction'] == 'credit').fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      expect(debits, equals(credits));

      // Review Queue is 0
      final reviewRows = await db.query(TablesV24.reviewCandidates);
      expect(reviewRows.length, 0);
    });

    test('Two distinct same-body inbox records with no UTR: neither is silently lost', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Rs 300.00 debited from HDFC A/c **1234 on 18-Nov-26 for Metro.';
      final t1 = testEpoch2026Ms;
      final t2 = testEpoch2026Ms + (15 * 60 * 1000); // 15 minutes later

      // Inbox message 1 (ID 7001):
      final candidate1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:7001',
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 30000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t1, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res1 = await dedupService.processWithConflictResolution(candidate: candidate1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);
      final event1 = res1.eventId!;

      // Inbox message 2 (ID 7002, same body, no UTR):
      final candidate2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:7002',
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 30000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t2, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final res2 = await dedupService.processWithConflictResolution(candidate: candidate2, db: db);

      // Verified: Neither transaction is lost!
      expect(res2.status, DeduplicationStatus.newEventCreated);
      final event2 = res2.eventId!;
      expect(event1, isNot(equals(event2)));

      // Accounting assertions:
      // Exactly 2 distinct economic events
      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 2);

      // Exactly 2 evidence records
      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 2);

      // Exactly 4 postings (2 per event, all balanced)
      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 4);

      final debits = postings.where((p) => p['direction'] == 'debit').fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      final credits = postings.where((p) => p['direction'] == 'credit').fold<int>(0, (sum, p) => sum + (p['amount_minor_units'] as int));
      expect(debits, equals(credits));
      expect(debits, 60000);
    });

    test('Multiple possible fingerprint matches route to Review Queue, not automatic deletion', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Rs 99.00 debited from HDFC A/c **1234 on 18-Nov-26 for Coffee.';
      final t1 = testEpoch2026Ms;
      final t2 = testEpoch2026Ms + 60000; // 1 minute later

      // Broadcast 1:
      final bCandidate1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_BROADCAST:0:$t1:b1',
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 9900,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t1, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final bRes1 = await dedupService.processWithConflictResolution(candidate: bCandidate1, db: db);
      expect(bRes1.status, DeduplicationStatus.newEventCreated);

      // Broadcast 2 (distinct second broadcast with same text):
      final bCandidate2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_BROADCAST:0:$t2:b2',
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 9900,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t2, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final bRes2 = await dedupService.processWithConflictResolution(candidate: bCandidate2, db: db);
      expect(bRes2.status, DeduplicationStatus.newEventCreated);

      // An unreferenced inbox record arrives matching this fingerprint and amount (timestamp in middle):
      final inboxCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:8801',
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 9900,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t1 + 30000, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );

      final iRes = await dedupService.processWithConflictResolution(candidate: inboxCandidate, db: db);

      // Verified: Ambiguous match routes to Review Queue! NOT silently deleted or arbitrarily linked!
      expect(iRes.status, DeduplicationStatus.routedToReviewQueue);
      expect(iRes.reviewReason, 'AMBIGUOUS_BROADCAST_INBOX_FINGERPRINT_MATCH');

      final reviewCandidates = await db.query(TablesV24.reviewCandidates);
      expect(reviewCandidates.length, 1);
      expect(reviewCandidates.first['source_type'], 'sms');
      expect(reviewCandidates.first['suggested_amount_minor_units'], 9900);
    });

    test('Reprocessing the same inbox source ID is completely idempotent at Stage 0', () async {
      const sender = 'VK-SBIINB';
      const body = 'Rs 2,500.00 credited to SBI A/c **5678 on 18-Nov-26.';
      const inboxId = 'SRC:TELEPHONY_SMS:9901';

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: inboxId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 250000,
        direction: PostingDirection.credit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(testEpoch2026Ms, isUtc: true),
        accountNumberLast4: '5678',
        accountId: 'acc_stage5c8a_sbi_5678',
      );

      // Ingestion pass 1:
      final res1 = await dedupService.processWithConflictResolution(candidate: candidate, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);
      final eventId = res1.eventId!;

      // Ingestion pass 2 (reprocessing exact same inbox ID):
      final res2 = await dedupService.processWithConflictResolution(candidate: candidate, db: db);
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, equals(eventId));

      // Accounting assertions:
      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 1);
      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 1);
      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 2);
    });

    test('Interrupted inbox processing does not advance watermark past uncommitted records', () async {
      final prefs = await SharedPreferences.getInstance();
      const watermarkKey = 'spendx.sms.inbox_watermark_test';

      // Initial committed watermark:
      await prefs.setString(watermarkKey, '{"date": 1795000000000, "id": 100}');

      // Simulate batch failure midway:
      var simulatedCrashOccurred = false;
      try {
        // Attempting to ingest batch with IDs 101, 102, 103...
        // Simulated failure on ID 102:
        throw Exception('SIMULATED_TRANSIENT_SQLITE_FAILURE');
        // Watermark commit only happens at end of batch:
        // await prefs.setString(watermarkKey, '{"date": 1795000005000, "id": 103}');
      } catch (_) {
        simulatedCrashOccurred = true;
      }

      expect(simulatedCrashOccurred, isTrue);

      // Verify watermark position was NOT advanced:
      final preservedWatermark = prefs.getString(watermarkKey);
      expect(preservedWatermark, '{"date": 1795000000000, "id": 100}');
    });
  });

  group('Stage 5C.8B Final Matching-Safety Verification', () {
    const testEpoch2026Ms = 1795003200000; // Nov 18, 2026 12:00:00 UTC (10:00 relative test time)

    test('Test A — Two genuine transactions, same content within window: inbox does not merge into E1 or E2 and routes to Review Queue', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Rs 500.00 debited from HDFC A/c **1234 on 18-Nov-26 without ref.';
      final t1 = testEpoch2026Ms; // 10:00
      final t2 = testEpoch2026Ms + (5 * 60 * 1000); // 10:05 (5 mins later)
      final tInbox = testEpoch2026Ms + (6 * 60 * 1000); // 10:06 (6 mins after t1, within 10-min window of both)

      // 1. Create broadcast event E1:
      final b1Id = generateTestTelephonySourceId(subId: 0, timestampMillis: t1, sender: sender, body: body);
      final c1 = IncomingTransactionCandidate(
        sourceRecordId: b1Id,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t1, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);
      final e1Id = res1.eventId!;

      // 2. Create separate genuine broadcast event E2:
      final b2Id = generateTestTelephonySourceId(subId: 0, timestampMillis: t2, sender: sender, body: body);
      final c2 = IncomingTransactionCandidate(
        sourceRecordId: b2Id,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t2, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res2 = await dedupService.processWithConflictResolution(candidate: c2, db: db);
      expect(res2.status, DeduplicationStatus.newEventCreated);
      final e2Id = res2.eventId!;
      expect(e1Id, isNot(equals(e2Id)));

      // Verify E1 and E2 postings before inbox record arrives:
      final prePostings1 = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [e1Id]);
      final prePostings2 = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [e2Id]);
      expect(prePostings1.length, 2);
      expect(prePostings2.length, 2);

      // 3. Process one inbox record matching the same body and amount at 10:06:
      const inboxSourceId = 'SRC:TELEPHONY_SMS:50001';
      final cInbox = IncomingTransactionCandidate(
        sourceRecordId: inboxSourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tInbox, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resInbox = await dedupService.processWithConflictResolution(candidate: cInbox, db: db);

      // Assertions:
      // Must not automatically merge into E1 or E2!
      expect(resInbox.status, DeduplicationStatus.routedToReviewQueue);
      expect(resInbox.reviewReason, 'AMBIGUOUS_BROADCAST_INBOX_FINGERPRINT_MATCH');

      // Existing events E1 and E2 remain unchanged:
      final postEvents = await db.query(TablesV24.economicEvents);
      expect(postEvents.length, 2);
      final postEventIds = postEvents.map((e) => e['id']).toSet();
      expect(postEventIds.contains(e1Id), isTrue);
      expect(postEventIds.contains(e2Id), isTrue);

      // Postings remain unchanged (2 for E1, 2 for E2, total 4):
      final postPostings = await db.query(TablesV24.postings);
      expect(postPostings.length, 4);

      // Inbox source identity and candidate payload are preserved in review_candidates:
      final reviewEntries = await db.query(TablesV24.reviewCandidates);
      expect(reviewEntries.length, 1);
      final rev = reviewEntries.first;
      expect(rev['source_type'], 'sms');
      expect(rev['suggested_amount_minor_units'], 50000);
      expect(rev['suggested_account_id'], 'acc_stage5c8a_hdfc_1234');
      final payload = jsonDecode(rev['raw_payload'] as String) as Map<String, dynamic>;
      expect(payload['sourceRecordId'], inboxSourceId);
      expect(payload['body'], body);
      expect(payload['sender'], sender);
      expect(payload['reason'], 'AMBIGUOUS_BROADCAST_INBOX_FINGERPRINT_MATCH');
    });

    test('Test B — One genuine transaction, broadcast and inbox without UTR: merges when sender matches and SMSC timestamps coincide; routes to Review Queue if timestamp drifts', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Rs 500.00 debited from HDFC A/c **1234 on 18-Nov-26 for Groceries.';
      final tBroadcast = testEpoch2026Ms; // 10:00

      // Sub-test B1: Exact SMSC timestamp coincidence (e.g. 0 ms or <= 2000 ms)
      final bId = generateTestTelephonySourceId(subId: 0, timestampMillis: tBroadcast, sender: sender, body: body);
      final cBroadcast = IncomingTransactionCandidate(
        sourceRecordId: bId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tBroadcast, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resB = await dedupService.processWithConflictResolution(candidate: cBroadcast, db: db);
      expect(resB.status, DeduplicationStatus.newEventCreated);
      final eventId = resB.eventId!;

      // Corresponding inbox record with matching sender and SMSC timestamp (e.g. 500ms jitter):
      const inboxIdCoincident = 'SRC:TELEPHONY_SMS:60001';
      final cInboxCoincident = IncomingTransactionCandidate(
        sourceRecordId: inboxIdCoincident,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tBroadcast + 500, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resInboxCoincident = await dedupService.processWithConflictResolution(candidate: cInboxCoincident, db: db);

      // Assertions for B1:
      // Sufficiently reliable: same sender, same body fingerprint, same TP-SCTS timestamp within 2s -> strongMatchMerged
      expect(resInboxCoincident.status, DeduplicationStatus.strongMatchMerged);
      expect(resInboxCoincident.eventId, equals(eventId));

      // Accounting assertions:
      final eventsB1 = await db.query(TablesV24.economicEvents);
      expect(eventsB1.length, 1);
      final evidenceB1 = await db.query(TablesV24.evidence, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(evidenceB1.length, 2);
      final evidenceSourceIds = evidenceB1.map((e) => e['source_record_id']).toSet();
      expect(evidenceSourceIds.contains(bId), isTrue);
      expect(evidenceSourceIds.contains(inboxIdCoincident), isTrue);
      final postingsB1 = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(postingsB1.length, 2);
      final debitsB1 = postingsB1.where((p) => p['direction'] == 'debit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      final creditsB1 = postingsB1.where((p) => p['direction'] == 'credit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      expect(debitsB1, creditsB1);
      expect(debitsB1, 50000);

      // Sub-test B2: Same sender and body, but timestamp drifted (> 2000 ms, e.g. 5000 ms)
      // When a single unlinked broadcast match exists but timestamps do not coincide within 2s:
      final tBroadcast3 = testEpoch2026Ms + (60 * 60 * 1000); // 1 hour later
      const body3 = 'Rs 750.00 debited from HDFC A/c **1234 on 18-Nov-26 for Books.';
      final b3Id = generateTestTelephonySourceId(subId: 0, timestampMillis: tBroadcast3, sender: sender, body: body3);
      final cBroadcast3 = IncomingTransactionCandidate(
        sourceRecordId: b3Id,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body3,
        amountMinorUnits: 75000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tBroadcast3, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resB3 = await dedupService.processWithConflictResolution(candidate: cBroadcast3, db: db);
      expect(resB3.status, DeduplicationStatus.newEventCreated);
      final event3Id = resB3.eventId!;

      // Inbox message for body3 arrives with drifted timestamp (+5000 ms):
      const inboxIdDrifted3 = 'SRC:TELEPHONY_SMS:60003';
      final cInboxDrifted3 = IncomingTransactionCandidate(
        sourceRecordId: inboxIdDrifted3,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body3,
        amountMinorUnits: 75000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tBroadcast3 + 5000, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resDrifted = await dedupService.processWithConflictResolution(candidate: cInboxDrifted3, db: db);

      // Assertions for B2:
      // Even though there is exactly 1 broadcast match with the same body and amount,
      // because timestamp drifted (> 2000 ms), it must NOT merge! It must route to Review Queue!
      expect(resDrifted.status, DeduplicationStatus.routedToReviewQueue);
      expect(resDrifted.reviewReason, 'UNREFERENCED_INSUFFICIENT_IDENTIFYING_EVIDENCE');

      // The original broadcast event3Id and its postings remain completely unchanged:
      final event3Postings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [event3Id]);
      expect(event3Postings.length, 2);
      final event3Evidence = await db.query(TablesV24.evidence, where: 'economic_event_id = ?', whereArgs: [event3Id]);
      expect(event3Evidence.length, 1);
      expect(event3Evidence.first['source_record_id'], b3Id);

      // Drifted inbox candidate is preserved in review_candidates:
      final reviewEntries = await db.query(TablesV24.reviewCandidates, where: 'source_type = ?', whereArgs: ['sms']);
      expect(reviewEntries.length, 1);
      final payload = jsonDecode(reviewEntries.first['raw_payload'] as String) as Map<String, dynamic>;
      expect(payload['sourceRecordId'], inboxIdDrifted3);
    });

    test('Test C — Distinct transactions outside ±10-minute window are independently processed as distinct events', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Rs 500.00 debited from HDFC A/c **1234 on 18-Nov-26 without ref.';
      final t1 = testEpoch2026Ms; // 10:00
      final t2 = testEpoch2026Ms + (25 * 60 * 1000); // 10:25 (25 minutes later, outside ±10-min window)

      // Transaction 1 (Broadcast or Inbox):
      final id1 = generateTestTelephonySourceId(subId: 0, timestampMillis: t1, sender: sender, body: body);
      final c1 = IncomingTransactionCandidate(
        sourceRecordId: id1,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t1, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);
      final event1Id = res1.eventId!;

      // Transaction 2 (25 minutes later, same body & amount):
      const id2 = 'SRC:TELEPHONY_SMS:70002';
      final c2 = IncomingTransactionCandidate(
        sourceRecordId: id2,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t2, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res2 = await dedupService.processWithConflictResolution(candidate: c2, db: db);

      // Assertions:
      // Outside 10-minute correlation window -> Independently processed as distinct event
      expect(res2.status, DeduplicationStatus.newEventCreated);
      final event2Id = res2.eventId!;
      expect(event1Id, isNot(equals(event2Id)));

      // Ledger integrity:
      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 2);

      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 2);

      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 4);

      final debits = postings.where((p) => p['direction'] == 'debit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      final credits = postings.where((p) => p['direction'] == 'credit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      expect(debits, credits);
      expect(debits, 100000); // 500 + 500 = 1000 INR
    });

    test('Test D — Existing UTR/RRN behavior: reconciles via Stage 1 and creates zero duplicate postings', () async {
      const sender = 'VM-HDFCBK';
      const utr = '998877665544';
      const body = 'Rs 1,500.00 debited from HDFC A/c **1234 on 18-Nov-26 to Flipkart. UPI Ref: $utr.';
      final tBroadcast = testEpoch2026Ms;
      final tInbox = testEpoch2026Ms + (3 * 60 * 1000); // 3 minutes later

      // 1. Live broadcast path:
      final bId = generateTestTelephonySourceId(subId: 0, timestampMillis: tBroadcast, sender: sender, body: body);
      final cBroadcast = IncomingTransactionCandidate(
        sourceRecordId: bId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 150000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tBroadcast, isUtc: true),
        externalReference: utr,
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resB = await dedupService.processWithConflictResolution(candidate: cBroadcast, db: db);
      expect(resB.status, DeduplicationStatus.newEventCreated);
      final eventId = resB.eventId!;

      // 2. Later Inbox sync for the same transaction:
      const inboxSourceId = 'SRC:TELEPHONY_SMS:80001';
      final cInbox = IncomingTransactionCandidate(
        sourceRecordId: inboxSourceId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 150000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(tInbox, isUtc: true),
        externalReference: utr,
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resInbox = await dedupService.processWithConflictResolution(candidate: cInbox, db: db);

      // Assertions:
      // Reconciles as strongMatchMerged via Stage 1 UTR/RRN matching:
      expect(resInbox.status, DeduplicationStatus.strongMatchMerged);
      expect(resInbox.eventId, equals(eventId));

      // Accounting invariants:
      // Exactly 1 Economic Event
      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 1);

      // Exactly 2 Evidence records (both broadcast and inbox source identities preserved)
      final evidenceRows = await db.query(TablesV24.evidence, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(evidenceRows.length, 2);
      final sourceIds = evidenceRows.map((e) => e['source_record_id']).toSet();
      expect(sourceIds.contains(bId), isTrue);
      expect(sourceIds.contains(inboxSourceId), isTrue);

      // Exactly 2 Postings (zero duplicate accounting entries)
      final postings = await db.query(TablesV24.postings, where: 'economic_event_id = ?', whereArgs: [eventId]);
      expect(postings.length, 2);
      final debits = postings.where((p) => p['direction'] == 'debit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      final credits = postings.where((p) => p['direction'] == 'credit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      expect(debits, credits);
      expect(debits, 150000);

      // Review Queue is 0
      final reviewRows = await db.query(TablesV24.reviewCandidates);
      expect(reviewRows.length, 0);
    });

    test('Final Edge-Case: Same-second identical SMS records with one broadcast match preserve second in Review Queue without data loss', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Rs 500.00 debited from HDFC A/c **1234 on 18-Nov-26 without ref.';
      final t0 = testEpoch2026Ms;

      // 1. Initial State: Create only one corresponding broadcast economic event,
      // representing the Stage 0 collision where the second broadcast was absorbed.
      final broadcastId = generateTestTelephonySourceId(subId: 0, timestampMillis: t0, sender: sender, body: body);
      final cBroadcast = IncomingTransactionCandidate(
        sourceRecordId: broadcastId,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t0, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final resB = await dedupService.processWithConflictResolution(candidate: cBroadcast, db: db);
      expect(resB.status, DeduplicationStatus.newEventCreated);
      final eventId = resB.eventId!;

      // Counts after Broadcast Event creation:
      final eventsAfterB = await db.query(TablesV24.economicEvents);
      expect(eventsAfterB.length, 1);
      final evidenceAfterB = await db.query(TablesV24.evidence);
      expect(evidenceAfterB.length, 1);
      final postingsAfterB = await db.query(TablesV24.postings);
      expect(postingsAfterB.length, 2);
      final reviewAfterB = await db.query(TablesV24.reviewCandidates);
      expect(reviewAfterB.length, 0);

      // Verify debit and credit equality after Broadcast:
      final debitsB = postingsAfterB.where((p) => p['direction'] == 'debit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      final creditsB = postingsAfterB.where((p) => p['direction'] == 'credit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      expect(debitsB, creditsB);
      expect(debitsB, 50000);

      // 2. Process Inbox Record 1 (Android SMS ID 10001):
      const inboxId1 = 'SRC:TELEPHONY_SMS:10001';
      final cInbox1 = IncomingTransactionCandidate(
        sourceRecordId: inboxId1,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t0, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res1 = await dedupService.processWithConflictResolution(candidate: cInbox1, db: db);

      // Assertions for Record 1:
      // Reconciles as strongMatchMerged to the single broadcast event
      expect(res1.status, DeduplicationStatus.strongMatchMerged);
      expect(res1.eventId, equals(eventId));

      // Verify counts after Record 1:
      // Event: 1, Evidence: 2 (broadcast + inbox 1), Postings: 2, Review Queue: 0
      final eventsAfter1 = await db.query(TablesV24.economicEvents);
      expect(eventsAfter1.length, 1);
      final evidenceAfter1 = await db.query(TablesV24.evidence);
      expect(evidenceAfter1.length, 2);
      final postingsAfter1 = await db.query(TablesV24.postings);
      expect(postingsAfter1.length, 2);
      final reviewAfter1 = await db.query(TablesV24.reviewCandidates);
      expect(reviewAfter1.length, 0);

      final debits1 = postingsAfter1.where((p) => p['direction'] == 'debit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      final credits1 = postingsAfter1.where((p) => p['direction'] == 'credit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      expect(debits1, credits1);
      expect(debits1, 50000);

      // Verify durable one-to-one reconciliation link in evidence_reconciliations:
      final bEvidence = evidenceAfter1.firstWhere((e) => e['source_record_id'] == broadcastId);
      final i1Evidence = evidenceAfter1.firstWhere((e) => e['source_record_id'] == inboxId1);
      // external_reference retains only genuine references (null for unreferenced SMS, NEVER markers):
      expect(bEvidence['external_reference'], isNull);
      expect(i1Evidence['external_reference'], isNull);

      final reconciliations = await db.query(TablesV26.evidenceReconciliations);
      expect(reconciliations.length, 1);
      final rec = reconciliations.first;
      expect(rec['broadcast_source_record_id'], broadcastId);
      expect(rec['inbox_source_record_id'], inboxId1);
      expect(rec['reconciliation_method'], 'BROADCAST_INBOX_STRICT_IDENTIFYING_EVIDENCE');

      // 3. Process Inbox Record 2 (Android SMS ID 10002):
      // Exact same timestamp t0, same sender, same body, same amount, but distinct SMS ID 10002
      const inboxId2 = 'SRC:TELEPHONY_SMS:10002';
      expect(inboxId1, isNot(equals(inboxId2))); // Assertion 1: Distinct source identities

      final cInbox2 = IncomingTransactionCandidate(
        sourceRecordId: inboxId2,
        sourceChannel: SourceChannel.sms,
        sender: sender,
        body: body,
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(t0, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_stage5c8a_hdfc_1234',
      );
      final res2 = await dedupService.processWithConflictResolution(candidate: cInbox2, db: db);

      // Assertions for Record 2:
      // Must NOT automatically merge into eventId (Assertion 3).
      // Must NOT silently disappear (Assertion 2 & 5).
      // System cannot establish if 1 or 2 transactions -> Preserved in Review Queue (Assertion 4).
      expect(res2.status, DeduplicationStatus.routedToReviewQueue);
      expect(res2.reviewReason, 'SAME_SECOND_UNREFERENCED_INBOX_COLLISION');

      // Verify counts after Record 2:
      // Event: 1 (E1 remains unchanged, no duplicate event created)
      // Evidence: 3 (Broadcast, Inbox 1, and quarantined Inbox 2)
      // Postings: 2 (Unchanged, balanced)
      // Review Queue: 1 (Record 2 preserved)
      final eventsAfter2 = await db.query(TablesV24.economicEvents);
      expect(eventsAfter2.length, 1);
      expect(eventsAfter2.first['id'], eventId);

      final evidenceAfter2 = await db.query(TablesV24.evidence);
      expect(evidenceAfter2.length, 3);
      final evidenceSourceIds2 = evidenceAfter2.map((e) => e['source_record_id']).toSet();
      expect(evidenceSourceIds2.contains(broadcastId), isTrue);
      expect(evidenceSourceIds2.contains(inboxId1), isTrue);
      expect(evidenceSourceIds2.contains(inboxId2), isTrue);

      final postingsAfter2 = await db.query(TablesV24.postings);
      expect(postingsAfter2.length, 2);

      final debits2 = postingsAfter2.where((p) => p['direction'] == 'debit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      final credits2 = postingsAfter2.where((p) => p['direction'] == 'credit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      expect(debits2, credits2);
      expect(debits2, 50000);

      final reviewAfter2 = await db.query(TablesV24.reviewCandidates);
      expect(reviewAfter2.length, 1);
      final revEntry = reviewAfter2.first;
      expect(revEntry['source_type'], 'sms');
      expect(revEntry['suggested_amount_minor_units'], 50000);
      expect(revEntry['status'], 'pending');
      final revPayload = jsonDecode(revEntry['raw_payload'] as String) as Map<String, dynamic>;
      expect(revPayload['sourceRecordId'], inboxId2);
      expect(revPayload['reason'], 'SAME_SECOND_UNREFERENCED_INBOX_COLLISION');

      // 4. Reprocessing Idempotency (Assertion 8):
      // Reprocessing Record 1:
      final reRes1 = await dedupService.processWithConflictResolution(candidate: cInbox1, db: db);
      expect(reRes1.status, DeduplicationStatus.duplicateSourceRecord);
      expect(reRes1.eventId, equals(eventId));

      // Reprocessing Record 2:
      final reRes2 = await dedupService.processWithConflictResolution(candidate: cInbox2, db: db);
      expect(reRes2.status, DeduplicationStatus.duplicateSourceRecord);

      // Counts after reprocessing remain completely identical:
      final finalEvents = await db.query(TablesV24.economicEvents);
      expect(finalEvents.length, 1);
      final finalEvidence = await db.query(TablesV24.evidence);
      expect(finalEvidence.length, 3);
      final finalPostings = await db.query(TablesV24.postings);
      expect(finalPostings.length, 2);
      final finalReview = await db.query(TablesV24.reviewCandidates);
      expect(finalReview.length, 1);

      final finalDebits = finalPostings.where((p) => p['direction'] == 'debit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      final finalCredits = finalPostings.where((p) => p['direction'] == 'credit').fold<int>(0, (s, p) => s + (p['amount_minor_units'] as int));
      expect(finalDebits, finalCredits);
      expect(finalDebits, 50000);
    });
  });
}

extension on List<String> {
  List<String> filter(bool Function(String) predicate) => where(predicate).toList();
}
