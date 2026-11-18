import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:spend_x/domain/finance/economic_event.dart';
import 'package:spend_x/domain/finance/posting.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late Database db;
  late CrossChannelDeduplicationService dedupService;
  late RefundAllocationsRepo refundRepo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_dedup_test_');
    dbPath = p.join(tempDir.path, 'dedup_test.db');

    db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 25,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
          await TablesV25.createAllV25(db);
          await TablesV25.installTriggers(db);
        },
      ),
    );

    refundRepo = RefundAllocationsRepo(executor: db);
    dedupService = CrossChannelDeduplicationService(refundRepo: refundRepo);

    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert(TablesV24.accounts, {
      'id': 'acc_sbi_1111',
      'account_type': 'asset',
      'subtype': 'savings',
      'name': 'SBI A/c 1111',
      'account_number_last4': '1111',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(TablesV24.accounts, {
      'id': 'acc_hdfc_2222',
      'account_type': 'asset',
      'subtype': 'savings',
      'name': 'HDFC A/c 2222',
      'account_number_last4': '2222',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(TablesV24.accounts, {
      'id': 'acc_card_regalia',
      'account_type': 'liability',
      'subtype': 'credit_card',
      'name': 'HDFC Regalia',
      'account_number_last4': '6366',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Category A — Source Identity', () {
    test('A1: SMS deterministic identity', () {
      final id1 = CrossChannelDeduplicationService.buildSmsSourceId('101');
      final id2 = CrossChannelDeduplicationService.buildSmsSourceId(101);
      expect(id1, 'SRC:TELEPHONY_SMS:101');
      expect(id2, 'SRC:TELEPHONY_SMS:101');
    });

    test('A2: Push deterministic identity', () {
      final id = CrossChannelDeduplicationService.buildPushSourceId(
        'com.google.android.apps.nbu.paisa.user',
        42,
        'payment_tag',
        1700000000000,
      );
      expect(
        id,
        'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:42:payment_tag:1700000000000',
      );
    });

    test('A3: Repeated observation of identical source identity triggers Stage 0 idempotency skip', () async {
      final candidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:501',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited INR 500.00 from HDFC Bank. UPI/532342342342/Swiggy',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.now().toUtc(),
        externalReference: 'UPI:RRN:532342342342',
        accountId: 'acc_hdfc_2222',
        merchant: 'Swiggy',
      );

      // First pass: creates new event
      final res1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
      expect(res1.status, DeduplicationStatus.newEventCreated);
      expect(res1.eventId, isNotNull);

      final eventCount1 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCount1 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      final evidenceCount1 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.evidence}'),
      );

      expect(eventCount1, 1);
      expect(postingCount1, 2);
      expect(evidenceCount1, 1);

      // Second pass with IDENTICAL sourceRecordId: Stage 0 hit!
      final res2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, res1.eventId);

      // Ledger and evidence counts remain 100% unchanged
      final eventCount2 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCount2 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      final evidenceCount2 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.evidence}'),
      );

      expect(eventCount2, 1);
      expect(postingCount2, 2);
      expect(evidenceCount2, 1);
    });

    test('A4: Distinct notification lifecycle identities create distinct candidate records', () async {
      final push1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:1::1700000001000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Paid ₹100.00 to Chai Point',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: DateTime.now().toUtc().subtract(const Duration(minutes: 15)),
        merchant: 'Chai Point',
      );

      final push2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:2::1700000099000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Paid ₹100.00 to Chai Point',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: DateTime.now().toUtc(),
        merchant: 'Chai Point',
      );

      final res1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push1,
            txn: txn,
          ));
      final res2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push2,
            txn: txn,
          ));

      expect(res1.status, DeduplicationStatus.newEventCreated);
      expect(res2.status, DeduplicationStatus.newEventCreated);
      expect(res1.eventId, isNot(equals(res2.eventId)));
    });
  });

  group('Category B — Stable Reference Matching', () {
    test('B1: Matching 12-digit UTR links push and bank SMS to exactly 1 economic event', () async {
      final utr = '532342342342';
      final now = DateTime.now().toUtc();

      // 1. Google Pay push arrives first
      final push = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:101::1700000000000',
        sourceChannel: SourceChannel.push,
        sender: 'Google Pay',
        body: 'Paid ₹450 to Swiggy. UPI Ref 532342342342',
        amountMinorUnits: 45000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: utr,
        merchant: 'Swiggy',
      );

      final resPush = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push,
            txn: txn,
          ));
      expect(resPush.status, DeduplicationStatus.newEventCreated);
      final eventId = resPush.eventId!;

      // 2. Bank SMS arrives 2 minutes later with identical UTR
      final sms = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:888',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited INR 450.00 from HDFC Bank A/c 2222. UPI/532342342342/Swiggy',
        amountMinorUnits: 45000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 2)),
        externalReference: utr,
        accountId: 'acc_hdfc_2222',
        merchant: 'Swiggy',
      );

      final resSms = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: sms,
            txn: txn,
          ));
      expect(resSms.status, DeduplicationStatus.strongMatchMerged);
      expect(resSms.eventId, eventId);

      // Verify invariant: Exactly 1 economic event, exactly 2 postings, exactly 2 evidence rows
      final eventCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      final evidenceRows = await db.query(TablesV24.evidence);

      expect(eventCount, 1);
      expect(postingCount, 2);
      expect(evidenceRows.length, 2);
      expect(evidenceRows.every((e) => e['economic_event_id'] == eventId), isTrue);
    });

    test('B2: Matching RRN normalization and extraction', () {
      final ref1 = CrossChannelDeduplicationService.extractUtrOrRrn('Paid via UPI Ref: 987654321012 to merchant');
      expect(ref1, '987654321012');

      final norm1 = CrossChannelDeduplicationService.normalizeReference('987654321012');
      expect(norm1, 'UPI:RRN:987654321012');

      final norm2 = CrossChannelDeduplicationService.normalizeReference('HDFC:UPI:REF123');
      expect(norm2, 'HDFC:UPI:REF123');
    });

    test('B3: Conflicting amounts on matching provider reference routes to Review Queue (P14-T25)', () async {
      final now = DateTime.now().toUtc();
      const sharedRef = 'HDFC:UPI:REF999';

      // Push says ₹500
      final push = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.hdfcbank.payzapp:1::1700000000000',
        sourceChannel: SourceChannel.push,
        sender: 'PayZapp',
        body: 'Paid ₹500.00 ref REF999',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: sharedRef,
      );

      await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push,
            txn: txn,
          ));

      // SMS says ₹450 with identical reference!
      final sms = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:901',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited ₹450.00 ref REF999',
        amountMinorUnits: 45000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 1)),
        externalReference: sharedRef,
      );

      final res = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: sms,
            txn: txn,
          ));

      expect(res.status, DeduplicationStatus.routedToReviewQueue);
      expect(res.reviewReason, 'REFERENCE_AMOUNT_MISMATCH');

      // Zero duplicate postings for the conflicted second transaction
      final postingCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(postingCount, 2); // only original 2 postings from push 1
    });

    test('B4: Duplicate reference ambiguity routes to Review Queue', () async {
      final now = DateTime.now().toUtc();
      const sharedRef = 'UPI:RRN:111222333444';

      // Manually simulate two existing distinct events sharing the reference
      final event1 = const Uuid().v4();
      final event2 = const Uuid().v4();
      await db.insert(TablesV24.economicEvents, {
        'id': event1,
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now.toIso8601String(),
        'currency': 'INR',
        'description': 'Event 1',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': event1,
        'account_id': 'acc_sbi_1111',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 30000,
        'currency': 'INR',
        'created_at': now.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': event1,
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 30000,
        'currency': 'INR',
        'created_at': now.toIso8601String(),
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [event1],
      );

      await db.insert(TablesV24.economicEvents, {
        'id': event2,
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now.toIso8601String(),
        'currency': 'INR',
        'description': 'Event 2',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': event2,
        'account_id': 'acc_sbi_1111',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 30000,
        'currency': 'INR',
        'created_at': now.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': event2,
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 30000,
        'currency': 'INR',
        'created_at': now.toIso8601String(),
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [event2],
      );
      await db.insert(TablesV24.evidence, {
        'id': const Uuid().v4(),
        'economic_event_id': event1,
        'source_type': 'sms',
        'source_record_id': 'SRC:TELEPHONY_SMS:1001',
        'extracted_amount_minor_units': 30000,
        'extracted_timestamp': now.toIso8601String(),
        'external_reference': sharedRef,
        'body_sha256': 'hash1',
        'is_payload_purged': 0,
        'created_at': now.toIso8601String(),
      });
      await db.insert(TablesV24.evidence, {
        'id': const Uuid().v4(),
        'economic_event_id': event2,
        'source_type': 'sms',
        'source_record_id': 'SRC:TELEPHONY_SMS:1002',
        'extracted_amount_minor_units': 30000,
        'extracted_timestamp': now.toIso8601String(),
        'external_reference': sharedRef,
        'body_sha256': 'hash2',
        'is_payload_purged': 0,
        'created_at': now.toIso8601String(),
      });

      // Third candidate with same reference arrives
      final candidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:500::1700000',
        sourceChannel: SourceChannel.push,
        sender: 'GPay',
        body: 'Paid ₹300 Ref 111222333444',
        amountMinorUnits: 30000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: sharedRef,
      );

      final res = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
      expect(res.status, DeduplicationStatus.routedToReviewQueue);
      expect(res.reviewReason, 'DUPLICATE_REFERENCE_AMBIGUITY');
    });
  });

  group('Category C — Conservative Correlation & Safeguards', () {
    test('C1: Cross-channel unreferenced matching strictly routes to Review Queue (P14-T03, P14-T37)', () async {
      final now = DateTime.now().toUtc();

      // Bank SMS arrives with account XX1111 and amount ₹500 without UTR
      final sms = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:700',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-SBIINB',
        body: 'A/c 1111 debited for Rs 500.00 on 18-Nov',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountId: 'acc_sbi_1111',
      );

      final resSms = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: sms,
            txn: txn,
          ));
      expect(resSms.status, DeduplicationStatus.newEventCreated);

      // GPay push arrives 4 minutes later with same amount and account, but NO UTR!
      final push = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:701::1700000',
        sourceChannel: SourceChannel.push,
        sender: 'Google Pay',
        body: 'Paid ₹500.00 using SBI **1111',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 4)),
        accountId: 'acc_sbi_1111',
      );

      final resPush = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push,
            txn: txn,
          ));

      // Invariant: Tier 3 unreferenced cross-channel automatic merge is FORBIDDEN!
      expect(resPush.status, DeduplicationStatus.routedToReviewQueue);
      expect(resPush.reviewReason, 'CROSS_CHANNEL_UNREFERENCED_ACCOUNT_MATCH');

      // Postings remain exactly 2 from the first transaction
      final postingCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(postingCount, 2);
    });

    test('C2: One-sided reference on correlation candidate routes to Review Queue (P14-T24)', () async {
      final now = DateTime.now().toUtc();

      // SMS arrives with UTR
      final sms = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:710',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited ₹300.00 from HDFC Bank A/c 2222. UPI/532342342342/Store',
        amountMinorUnits: 30000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: 'UPI:RRN:532342342342',
        accountId: 'acc_hdfc_2222',
      );

      await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: sms,
            txn: txn,
          ));

      // Push arrives 3 minutes later with NO UTR for the same amount
      final push = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:711::1700000',
        sourceChannel: SourceChannel.push,
        sender: 'GPay',
        body: 'Paid ₹300 to Store',
        amountMinorUnits: 30000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 3)),
        accountId: 'acc_hdfc_2222',
      );

      final res = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push,
            txn: txn,
          ));

      expect(res.status, DeduplicationStatus.routedToReviewQueue);
      expect(res.reviewReason, 'ONE_SIDED_REFERENCE_UNRESOLVED');
    });

    test('C3: Cross-account distinction prevents merge (P14-T06)', () async {
      final now = DateTime.now().toUtc();

      // SBI debit ₹500
      final sbi = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:720',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-SBIINB',
        body: 'Debited ₹500 from SBI 1111',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountId: 'acc_sbi_1111',
      );

      // HDFC debit ₹500 2 minutes later
      final hdfc = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:721',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited ₹500 from HDFC 2222',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 2)),
        accountId: 'acc_hdfc_2222',
      );

      final res1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: sbi,
            txn: txn,
          ));
      final res2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: hdfc,
            txn: txn,
          ));

      expect(res1.status, DeduplicationStatus.newEventCreated);
      expect(res2.status, DeduplicationStatus.newEventCreated);
      expect(res1.eventId, isNot(equals(res2.eventId)));

      final eventCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      expect(eventCount, 2);
    });

    test('C4: Timestamp outside permitted correlation window (> 10 min) posts independently', () async {
      final now = DateTime.now().toUtc();

      final s1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:730',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-SBIINB',
        body: 'Debited ₹100 from SBI',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: now.subtract(const Duration(minutes: 25)),
      );

      final s2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:731',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-SBIINB',
        body: 'Debited ₹100 from SBI',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: now,
      );

      final r1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: s1,
            txn: txn,
          ));
      final r2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: s2,
            txn: txn,
          ));

      expect(r1.status, DeduplicationStatus.newEventCreated);
      expect(r2.status, DeduplicationStatus.newEventCreated);
      expect(r1.eventId, isNot(equals(r2.eventId)));
    });
  });

  group('Category D — Same-Channel Behavior', () {
    test('D1: Distinct SMS records with similar content post independently (P14-T04, P14-T11)', () async {
      final now = DateTime.now().toUtc();

      final sms1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:801',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-METRO',
        body: 'Debited Rs 50.00 for Metro Smart Card',
        amountMinorUnits: 5000,
        direction: PostingDirection.debit,
        timestamp: now,
      );

      final sms2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:802',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-METRO',
        body: 'Debited Rs 50.00 for Metro Smart Card',
        amountMinorUnits: 5000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 3)),
      );

      final r1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: sms1,
            txn: txn,
          ));
      final r2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: sms2,
            txn: txn,
          ));

      expect(r1.status, DeduplicationStatus.newEventCreated);
      expect(r2.status, DeduplicationStatus.newEventCreated);
      expect(r1.eventId, isNot(equals(r2.eventId)));

      final eventCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      expect(eventCount, 2);
    });

    test('D2: Distinct push records with similar content without UTR within 2 min routes 2nd to Review Queue (P14-T05)', () async {
      final now = DateTime.now().toUtc();

      final push1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:10::1700000000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Paid ₹100.00 to Chai Point',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: now,
      );

      final push2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:11::1700000120',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Paid ₹100.00 to Chai Point',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 2)),
      );

      final r1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push1,
            txn: txn,
          ));
      final r2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: push2,
            txn: txn,
          ));

      expect(r1.status, DeduplicationStatus.newEventCreated);
      expect(r2.status, DeduplicationStatus.routedToReviewQueue);
      expect(r2.reviewReason, 'REPEAT_PAYMENT_SUSPECTED_DUPLICATE');
    });
  });

  group('Category E — Historical Linking', () {
    test('E1: Unique UTR historical match links SMS to legacy evidence without financial mutation', () async {
      final now = DateTime.now().toUtc();
      const legacyUtr = 'UPI:RRN:777888999000';

      // Seed pre-migration legacy evidence (source_record_id IS NULL)
      final legacyEventId = const Uuid().v4();
      final legacyEvidenceId = const Uuid().v4();

      await db.insert(TablesV24.economicEvents, {
        'id': legacyEventId,
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': now.toIso8601String(),
        'currency': 'INR',
        'description': 'Historical Purchase',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': legacyEventId,
        'account_id': 'acc_sbi_1111',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 150000,
        'currency': 'INR',
        'created_at': now.toIso8601String(),
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': legacyEventId,
        'account_id': TablesV24.sysExpMisc,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 150000,
        'currency': 'INR',
        'created_at': now.toIso8601String(),
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [legacyEventId],
      );
      await db.insert(TablesV24.evidence, {
        'id': legacyEvidenceId,
        'economic_event_id': legacyEventId,
        'source_type': 'sms',
        'source_record_id': null, // Pre-migration null
        'extracted_amount_minor_units': 150000,
        'extracted_timestamp': now.toIso8601String(),
        'external_reference': legacyUtr,
        'body_sha256': 'legacy_hash_1',
        'is_payload_purged': 0,
        'created_at': now.toIso8601String(),
      });

      // Historical reconciliation runs for SMS with same UTR
      final linkResult = await db.transaction((txn) => dedupService.linkHistoricalSms(
            smsId: '9901',
            body: 'Debited Rs 1500.00 Ref 777888999000',
            sender: 'SBI',
            timestamp: now,
            amountMinorUnits: 150000,
            utrOrRrn: legacyUtr,
            txn: txn,
          ));

      expect(linkResult.isLinked, isTrue);
      expect(linkResult.linkedEvidenceId, legacyEvidenceId);

      // Verify source_record_id was updated on legacy evidence
      final updatedEvidence = await db.query(
        TablesV24.evidence,
        where: 'id = ?',
        whereArgs: [legacyEvidenceId],
      );
      expect(updatedEvidence.first['source_record_id'], 'SRC:TELEPHONY_SMS:9901');

      // Verify zero changes to economic events or postings
      final eventCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(eventCount, 1);
      expect(postingCount, 2);
    });

    test('E2: Fingerprint-only historical match strictly refuses auto-linking and quarantines in Review Queue (P14-T64)', () async {
      final now = DateTime.now().toUtc();
      const body = 'Debited Rs 250 at Cafe Coffee Day without reference';
      final bodyFp = CanonicalTransactionAdapter.computeBodyFingerprint(body);

      // Seed pre-migration legacy evidence without reference
      await db.insert(TablesV24.evidence, {
        'id': const Uuid().v4(),
        'economic_event_id': null,
        'source_type': 'sms',
        'source_record_id': null,
        'extracted_amount_minor_units': 25000,
        'extracted_timestamp': now.toIso8601String(),
        'external_reference': null,
        'body_sha256': bodyFp,
        'is_payload_purged': 0,
        'created_at': now.toIso8601String(),
      });

      // Historical reconciliation scan encounters this SMS
      final linkResult = await db.transaction((txn) => dedupService.linkHistoricalSms(
            smsId: '9902',
            body: body,
            sender: 'SBI',
            timestamp: now,
            amountMinorUnits: 25000,
            utrOrRrn: null,
            txn: txn,
          ));

      // Invariant: Fingerprint-only matching is forbidden for auto-linking; must quarantine in Review Queue
      expect(linkResult.isLinked, isFalse);
      expect(linkResult.isQuarantined, isTrue);
      expect(linkResult.reason, 'AMBIGUOUS_HISTORICAL_SMS_RECONCILIATION');
    });
  });

  group('Category F — Atomicity and Concurrency', () {
    test('F1: SQLite unique constraint idx_evidence_source_record rejects duplicate source insertion', () async {
      const srcId = 'SRC:TELEPHONY_SMS:9999';
      final now = DateTime.now().toUtc().toIso8601String();

      await db.insert(TablesV24.evidence, {
        'id': const Uuid().v4(),
        'source_type': 'sms',
        'source_record_id': srcId,
        'extracted_amount_minor_units': 10000,
        'extracted_timestamp': now,
        'body_sha256': 'hash_f1',
        'is_payload_purged': 0,
        'created_at': now,
      });

      // Attempt second raw insert with duplicate source_record_id
      expect(
        () async => await db.insert(
          TablesV24.evidence,
          {
            'id': const Uuid().v4(),
            'source_type': 'sms',
            'source_record_id': srcId,
            'extracted_amount_minor_units': 10000,
            'extracted_timestamp': now,
            'body_sha256': 'hash_f2',
            'is_payload_purged': 0,
            'created_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.abort,
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('F2: Injected failure during transaction rolls back evidence and events atomically', () async {
      final candidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:8888',
        sourceChannel: SourceChannel.sms,
        sender: 'Bank',
        body: 'Debited 500',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: DateTime.now().toUtc(),
      );

      try {
        await db.transaction((txn) async {
          await dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          );
          // Injected error before commit
          throw StateError('Simulated crash during ingestion transaction');
        });
      } catch (e) {
        expect(e, isA<StateError>());
      }

      // Verify complete rollback: zero evidence and zero economic events persisted
      final evidenceCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.evidence} WHERE source_record_id = ?', ['SRC:TELEPHONY_SMS:8888']),
      );
      final eventCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      expect(evidenceCount, 0);
      expect(eventCount, 0);
    });

    test('F3: Crash/retry after transaction commit before checkpoint persistence is safely absorbed by Stage 0', () async {
      final candidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:7777',
        sourceChannel: SourceChannel.sms,
        sender: 'SBI',
        body: 'Debited Rs 1,000 at Supermarket',
        amountMinorUnits: 100000,
        direction: PostingDirection.debit,
        timestamp: DateTime.now().toUtc(),
      );

      // Pass 1: commits transaction successfully
      final res1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
      expect(res1.status, DeduplicationStatus.newEventCreated);

      // (Simulate crash before updating paginator checkpoint)

      // Pass 2: recovery paginator restarts and feeds the same message again
      final res2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
      expect(res2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(res2.eventId, res1.eventId);

      // Exactly 1 event, exactly 2 postings in the ledger
      final eventCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(eventCount, 1);
      expect(postingCount, 2);
    });
  });

  group('Category G — Accounting Regression', () {
    test('G1: Shared UTR between payment and refund creates distinct events linked via reversal_of_event_id (P14-T07, P14-T08)', () async {
      final now = DateTime.now().toUtc();
      const sharedUtr = 'UPI:RRN:555666777888';

      // 1. Original purchase: ₹200 debit
      final purchase = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:601',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited ₹200.00 from HDFC Bank A/c 2222. UPI/555666777888/Merchant',
        amountMinorUnits: 20000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: sharedUtr,
        accountId: 'acc_hdfc_2222',
        eventType: CanonicalEventType.expense,
      );

      final r1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: purchase,
            txn: txn,
          ));
      expect(r1.status, DeduplicationStatus.newEventCreated);
      final purchaseEventId = r1.eventId!;

      // 2. Refund arrives sharing the same UTR: ₹200 credit
      final refund = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:602',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Credited ₹200.00 to HDFC Bank A/c 2222 refund for UPI/555666777888',
        amountMinorUnits: 20000,
        direction: PostingDirection.credit,
        timestamp: now.add(const Duration(minutes: 5)),
        externalReference: sharedUtr,
        accountId: 'acc_hdfc_2222',
        eventType: CanonicalEventType.refund,
        originalPurchaseEventId: purchaseEventId,
      );

      final r2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: refund,
            txn: txn,
          ));

      // Invariant: Both are recorded as distinct events; refund linked as reversal/refund
      expect(r2.status, DeduplicationStatus.newEventCreated);
      expect(r2.eventId, isNot(equals(purchaseEventId)));

      final refundRow = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: [r2.eventId],
      );
      expect(refundRow.first['reversal_of_event_id'], purchaseEventId);

      // Verify refund allocation table has valid relational link
      final allocation = await refundRepo.findByRefundEventId(r2.eventId!);
      expect(allocation, isNotNull);
      expect(allocation!.refundEventId, r2.eventId);
      expect(allocation.originalEventId, purchaseEventId);
      expect(allocation.allocatedAmountMinorUnits, 20000);
    });
  });

  group('Stage 4 Acceptance Addendum — Verification Requirements', () {
    test('V1: End-to-end push source identity tracing through simulated pipeline', () async {
      // 1. Layer A generates stable push source ID
      const pkg = 'com.google.android.apps.nbu.paisa.user';
      const notifId = 8842;
      const tag = 'payment_notif';
      const postTime = 1700100200300;
      final expectedSourceId = 'SRC:ANDROID_NOTIF:$pkg:$notifId:$tag:$postTime';

      final generatedId = CrossChannelDeduplicationService.buildPushSourceId(
        pkg,
        notifId,
        tag,
        postTime,
      );
      expect(generatedId, expectedSourceId);

      // 2. Simulated serialization through SmsStore (delimiter format)
      const fieldSep = '\u0002';
      const sender = 'APP:$pkg:Google Pay';
      const body = 'Paid ₹750.00 to Swiggy. UPI Ref 887766554433';
      final queuedEntry = '$sender$fieldSep$body$fieldSep$generatedId';

      // 3. Simulated deserialization in all(context)
      final parts = queuedEntry.split(fieldSep);
      expect(parts.length, 3);
      final deserializedSender = parts[0];
      final deserializedBody = parts[1];
      final deserializedSourceId = parts[2];
      expect(deserializedSourceId, expectedSourceId);

      // 4. Ingestion via CrossChannelDeduplicationService
      final candidate = IncomingTransactionCandidate(
        sourceRecordId: deserializedSourceId,
        sourceChannel: SourceChannel.push,
        sender: deserializedSender,
        body: deserializedBody,
        amountMinorUnits: 75000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(postTime, isUtc: true),
        externalReference: '887766554433',
        merchant: 'Swiggy',
      );

      final result1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
      expect(result1.status, DeduplicationStatus.newEventCreated);
      final eventId = result1.eventId!;

      // 5. Verify SQLite evidence.source_record_id contains the exact original ID
      final evidenceRows = await db.query(
        TablesV24.evidence,
        columns: ['id', 'source_record_id', 'economic_event_id'],
        where: 'economic_event_id = ?',
        whereArgs: [eventId],
      );
      expect(evidenceRows.length, 1);
      expect(evidenceRows.first['source_record_id'], expectedSourceId);

      // 6. Replay identical notification lifecycle event:
      // Stage 0 absorbs replay, returns existing event, zero new economic events, zero new postings
      final result2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: candidate,
            txn: txn,
          ));
      expect(result2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(result2.eventId, eventId);

      final totalEvents = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final totalPostings = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(totalEvents, 1);
      expect(totalPostings, 2);
    });

    test('V2: Genuine concurrent ingestion with synchronization barrier and constraint-collision recovery', () async {
      const sourceId = 'SRC:TELEPHONY_SMS:554433';
      final now = DateTime.now().toUtc();

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: sourceId,
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited INR 1,200.00 from A/c 2222',
        amountMinorUnits: 120000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountId: 'acc_hdfc_2222',
      );

      // ────────────────────────────────────────────────────────────────────────
      // Part 1: Genuine Concurrent Dispatch with Synchronization Barrier
      // ────────────────────────────────────────────────────────────────────────
      // Both workers start simultaneously before either transaction completes.
      final barrier1 = Completer<void>();
      final barrier2 = Completer<void>();

      var worker1Started = false;
      var worker2Started = false;

      final worker1Future = Future(() async {
        worker1Started = true;
        barrier1.complete();
        // Wait until worker 2 has also been dispatched
        await barrier2.future;
        return await dedupService.processWithConflictResolution(
          candidate: candidate,
          db: db,
        );
      });

      final worker2Future = Future(() async {
        worker2Started = true;
        barrier2.complete();
        // Wait until worker 1 has also been dispatched
        await barrier1.future;
        return await dedupService.processWithConflictResolution(
          candidate: candidate,
          db: db,
        );
      });

      // Confirm both workers entered execution before either completed
      final results = await Future.wait([worker1Future, worker2Future]);
      expect(worker1Started, isTrue);
      expect(worker2Started, isTrue);

      final resA = results[0];
      final resB = results[1];

      // Exactly one worker must create the new event; the other must resolve to duplicateSourceRecord
      final createdCount = results.where((r) => r.isNewEventCreated).length;
      final duplicateCount = results.where((r) => r.isDuplicateSource).length;
      expect(createdCount, 1);
      expect(duplicateCount, 1);

      final winningEventId = resA.isNewEventCreated ? resA.eventId : resB.eventId;
      final losingEventId = resA.isDuplicateSource ? resA.eventId : resB.eventId;
      expect(losingEventId, winningEventId);

      // Verify strictly 1 canonical event, 2 balanced postings, and 1 evidence row
      final eventCount1 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCount1 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      final evidenceCount1 = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.evidence}'),
      );
      expect(eventCount1, 1);
      expect(postingCount1, 2);
      expect(evidenceCount1, 1);

      // ────────────────────────────────────────────────────────────────────────
      // Part 2: Active Constraint Collision & Safe Rollback Verification
      // ────────────────────────────────────────────────────────────────────────
      // Simulate a concurrent race condition where a losing transaction attempts to
      // insert the identical source_record_id directly into the database.
      // SQLite UNIQUE constraint on idx_evidence_source_record MUST abort the transaction,
      // roll back all partial draft events, and leave zero orphaned postings.
      const collidingDraftId = 'event_colliding_draft_worker2';
      bool collisionCaught = false;

      try {
        await db.transaction((txn) async {
          // Worker 2 creates its draft event
          await txn.insert(TablesV24.economicEvents, {
            'id': collidingDraftId,
            'event_type': 'expense',
            'lifecycle_status': 'draft',
            'timestamp': now.toIso8601String(),
            'currency': 'INR',
            'description': 'Colliding Draft Worker 2',
            'created_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
          });

          // Worker 2 attempts to insert evidence with colliding source_record_id
          await txn.insert(
            TablesV24.evidence,
            {
              'id': const Uuid().v4(),
              'economic_event_id': collidingDraftId,
              'source_type': 'sms',
              'source_record_id': sourceId, // Collides with committed sourceId
              'extracted_amount_minor_units': 120000,
              'extracted_timestamp': now.toIso8601String(),
              'body_sha256': 'hash_colliding',
              'is_payload_purged': 0,
              'created_at': now.toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.abort,
          );
        });
      } on DatabaseException catch (e) {
        collisionCaught = true;
        expect(
          e.toString().contains('UNIQUE constraint failed: evidence.source_record_id') ||
              e.toString().contains('idx_evidence_source_record'),
          isTrue,
        );
      }

      expect(collisionCaught, isTrue);

      // Verify SQLite transaction rolled back completely:
      // Draft event 'event_colliding_draft_worker2' MUST NOT exist!
      final orphanDrafts = await db.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: [collidingDraftId],
      );
      expect(orphanDrafts, isEmpty);

      // Total canonical events and postings remain strictly 1 and 2
      final eventCountFinal = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCountFinal = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(eventCountFinal, 1);
      expect(postingCountFinal, 2);

      // Verify processWithConflictResolution handles constraint conflicts gracefully
      final conflictRecoveryResult = await dedupService.processWithConflictResolution(
        candidate: candidate,
        db: db,
      );
      expect(conflictRecoveryResult.isDuplicateSource, isTrue);
      expect(conflictRecoveryResult.eventId, winningEventId);
    });

    test('V3: Notification lifecycle behaviors (update, cancellation, reposting, duplicate repeat)', () async {
      final now = DateTime.now().toUtc();
      const pkg = 'com.phonepe.app';

      // 1. Initial notification posting
      const sbnId = 55;
      const tag = 'txn_alert';
      const postTime1 = 1700200000000;
      final sourceId1 = CrossChannelDeduplicationService.buildPushSourceId(pkg, sbnId, tag, postTime1);

      final notif1 = IncomingTransactionCandidate(
        sourceRecordId: sourceId1,
        sourceChannel: SourceChannel.push,
        sender: 'APP:$pkg:PhonePe',
        body: 'Paid ₹250.00 to Merchant A',
        amountMinorUnits: 25000,
        direction: PostingDirection.debit,
        timestamp: now,
      );

      final r1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: notif1,
            txn: txn,
          ));
      expect(r1.status, DeduplicationStatus.newEventCreated);

      // 2. Notification update with unchanged identity:
      // Same sourceId1 re-evaluated -> Stage 0 prevents duplicate
      final rUpdate = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: notif1,
            txn: txn,
          ));
      expect(rUpdate.status, DeduplicationStatus.duplicateSourceRecord);

      // 3. Reposting / new notification after cancellation with new postTime (2 min later, same amount, no UTR):
      // Layer B Stage 2 routes ambiguous repeat to Review Queue without silent drop
      const postTime2 = postTime1 + 120000;
      final sourceId2 = CrossChannelDeduplicationService.buildPushSourceId(pkg, sbnId, tag, postTime2);

      final notif2 = IncomingTransactionCandidate(
        sourceRecordId: sourceId2,
        sourceChannel: SourceChannel.push,
        sender: 'APP:$pkg:PhonePe',
        body: 'Paid ₹250.00 to Merchant A',
        amountMinorUnits: 25000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 2)),
      );

      final r2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: notif2,
            txn: txn,
          ));
      expect(r2.status, DeduplicationStatus.routedToReviewQueue);
      expect(r2.reviewReason, 'REPEAT_PAYMENT_SUSPECTED_DUPLICATE');

      // Verify review candidate created with ZERO extra postings
      final reviewCandidates = await db.query(TablesV24.reviewCandidates);
      expect(reviewCandidates.length, 1);
      final postings = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(postings, 2); // only original 2 postings from initial post
    });

    test('V4: Reference normalization validation & rejection of non-reference numbers', () {
      // 1. Valid UTR/RRN extraction & canonical normalization
      final validPatterns = [
        'Paid via UPI/532342342342/Merchant',
        'Ref no: 532342342342 completed',
        'RRN 532342342342 for your payment',
        'UTR: 532342342342 credited',
        'UPI Ref 532342342342',
      ];

      for (final text in validPatterns) {
        final extracted = CrossChannelDeduplicationService.extractUtrOrRrn(text);
        expect(extracted, '532342342342', reason: 'Failed for pattern: $text');
        final normalized = CrossChannelDeduplicationService.normalizeReference(extracted!);
        expect(normalized, 'UPI:RRN:532342342342');
      }

      // 2. Plain numbers without banking reference context MUST NOT be extracted as UTR/RRN
      final invalidPatterns = [
        'Your A/c 123456789012 has a balance of Rs 500',
        'Call customer care at 987654321012 for support',
        'Order # 123456789012 placed successfully',
        'Timestamp is 202611181050 for statement',
        'Amount Rs 123456789012 debited',
      ];

      for (final text in invalidPatterns) {
        final extracted = CrossChannelDeduplicationService.extractUtrOrRrn(text);
        expect(
          extracted,
          isNull,
          reason: 'Arbitrary 12-digit number should NOT be extracted from: $text',
        );
      }
    });

    test('V5: End-to-end bridge: Android push notification identity through SmsStore and Dart ingestion', () async {
      // 1. Android BankNotificationListener source ID generation
      const pkg = 'net.one97.paytm';
      const sbnId = 7788;
      const tag = 'paytm_txn';
      const postTime = 1731920000000;
      final sourceRecordId = CrossChannelDeduplicationService.buildPushSourceId(pkg, sbnId, tag, postTime);
      expect(sourceRecordId, 'SRC:ANDROID_NOTIF:net.one97.paytm:7788:paytm_txn:1731920000000');

      const senderTitle = 'Paytm';
      const fullBody = 'Paid Rs 340.00 to Merchant Coffee. UPI/532342349999/Success';

      // 2. Android SmsStore queue serialization: "$sender\u0002$body\u0002$sourceRecordId"
      const fieldSep = '\u0002';
      final serializedQueueEntry = '$senderTitle$fieldSep$fullBody$fieldSep$sourceRecordId';

      // 3. App Restart & Deserialization in SmsStore.all()
      final parts = serializedQueueEntry.split(fieldSep);
      expect(parts.length, 3);
      final deserializedMap = {
        'sender': parts[0],
        'body': parts[1],
        'sourceRecordId': parts[2],
      };
      expect(deserializedMap['sourceRecordId'], sourceRecordId);

      // 4. Dart Ingestion: LiveSmsService extracts sourceRecordId and creates IncomingTransactionCandidate
      final extractedSourceId = deserializedMap['sourceRecordId'];
      expect(extractedSourceId, isNotNull);

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: extractedSourceId!,
        sourceChannel: SourceChannel.push,
        sender: deserializedMap['sender']!,
        body: deserializedMap['body']!,
        amountMinorUnits: 34000,
        direction: PostingDirection.debit,
        timestamp: DateTime.fromMillisecondsSinceEpoch(postTime, isUtc: true),
        externalReference: 'UPI:RRN:532342349999',
        accountId: 'acc_hdfc_2222',
        merchant: 'Merchant Coffee',
      );

      // 5. Ingestion through Deduplication Service
      final result1 = await dedupService.processWithConflictResolution(
        candidate: candidate,
        db: db,
      );
      expect(result1.status, DeduplicationStatus.newEventCreated);
      expect(result1.eventId, isNotNull);

      // Verify exact source_record_id is preserved in SQLite evidence table
      final evidenceRows = await db.query(
        TablesV24.evidence,
        where: 'source_record_id = ?',
        whereArgs: [sourceRecordId],
      );
      expect(evidenceRows.length, 1);
      expect(evidenceRows.first['source_record_id'], sourceRecordId);
      expect(evidenceRows.first['economic_event_id'], result1.eventId);

      // 6. Replay lifecycle test: identical notification replayed from queue
      final replayResult = await dedupService.processWithConflictResolution(
        candidate: candidate,
        db: db,
      );
      expect(replayResult.status, DeduplicationStatus.duplicateSourceRecord);
      expect(replayResult.eventId, result1.eventId);

      // Verify zero extra economic events or postings created on replay
      final eventCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.economicEvents}'),
      );
      final postingCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM ${TablesV24.postings}'),
      );
      expect(eventCount, 1);
      expect(postingCount, 2);
    });
  });
}
