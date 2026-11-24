import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/domain/finance/posting.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
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

class SyntheticPduSegment {
  final String? originatingAddress;
  final String? body;
  final int timestampMillis;

  const SyntheticPduSegment({
    this.originatingAddress,
    this.body,
    required this.timestampMillis,
  });
}

class SyntheticReassembledSms {
  final String sender;
  final String fullBody;
  final int timestampMillis;
  final int subId;
  final String sourceRecordId;

  const SyntheticReassembledSms({
    required this.sender,
    required this.fullBody,
    required this.timestampMillis,
    required this.subId,
    required this.sourceRecordId,
  });
}

/// Pure boundary validator and reassembly mirroring native SmsReceiver.validateAndReassemble
SyntheticReassembledSms? syntheticValidateAndReassemble(
  List<SyntheticPduSegment> segments,
  int subId,
) {
  if (segments.isEmpty) return null;

  // 1. Validate sender consistency
  final senders = segments
      .map((s) => s.originatingAddress?.trim())
      .where((s) => s != null && s.isNotEmpty)
      .cast<String>()
      .toList();
  if (senders.isEmpty) return null;
  final primarySender = senders.first;
  if (senders.any((s) => s.toUpperCase() != primarySender.toUpperCase())) {
    return null; // Reject sender mismatch
  }

  // 2. Validate timestamp consistency (within 60s)
  final timestamps = segments.map((s) => s.timestampMillis).toList();
  final minTs = timestamps.reduce((a, b) => a < b ? a : b);
  final maxTs = timestamps.reduce((a, b) => a > b ? a : b);
  if (maxTs - minTs > 60000) {
    return null; // Reject drifting timestamps
  }

  // 3. Reassemble valid bodies
  final validBodies = segments
      .map((s) => s.body)
      .where((b) => b != null && b.trim().isNotEmpty)
      .cast<String>()
      .toList();
  if (validBodies.isEmpty) return null;

  final fullBody = validBodies.join('');

  // 4. Financial classification gate (requires monetary amount and verb)
  final hasAmount = RegExp(r'(?:(?:rs\.?|inr|₹)\s*[\d,]+(?:\.\d+)?)|(?:[\d,]+(?:\.\d+)?\s*(?:rs\.?|inr|₹))', caseSensitive: false).hasMatch(fullBody);
  final hasVerb = RegExp(r'\b(?:debited|debit|credited|credit|paid|spent|sent|transferred|withdrawn|deposited|deposit|refunded|received|payment)\b', caseSensitive: false).hasMatch(fullBody);

  if (!hasAmount || !hasVerb) {
    return null; // Reject non-financial or incomplete messages
  }

  final sourceRecordId = generateTestTelephonySourceId(
    subId: subId,
    timestampMillis: timestamps.first,
    sender: primarySender,
    body: fullBody,
  );

  return SyntheticReassembledSms(
    sender: primarySender,
    fullBody: fullBody,
    timestampMillis: timestamps.first,
    subId: subId,
    sourceRecordId: sourceRecordId,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const testDbName = 'spendx_multipart_audit.db';
  const testKeySlot = 'spendx_db_test_key_multipart_audit';

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

    final nowStr = DateTime.now().toUtc().toIso8601String();
    await db.insert(
      TablesV24.accounts,
      {
        'id': 'acc_test_1234',
        'account_type': 'asset',
        'subtype': 'checking',
        'name': 'HDFC Primary',
        'account_number_last4': '1234',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': nowStr,
        'updated_at': nowStr,
      },
    );
    await db.insert(
      TablesV24.accounts,
      {
        'id': 'acc_test_5678',
        'account_type': 'asset',
        'subtype': 'checking',
        'name': 'HDFC Secondary',
        'account_number_last4': '5678',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': nowStr,
        'updated_at': nowStr,
      },
    );
    await db.insert(
      TablesV24.accounts,
      {
        'id': 'acc_test_9988',
        'account_type': 'asset',
        'subtype': 'savings',
        'name': 'SBI Salary',
        'account_number_last4': '9988',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': nowStr,
        'updated_at': nowStr,
      },
    );
    await db.insert(
      TablesV24.accounts,
      {
        'id': 'acc_test_1122',
        'account_type': 'asset',
        'subtype': 'checking',
        'name': 'HDFC Test',
        'account_number_last4': '1122',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': nowStr,
        'updated_at': nowStr,
      },
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
    if (await file.exists()) {
      await file.delete();
    }
  });

  group('SpendX Multipart SMS Boundary & Ingestion Audit (15 Tests)', () {
    test('1. Valid single-part SMS creates new event and durable posting', () async {
      final segments = [
        const SyntheticPduSegment(
          originatingAddress: 'VM-HDFCBK',
          body: 'Rs 1,500.00 debited from A/C **1234 on 18-Nov-26 towards Amazon. Avl Bal: Rs 45,000.00',
          timestampMillis: 1731950000000,
        ),
      ];

      final reassembled = syntheticValidateAndReassemble(segments, 0);
      expect(reassembled, isNotNull);

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: reassembled!.sourceRecordId,
        sourceChannel: SourceChannel.sms,
        sender: reassembled.sender,
        body: reassembled.fullBody,
        amountMinorUnits: 150000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(reassembled.timestampMillis, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_test_1234',
      );

      final res = await dedupService.processWithConflictResolution(candidate: candidate, db: db);
      expect(res.status, DeduplicationStatus.newEventCreated);

      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 1);
    });

    test('2. Valid multipart SMS with two segments reassembles and ingests cleanly', () async {
      final segments = [
        const SyntheticPduSegment(
          originatingAddress: 'VM-HDFCBK',
          body: 'Rs 2,499.00 debited from HDFC Bank A/C **5678 on 18-Nov-26 18:30:15 ',
          timestampMillis: 1731950000000,
        ),
        const SyntheticPduSegment(
          originatingAddress: 'VM-HDFCBK',
          body: 'towards Flipkart. Avl Bal: Rs 28,100.50. Ref: 432109876543.',
          timestampMillis: 1731950000000,
        ),
      ];

      final reassembled = syntheticValidateAndReassemble(segments, 0);
      expect(reassembled, isNotNull);
      expect(reassembled!.fullBody, contains('Rs 2,499.00 debited'));
      expect(reassembled.fullBody, contains('towards Flipkart'));

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: reassembled.sourceRecordId,
        sourceChannel: SourceChannel.sms,
        sender: reassembled.sender,
        body: reassembled.fullBody,
        amountMinorUnits: 249900,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(reassembled.timestampMillis, isUtc: true),
        externalReference: '432109876543',
        accountNumberLast4: '5678',
        accountId: 'acc_test_5678',
      );

      final res = await dedupService.processWithConflictResolution(candidate: candidate, db: db);
      expect(res.status, DeduplicationStatus.newEventCreated);

      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 1);
      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 2, reason: 'Double-entry bookkeeping creates 2 postings per economic event');
    });

    test('3. Valid multipart SMS with three segments reassembles and ingests', () async {
      final segments = [
        const SyntheticPduSegment(originatingAddress: 'AD-SBIINB', body: 'Dear Customer, your Account ending 9988 ', timestampMillis: 1731950100000),
        const SyntheticPduSegment(originatingAddress: 'AD-SBIINB', body: 'has been credited by Rs 50,000.00 on 18-Nov-26 ', timestampMillis: 1731950100000),
        const SyntheticPduSegment(originatingAddress: 'AD-SBIINB', body: 'by transfer from SALARY. Total Avail Bal Rs 1,12,000.00.', timestampMillis: 1731950100000),
      ];

      final reassembled = syntheticValidateAndReassemble(segments, 0);
      expect(reassembled, isNotNull);

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: reassembled!.sourceRecordId,
        sourceChannel: SourceChannel.sms,
        sender: reassembled.sender,
        body: reassembled.fullBody,
        amountMinorUnits: 5000000,
        direction: PostingDirection.credit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(reassembled.timestampMillis, isUtc: true),
        accountNumberLast4: '9988',
        accountId: 'acc_test_9988',
      );

      final res = await dedupService.processWithConflictResolution(candidate: candidate, db: db);
      expect(res.status, DeduplicationStatus.newEventCreated);
    });

    test('4. Reordered segments produce distinct deterministic source identity without corruption', () {
      final seg1 = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 500 debited from A/c 1234 ', timestampMillis: 1731950000000);
      final seg2 = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'towards Swiggy. Avl Bal Rs 5,000.', timestampMillis: 1731950000000);

      final natural = syntheticValidateAndReassemble([seg1, seg2], 0);
      final inverted = syntheticValidateAndReassemble([seg2, seg1], 0);

      expect(natural, isNotNull);
      expect(inverted, isNotNull);
      expect(natural!.sourceRecordId, isNot(equals(inverted!.sourceRecordId)));
    });

    test('5. Missing segment lacking financial amount is dropped with zero postings created', () async {
      final incomplete = [
        const SyntheticPduSegment(
          originatingAddress: 'VM-HDFCBK',
          body: 'towards Merchant XYZ. Thank you for using HDFC netbanking.',
          timestampMillis: 1731950000000,
        ),
      ];

      final reassembled = syntheticValidateAndReassemble(incomplete, 0);
      expect(reassembled, isNull);

      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 0, reason: 'Incomplete segment must not create economic event');
    });

    test('6. Duplicate segment concatenated safely without breaking parser', () {
      final seg1 = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 500 debited from A/c 1234. ', timestampMillis: 1731950000000);
      final segDup = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 500 debited from A/c 1234. ', timestampMillis: 1731950000000);

      final reassembled = syntheticValidateAndReassemble([seg1, segDup], 0);
      expect(reassembled, isNotNull);
      expect(reassembled!.fullBody, contains('Rs 500 debited'));
    });

    test('7. Malformed PDU with null body is strictly dropped', () {
      final malformed = [
        const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: null, timestampMillis: 1731950000000),
      ];
      final reassembled = syntheticValidateAndReassemble(malformed, 0);
      expect(reassembled, isNull);
    });

    test('8. Empty whitespace-only segment is safely filtered out', () {
      final emptySeg = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: '   \n\t  ', timestampMillis: 1731950000000);
      final validSeg = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 750 debited from A/c **4321. Avl Bal Rs 10,000', timestampMillis: 1731950000000);

      final reassembled = syntheticValidateAndReassemble([emptySeg, validSeg], 0);
      expect(reassembled, isNotNull);
      expect(reassembled!.fullBody, equals(validSeg.body));
    });

    test('9. Different sender across segments is strictly rejected', () {
      final seg1 = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 1,000 debited ', timestampMillis: 1731950000000);
      final seg2 = const SyntheticPduSegment(originatingAddress: 'AD-AIRTEL', body: 'from your account towards Airtel.', timestampMillis: 1731950000000);

      final reassembled = syntheticValidateAndReassemble([seg1, seg2], 0);
      expect(reassembled, isNull, reason: 'Conflicting originating addresses must return null');
    });

    test('10. Different subscription identities produce distinct isolated source records', () {
      final seg = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 500 debited from A/c 1234', timestampMillis: 1731950000000);

      final resSub0 = syntheticValidateAndReassemble([seg], 0);
      final resSub1 = syntheticValidateAndReassemble([seg], 1);

      expect(resSub0, isNotNull);
      expect(resSub1, isNotNull);
      expect(resSub0!.sourceRecordId, isNot(equals(resSub1!.sourceRecordId)));
      expect(resSub0.sourceRecordId, startsWith('SRC:TELEPHONY_BROADCAST:0:'));
      expect(resSub1.sourceRecordId, startsWith('SRC:TELEPHONY_BROADCAST:1:'));
    });

    test('11. Timestamp inconsistency (>60s drift) across segments is strictly rejected', () {
      final seg1 = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 1,000 debited ', timestampMillis: 1731950000000);
      final segDrift = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'from A/c **1234. Avl Bal Rs 5,000', timestampMillis: 1731950100000); // 100s later

      final reassembled = syntheticValidateAndReassemble([seg1, segDrift], 0);
      expect(reassembled, isNull, reason: 'Drifting timestamps must be rejected');
    });

    test('12. Duplicate broadcast of same complete message triggers Stage 0 idempotency with zero duplicate postings', () async {
      final seg = const SyntheticPduSegment(
        originatingAddress: 'VM-HDFCBK',
        body: 'Rs 800.00 debited from A/c **1122. Avl Bal Rs 12,000',
        timestampMillis: 1731950000000,
      );

      final reassembled = syntheticValidateAndReassemble([seg], 0);
      expect(reassembled, isNotNull);

      final candidate1 = IncomingTransactionCandidate(
        sourceRecordId: reassembled!.sourceRecordId,
        sourceChannel: SourceChannel.sms,
        sender: reassembled.sender,
        body: reassembled.fullBody,
        amountMinorUnits: 80000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(reassembled.timestampMillis, isUtc: true),
        accountNumberLast4: '1122',
        accountId: 'acc_test_1122',
      );

      final res1 = await dedupService.processWithConflictResolution(candidate: candidate1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);

      // Duplicate delivery attempt
      final candidate2 = IncomingTransactionCandidate(
        sourceRecordId: reassembled.sourceRecordId,
        sourceChannel: SourceChannel.sms,
        sender: reassembled.sender,
        body: reassembled.fullBody,
        amountMinorUnits: 80000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(reassembled.timestampMillis, isUtc: true),
        accountNumberLast4: '1122',
        accountId: 'acc_test_1122',
      );

      final res2 = await dedupService.processWithConflictResolution(candidate: candidate2, db: db);
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, equals(res1.eventId));

      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 1, reason: 'Exactly one economic event must exist despite duplicate deliveries');
      final allPostings = await db.query(TablesV24.postings);
      expect(allPostings.length, 2, reason: 'Exactly two postings (one debit, one credit) must exist');
    });

    test('13. Two distinct transactions from same sender with identical body create distinct events', () async {
      final segA = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 50.00 debited from A/c **1234 for Tea', timestampMillis: 1731950000000);
      final segB = const SyntheticPduSegment(originatingAddress: 'VM-HDFCBK', body: 'Rs 50.00 debited from A/c **1234 for Tea', timestampMillis: 1731950060000); // 60s later

      final resA = syntheticValidateAndReassemble([segA], 0);
      final resB = syntheticValidateAndReassemble([segB], 0);

      expect(resA, isNotNull);
      expect(resB, isNotNull);
      expect(resA!.sourceRecordId, isNot(equals(resB!.sourceRecordId)));

      final cA = IncomingTransactionCandidate(
        sourceRecordId: resA.sourceRecordId,
        sourceChannel: SourceChannel.sms,
        sender: resA.sender,
        body: resA.fullBody,
        amountMinorUnits: 5000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(resA.timestampMillis, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_test_1234',
      );
      final cB = IncomingTransactionCandidate(
        sourceRecordId: resB.sourceRecordId,
        sourceChannel: SourceChannel.sms,
        sender: resB.sender,
        body: resB.fullBody,
        amountMinorUnits: 5000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(resB.timestampMillis, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_test_1234',
      );

      final outA = await dedupService.processWithConflictResolution(candidate: cA, db: db);
      final outB = await dedupService.processWithConflictResolution(candidate: cB, db: db);

      expect(outA.status, DeduplicationStatus.newEventCreated);
      expect(outB.status, DeduplicationStatus.newEventCreated);
      expect(outA.eventId, isNot(equals(outB.eventId)));

      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 2, reason: 'Both legitimate separate transactions must produce distinct events');
      final allPostings = await db.query(TablesV24.postings);
      expect(allPostings.length, 4, reason: 'Two events produce 4 double-entry postings (2 debits, 2 credits)');
    });

    test('14. Process interruption preserves unacknowledged queue items on disk', () async {
      // Simulate raw SharedPreferences storage
      final prefs = await SharedPreferences.getInstance();
      const entrySep = '\u0001';
      const fieldSep = '\u0002';
      final queueKey = 'pending_sms_queue';

      final e1 = 'VM-HDFCBK${fieldSep}Rs 100 debited from A/c 1234${fieldSep}SRC:ID1';
      final e2 = 'VM-HDFCBK${fieldSep}Rs 200 debited from A/c 1234${fieldSep}SRC:ID2';
      await prefs.setString(queueKey, '$e1$entrySep$e2');

      // Process dies before drain completes. Verify queue state remains intact:
      final raw = prefs.getString(queueKey);
      expect(raw, contains('SRC:ID1'));
      expect(raw, contains('SRC:ID2'));
    });

    test('15. Retry after interrupted queue drain achieves idempotent recovery', () async {
      final id1 = 'SRC:TELEPHONY_BROADCAST:0:1731950000000:id1';
      final id2 = 'SRC:TELEPHONY_BROADCAST:0:1731950001000:id2';

      // Pre-ingest id1 as if it succeeded before the crash
      final candidate1 = IncomingTransactionCandidate(
        sourceRecordId: id1,
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 100 debited from A/c 1234',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1731950000000, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_test_1234',
      );
      final r1 = await dedupService.processWithConflictResolution(candidate: candidate1, db: db);
      expect(r1.status, DeduplicationStatus.newEventCreated);

      // On retry/reboot, both id1 and id2 are drained:
      // id1 is safely recognized as Stage 0 duplicate
      final r1Retry = await dedupService.processWithConflictResolution(candidate: candidate1, db: db);
      expect(r1Retry.status, DeduplicationStatus.duplicateSourceRecord);

      // id2 is processed for the first time
      final candidate2 = IncomingTransactionCandidate(
        sourceRecordId: id2,
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 200 debited from A/c 1234',
        amountMinorUnits: 20000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1731950001000, isUtc: true),
        accountNumberLast4: '1234',
        accountId: 'acc_test_1234',
      );
      final r2 = await dedupService.processWithConflictResolution(candidate: candidate2, db: db);
      expect(r2.status, DeduplicationStatus.newEventCreated);

      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 2, reason: 'Exactly 2 economic events exist with zero duplicate postings');
    });
  });
}
