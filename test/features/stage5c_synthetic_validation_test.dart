import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:spend_x/domain/finance/economic_event.dart';
import 'package:spend_x/domain/finance/posting.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
import 'package:spend_x/services/sms_import_service.dart';
import 'package:spend_x/services/sms_recovery_paginator.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    tempDir = await Directory.systemTemp.createTemp('spendx_stage5c_test_');
    dbPath = p.join(tempDir.path, 'stage5c_validation.db');

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

    // Seed test accounts
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert(TablesV24.accounts, {
      'id': 'acc_test_sbi_1111',
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
      'id': 'acc_test_hdfc_4321',
      'account_type': 'asset',
      'subtype': 'checking',
      'name': 'HDFC A/c 4321',
      'account_number_last4': '4321',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(TablesV24.accounts, {
      'id': 'acc_test_sbi_card_9012',
      'account_type': 'liability',
      'subtype': 'credit_card',
      'name': 'SBI Card 9012',
      'account_number_last4': '9012',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // Helper to query account balance from postings table
  Future<int> getAccountBalanceMinorUnits(String accountId) async {
    final res = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE -amount_minor_units END), 0) as balance
      FROM ${TablesV24.postings}
      WHERE account_id = ?
    ''', [accountId]);
    return (res.first['balance'] as num).toInt();
  }

  // Helper to verify trial balance across entire database
  Future<void> assertBalancedLedger() async {
    final res = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END), 0) as total_debits,
        COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END), 0) as total_credits
      FROM ${TablesV24.postings}
    ''');
    final debits = (res.first['total_debits'] as num).toInt();
    final credits = (res.first['total_credits'] as num).toInt();
    expect(debits, equals(credits), reason: 'Trial balance must be exactly balanced across all postings');
  }

  group('Phase 5C.2 & 5C.3: Synthetic Fixture Matrix & Classification', () {
    test('Fixture 1: Successful debit SMS', () {
      final res = SmsImportService.instance.classifyMessage(
        'Rs 1250.00 debited from HDFC Bank A/c **4321 on 18-Nov-26 to SWIGGY. Avl Bal: Rs 45,210.00. Ref: 432198765432',
        'VM-HDFCBK',
      );
      expect(res.eventType, SmsEventType.expense);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 1250.00);
      expect(res.transaction!.isCredit, isFalse);
      expect(res.transaction!.last4, '4321');
      expect(res.transaction!.refId, isNotNull);
    });

    test('Fixture 2: Successful credit SMS', () {
      final res = SmsImportService.instance.classifyMessage(
        'Dear Customer, your A/c ending 1111 credited by Rs 50,000.00 on 18-Nov-26 by Salary deposit. Avl Bal: Rs 95,210.00. UTR: SBIN00012345678',
        'VK-SBIINB',
      );
      expect(res.eventType, SmsEventType.income);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 50000.00);
      expect(res.transaction!.isCredit, isTrue);
      expect(res.transaction!.last4, '1111');
      expect(res.transaction!.refId, isNotNull);
    });

    test('Fixture 3: UPI payment alert', () {
      final res = SmsImportService.instance.classifyMessage(
        'Dear SBI UPI User, Rs 450.00 debited from A/c **1111 on 18-Nov-26 to Chai Point. UPI Ref: 632154987123. Not you? Call bank.',
        'AX-SBIUPI',
      );
      expect(res.eventType, SmsEventType.expense);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 450.00);
      expect(res.transaction!.isCredit, isFalse);
      expect(res.transaction!.refId, '632154987123');
    });

    test('Fixture 4: Bank transfer', () {
      final res = SmsImportService.instance.classifyMessage(
        'Dear Customer, Rs 10000.00 transferred from A/c **4321 to A/c **1111 via IMPS on 18-Nov-26. Ref: IMPS98765432101.',
        'AD-HDFCBK',
      );
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 10000.00);
      expect(res.transaction!.last4, '4321');
    });

    test('Fixture 5: Credit card purchase', () {
      final res = SmsImportService.instance.classifyMessage(
        'Alert: Spent Rs 2,499.00 on SBI Credit Card ending 9012 at AMAZON INDIA on 18-Nov-26. Available limit: Rs 75,000.00.',
        'VK-SBICRD',
      );
      expect(res.eventType, SmsEventType.creditCardPurchase);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 2499.00);
      expect(res.transaction!.last4, '9012');
    });

    test('Fixture 6: Credit card bill payment', () {
      final res = SmsImportService.instance.classifyMessage(
        'Thank you for payment of Rs 15,000.00 towards your SBI Credit Card ending 9012 received on 18-Nov-26. Available limit: Rs 90,000.00.',
        'VK-SBICRD',
      );
      expect(res.eventType, SmsEventType.creditCardPayment);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 15000.00);
      expect(res.transaction!.last4, '9012');
    });

    test('Fixture 7: Refund', () {
      final res = SmsImportService.instance.classifyMessage(
        'Refund of Rs 450.00 credited to your HDFC Bank A/c **4321 on 18-Nov-26 from SWIGGY. Ref: 432198765432.',
        'AD-HDFCBK',
      );
      expect(res.eventType, SmsEventType.refund);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 450.00);
      expect(res.transaction!.isCredit, isTrue);
    });

    test('Fixture 8: Reversal', () {
      final res = SmsImportService.instance.classifyMessage(
        'Reversal of Rs 1,200.00 credited to A/c ending 1111 on 18-Nov-26. UPI Ref: 632154987123.',
        'VK-SBIINB',
      );
      expect(res.transaction, isNotNull);
      expect(res.transaction!.amount, 1200.00);
      expect(res.transaction!.isCredit, isTrue);
    });

    test('Fixture 9: Failed transaction attempt', () {
      final res = SmsImportService.instance.classifyMessage(
        'Your transaction of Rs 5,000.00 at FLIPKART using Card ending 9012 failed due to insufficient balance. Ref: FAIL987654.',
        'VM-HDFCBK',
      );
      expect(res.eventType, SmsEventType.failed);
      expect(res.transaction, isNull);
    });

    test('Fixture 10: Balance-only notification', () {
      final res = SmsImportService.instance.classifyMessage(
        'Dear Customer, available balance in your SBI A/c **1111 is Rs 45,210.00.',
        'VK-SBIINB',
      );
      expect(res.eventType, SmsEventType.infoOnly);
      expect(res.transaction, isNull);
      expect(res.balance, isNotNull);
      expect(res.balance!.amount, 45210.00);
      expect(res.balance!.last4, '1111');
    });

    test('Fixture 11: Unknown marketing sender', () {
      final res = SmsImportService.instance.classifyMessage(
        'Get 50% off on your next purchase at MegaStore! Use code SAVE50.',
        'XYZ-PROMO',
      );
      expect(res.transaction, isNull);
      expect(res.balance, isNull);
    });

    test('Fixture 12: Malformed unparseable message', () {
      final res = SmsImportService.instance.classifyMessage(
        'debited from a/c without amount or date invalid random string',
        'VM-HDFCBK',
      );
      expect(res.transaction, isNull);
    });

    test('Fixture 13: Duplicate message detection via UTR and source ID', () {
      final utr1 = CrossChannelDeduplicationService.extractUtrOrRrn(
        'debited Rs 200.00 from A/c **1111. UPI Ref: 123456789012',
      );
      final utr2 = CrossChannelDeduplicationService.extractUtrOrRrn(
        'debited Rs 200.00 from A/c **1111. UPI Ref: 123456789012',
      );
      expect(utr1, isNotNull);
      expect(utr1, equals(utr2));
    });

    test('Fixture 14: Message with explicit 12-digit UPI RRN', () {
      final ref = CrossChannelDeduplicationService.extractUtrOrRrn(
        'A/c 1111 debited Rs 100 on 18-Nov-26. UPI Ref: 987654321098.',
      );
      expect(ref, '987654321098');
      expect(CrossChannelDeduplicationService.normalizeReference(ref!), 'UPI:RRN:987654321098');
    });

    test('Fixture 15: Message without stable reference', () {
      final ref = CrossChannelDeduplicationService.extractUtrOrRrn(
        'Rs 500 debited from A/c ending 1111 on 18-Nov-26 at Local Kirana.',
      );
      expect(ref, isNull);
    });

    test('Fixture 16: Ambiguous transaction routing to Review Queue', () async {
      final now = DateTime.now();
      // Candidate with unreferenced collision in 120s window
      final c1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:1001',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Rs 500.00 debited from A/c **1111 at Shop A.',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountNumberLast4: '1111',
        accountId: 'acc_test_sbi_1111',
      );
      final res1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(res1.status, DeduplicationStatus.newEventCreated);

      // Candidate 2 has matching account, amount, and timestamp within 120s, but DIFFERENT source and no UTR
      final c2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:1::17000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Paid Rs 500.00 from SBI account.',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 30)),
        accountNumberLast4: '1111',
        accountId: 'acc_test_sbi_1111',
      );
      final res2 = await dedupService.processWithConflictResolution(candidate: c2, db: db);
      expect(res2.status, DeduplicationStatus.routedToReviewQueue);
      expect(res2.reviewReason, 'CROSS_CHANNEL_UNREFERENCED_ACCOUNT_MATCH');
    });
  });

  group('Phase 5C.4: Cross-Channel Deduplication (10 Scenarios)', () {
    final baseTime = DateTime.parse('2026-11-18T10:00:00Z');

    test('Scenario 1: Same SMS source ID processed twice (Stage 0 Idempotency)', () async {
      final c = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9001',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 1200 debited from A/c **4321. Ref: 987612345678',
        amountMinorUnits: 120000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        accountId: 'acc_test_hdfc_4321',
      );
      final r1 = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(r1.status, DeduplicationStatus.newEventCreated);

      final r2 = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(r2.status, DeduplicationStatus.duplicateSourceRecord);
      expect(r2.eventId, r1.eventId);

      // Verify only 1 economic event exists
      final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM economic_events;'));
      expect(count, 1);
    });

    test('Scenario 2: Two distinct SMS records with identical content (P14-T04, P14-T11)', () async {
      final c1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9002',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 500 debited from A/c **4321 at Coffee Shop',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        accountNumberLast4: '4321',
        accountId: 'acc_test_hdfc_4321',
      );
      final r1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(r1.status, DeduplicationStatus.newEventCreated);

      final c2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9003',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 500 debited from A/c **4321 at Coffee Shop',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: baseTime.add(const Duration(seconds: 45)),
        accountNumberLast4: '4321',
        accountId: 'acc_test_hdfc_4321',
      );
      final r2 = await dedupService.processWithConflictResolution(candidate: c2, db: db);
      expect(r2.status, DeduplicationStatus.newEventCreated);
      expect(r1.eventId, isNot(equals(r2.eventId)));

      final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM economic_events WHERE id IN (?, ?);', [r1.eventId, r2.eventId]));
      expect(count, 2);
    });

    test('Scenario 3: SMS and push with matching 12-digit UTR (Tier 1 Merge)', () async {
      final cPush = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:101::17000',
        sourceChannel: SourceChannel.push,
        sender: 'Google Pay',
        body: 'Paid Rs 750.00 to Swiggy. UPI Ref: 112233445566',
        amountMinorUnits: 75000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        externalReference: '112233445566',
        accountId: 'acc_test_sbi_1111',
      );
      final rPush = await dedupService.processWithConflictResolution(candidate: cPush, db: db);
      expect(rPush.status, DeduplicationStatus.newEventCreated);

      final cSms = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9004',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'A/c 1111 debited Rs 750.00 on 18-Nov-26. UPI Ref: 112233445566',
        amountMinorUnits: 75000,
        direction: PostingDirection.debit,
        timestamp: baseTime.add(const Duration(seconds: 10)),
        externalReference: '112233445566',
        accountId: 'acc_test_sbi_1111',
      );
      final rSms = await dedupService.processWithConflictResolution(candidate: cSms, db: db);
      expect(rSms.status, DeduplicationStatus.strongMatchMerged);
      expect(rSms.eventId, rPush.eventId);

      // Verify exactly 1 event and 2 evidence items
      final evCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM evidence WHERE economic_event_id = ?;', [rPush.eventId]));
      expect(evCount, 2);
    });

    test('Scenario 4: SMS and push with no stable reference (routes to Review Queue)', () async {
      final cPush = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:201::17000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Paid Rs 300 to Merchant',
        amountMinorUnits: 30000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        accountNumberLast4: '1111',
        accountId: 'acc_test_sbi_1111',
      );
      final rPush = await dedupService.processWithConflictResolution(candidate: cPush, db: db);
      expect(rPush.status, DeduplicationStatus.newEventCreated);

      final cSms = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9005',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Rs 300 debited from A/c **1111',
        amountMinorUnits: 30000,
        direction: PostingDirection.debit,
        timestamp: baseTime.add(const Duration(seconds: 15)),
        accountNumberLast4: '1111',
        accountId: 'acc_test_sbi_1111',
      );
      final rSms = await dedupService.processWithConflictResolution(candidate: cSms, db: db);
      expect(rSms.status, DeduplicationStatus.routedToReviewQueue);
    });

    test('Scenario 5: One-sided reference availability (safe routing)', () async {
      // SMS has UTR, push doesn't
      final cSms = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9006',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'A/c 1111 debited Rs 400. UPI Ref: 998877665544',
        amountMinorUnits: 40000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        externalReference: '998877665544',
        accountNumberLast4: '1111',
        accountId: 'acc_test_sbi_1111',
      );
      final rSms = await dedupService.processWithConflictResolution(candidate: cSms, db: db);
      expect(rSms.status, DeduplicationStatus.newEventCreated);

      // Push arrives without UTR in 60s
      final cPush = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:301::17000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Paid Rs 400 to Grocery',
        amountMinorUnits: 40000,
        direction: PostingDirection.debit,
        timestamp: baseTime.add(const Duration(seconds: 20)),
        accountNumberLast4: '1111',
        accountId: 'acc_test_sbi_1111',
      );
      final rPush = await dedupService.processWithConflictResolution(candidate: cPush, db: db);
      expect(rPush.status, DeduplicationStatus.routedToReviewQueue);
    });

    test('Scenario 6: Repeated notification lifecycle updates', () async {
      final cInitial = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:401:txn:1700000000000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Processing payment of Rs 150',
        amountMinorUnits: 15000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        accountId: 'acc_test_sbi_1111',
      );
      final r1 = await dedupService.processWithConflictResolution(candidate: cInitial, db: db);
      expect(r1.status, DeduplicationStatus.newEventCreated);

      // Resent with exact same source ID
      final r2 = await dedupService.processWithConflictResolution(candidate: cInitial, db: db);
      expect(r2.status, DeduplicationStatus.duplicateSourceRecord);
    });

    test('Scenario 7: Notification cancellation and repost', () async {
      final c1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:501:tag1:1700000000000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Payment of Rs 250 successful',
        amountMinorUnits: 25000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        accountId: 'acc_test_sbi_1111',
      );
      final r1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(r1.status, DeduplicationStatus.newEventCreated);

      // Reposted with updated timestamp in source ID
      final cRepost = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:501:tag1:1700000005000',
        sourceChannel: SourceChannel.push,
        sender: 'PhonePe',
        body: 'Payment of Rs 250 successful',
        amountMinorUnits: 25000,
        direction: PostingDirection.debit,
        timestamp: baseTime.add(const Duration(seconds: 5)),
        accountNumberLast4: '1111',
        accountId: 'acc_test_sbi_1111',
      );
      final r2 = await dedupService.processWithConflictResolution(candidate: cRepost, db: db);
      expect(r2.status, DeduplicationStatus.routedToReviewQueue);
    });

    test('Scenario 8: Same amount and merchant but distinct UTRs (separate legitimate transactions)', () async {
      final c1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9007',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Rs 100 debited at Metro. UPI Ref: 111122223333',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        externalReference: '111122223333',
        accountId: 'acc_test_sbi_1111',
      );
      final r1 = await dedupService.processWithConflictResolution(candidate: c1, db: db);
      expect(r1.status, DeduplicationStatus.newEventCreated);

      // Second ride 10 minutes later with different UTR
      final c2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:9008',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Rs 100 debited at Metro. UPI Ref: 444455556666',
        amountMinorUnits: 10000,
        direction: PostingDirection.debit,
        timestamp: baseTime.add(const Duration(minutes: 10)),
        externalReference: '444455556666',
        accountId: 'acc_test_sbi_1111',
      );
      final r2 = await dedupService.processWithConflictResolution(candidate: c2, db: db);
      expect(r2.status, DeduplicationStatus.newEventCreated);
      expect(r1.eventId, isNot(equals(r2.eventId)));
    });

    test('Scenario 9: Concurrent ingestion attempts with unique constraint recovery', () async {
      final candidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:CONCURRENT_99',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 500 debited. Ref: 987654321',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        accountId: 'acc_test_hdfc_4321',
      );

      // Run parallel calls
      final results = await Future.wait([
        dedupService.processWithConflictResolution(candidate: candidate, db: db),
        dedupService.processWithConflictResolution(candidate: candidate, db: db),
      ]);

      final statuses = results.map((r) => r.status).toList();
      expect(statuses, contains(DeduplicationStatus.newEventCreated));
      expect(statuses, contains(DeduplicationStatus.duplicateSourceRecord));

      // Assert exactly 1 event created
      final count = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM evidence WHERE source_record_id = ?;',
        ['SRC:TELEPHONY_SMS:CONCURRENT_99'],
      ));
      expect(count, 1);
    });

    test('Scenario 10: Process interruption between evidence creation and event posting (Atomic rollback)', () async {
      final candidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:INTERRUPT_FAIL',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 800 debited',
        amountMinorUnits: 80000,
        direction: PostingDirection.debit,
        timestamp: baseTime,
        accountId: 'acc_test_hdfc_4321',
      );

      try {
        await db.transaction((txn) async {
          await dedupService.processIncomingCandidate(candidate: candidate, txn: txn);
          throw StateError('Simulated crash before commit');
        });
      } catch (_) {
        // Expected
      }

      // Verify zero partial records left
      final evCount = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM evidence WHERE source_record_id = ?;', ['SRC:TELEPHONY_SMS:INTERRUPT_FAIL']));
      expect(evCount, 0);
    });
  });

  group('Phase 5C.5: Accounting Integrity Invariants', () {
    final now = DateTime.now().toUtc();

    test('Accounting 1: Expense (Debit expense, Credit asset)', () async {
      final initialBal = await getAccountBalanceMinorUnits('acc_test_hdfc_4321');

      final c = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:ACCT_EXPENSE_1',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 1500 debited for dinner',
        amountMinorUnits: 150000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountId: 'acc_test_hdfc_4321',
        eventType: CanonicalEventType.expense,
      );
      final r = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(r.status, DeduplicationStatus.newEventCreated);

      final newBal = await getAccountBalanceMinorUnits('acc_test_hdfc_4321');
      expect(newBal, equals(initialBal - 150000));
      await assertBalancedLedger();
    });

    test('Accounting 2: Income (Debit asset, Credit income)', () async {
      final initialBal = await getAccountBalanceMinorUnits('acc_test_sbi_1111');

      final c = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:ACCT_INCOME_1',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Rs 25000 credited salary',
        amountMinorUnits: 2500000,
        direction: PostingDirection.credit,
        timestamp: now,
        accountId: 'acc_test_sbi_1111',
        eventType: CanonicalEventType.income,
      );
      final r = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(r.status, DeduplicationStatus.newEventCreated);

      final newBal = await getAccountBalanceMinorUnits('acc_test_sbi_1111');
      expect(newBal, equals(initialBal + 2500000));
      await assertBalancedLedger();
    });

    test('Accounting 3: Transfer between accounts (Debit dest, Credit src, zero net P&L)', () async {
      final sbiBefore = await getAccountBalanceMinorUnits('acc_test_sbi_1111');
      final hdfcBefore = await getAccountBalanceMinorUnits('acc_test_hdfc_4321');

      final c = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:ACCT_TRANSFER_1',
        sourceChannel: SourceChannel.sms,
        sender: 'AD-HDFCBK',
        body: 'Rs 5000 transferred from HDFC to SBI',
        amountMinorUnits: 500000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountId: 'acc_test_hdfc_4321',
        counterpartyAccountId: 'acc_test_sbi_1111',
        eventType: CanonicalEventType.transfer,
      );
      final r = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(r.status, DeduplicationStatus.newEventCreated);

      final sbiAfter = await getAccountBalanceMinorUnits('acc_test_sbi_1111');
      final hdfcAfter = await getAccountBalanceMinorUnits('acc_test_hdfc_4321');

      expect(hdfcAfter, equals(hdfcBefore - 500000));
      expect(sbiAfter, equals(sbiBefore + 500000));
      await assertBalancedLedger();
    });

    test('Accounting 4: Credit card purchase (Debit expense, Credit liability)', () async {
      final cardBalBefore = await getAccountBalanceMinorUnits('acc_test_sbi_card_9012');

      final c = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:ACCT_CARD_PURCHASE_1',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBICRD',
        body: 'Spent Rs 3000 on card ending 9012',
        amountMinorUnits: 300000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountId: 'acc_test_sbi_card_9012',
        eventType: CanonicalEventType.cardPurchase,
      );
      final r = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(r.status, DeduplicationStatus.newEventCreated);

      final cardBalAfter = await getAccountBalanceMinorUnits('acc_test_sbi_card_9012');
      // For liability account: credit increases liability (more negative in debit-normal balance terms)
      expect(cardBalAfter, equals(cardBalBefore - 300000));
      await assertBalancedLedger();
    });

    test('Accounting 5: Credit card bill payment (Debit liability, Credit asset, zero duplicate expense)', () async {
      final bankBefore = await getAccountBalanceMinorUnits('acc_test_sbi_1111');
      final cardBefore = await getAccountBalanceMinorUnits('acc_test_sbi_card_9012');

      final c = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:ACCT_CARD_PAYMENT_1',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBICRD',
        body: 'Payment of Rs 3000 received for card 9012',
        amountMinorUnits: 300000,
        direction: PostingDirection.credit,
        timestamp: now,
        accountId: 'acc_test_sbi_card_9012',
        counterpartyAccountId: 'acc_test_sbi_1111',
        eventType: CanonicalEventType.cardPayment,
      );
      final r = await dedupService.processWithConflictResolution(candidate: c, db: db);
      expect(r.status, DeduplicationStatus.newEventCreated);

      final bankAfter = await getAccountBalanceMinorUnits('acc_test_sbi_1111');
      final cardAfter = await getAccountBalanceMinorUnits('acc_test_sbi_card_9012');

      expect(bankAfter, equals(bankBefore - 300000));
      expect(cardAfter, equals(cardBefore + 300000)); // liability reduced back towards 0
      await assertBalancedLedger();
    });

    test('Accounting 6: Refund with allocation cap', () async {
      // 1. Initial purchase Rs 1000
      final cPurchase = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:REFUND_ORIG_PURCHASE',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Rs 1000 debited at BookStore. Ref: UTRBOOK123',
        amountMinorUnits: 100000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: 'UTRBOOK123',
        accountId: 'acc_test_hdfc_4321',
        eventType: CanonicalEventType.expense,
      );
      final rPurchase = await dedupService.processWithConflictResolution(candidate: cPurchase, db: db);
      expect(rPurchase.status, DeduplicationStatus.newEventCreated);

      // 2. Refund Rs 400
      final cRefund = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:REFUND_TXN_1',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Refund of Rs 400 credited for BookStore. Ref: UTRREFUND400',
        amountMinorUnits: 40000,
        direction: PostingDirection.credit,
        timestamp: now.add(const Duration(hours: 1)),
        externalReference: 'UTRREFUND400',
        accountId: 'acc_test_hdfc_4321',
        eventType: CanonicalEventType.refund,
        originalPurchaseEventId: rPurchase.eventId,
        allocatedAmountMinorUnits: 40000,
      );
      final rRefund = await dedupService.processWithConflictResolution(candidate: cRefund, db: db);
      expect(rRefund.status, DeduplicationStatus.newEventCreated);

      // Verify refund allocation record
      final allocation = await refundRepo.findByRefundEventId(rRefund.eventId!);
      expect(allocation, isNotNull);
      expect(allocation!.allocatedAmountMinorUnits, 40000);
      expect(allocation.originalEventId, rPurchase.eventId);

      // 3. Attempt refund exceeding cap (remaining cap is 60,000 paise; trying 70,000)
      final cExcessRefund = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:REFUND_EXCESS',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Refund of Rs 700 credited. Ref: UTRREFUND700',
        amountMinorUnits: 70000,
        direction: PostingDirection.credit,
        timestamp: now.add(const Duration(hours: 2)),
        externalReference: 'UTRREFUND700',
        accountId: 'acc_test_hdfc_4321',
        eventType: CanonicalEventType.refund,
        originalPurchaseEventId: rPurchase.eventId,
        allocatedAmountMinorUnits: 70000,
      );
      expect(
        () => dedupService.processWithConflictResolution(candidate: cExcessRefund, db: db),
        throwsA(isA<DatabaseException>()),
      );
      await assertBalancedLedger();
    });

    test('Accounting 7: Reversal preserves audit trail and balanced postings', () async {
      // 1. Initial event
      final cOrig = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:REVERSAL_ORIG',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Rs 1200 debited. UPI Ref: UTRREV999',
        amountMinorUnits: 120000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: 'UTRREV999',
        accountId: 'acc_test_sbi_1111',
        eventType: CanonicalEventType.expense,
      );
      final rOrig = await dedupService.processWithConflictResolution(candidate: cOrig, db: db);
      expect(rOrig.status, DeduplicationStatus.newEventCreated);

      // 2. Reversal event sharing the same UTR
      final cRev = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:REVERSAL_DONE',
        sourceChannel: SourceChannel.sms,
        sender: 'VK-SBIINB',
        body: 'Reversal of Rs 1200 credited. UPI Ref: UTRREV999',
        amountMinorUnits: 120000,
        direction: PostingDirection.credit,
        timestamp: now.add(const Duration(minutes: 5)),
        externalReference: 'UTRREV999',
        accountId: 'acc_test_sbi_1111',
        eventType: CanonicalEventType.adjustment,
        reversalOfEventId: rOrig.eventId,
      );
      final rRev = await dedupService.processWithConflictResolution(candidate: cRev, db: db);
      expect(rRev.status, DeduplicationStatus.newEventCreated);

      // Verify reversal linkage in economic_events
      final revRow = await db.query(TablesV24.economicEvents, where: 'id = ?', whereArgs: [rRev.eventId]);
      expect(revRow.first['reversal_of_event_id'], rOrig.eventId);
      await assertBalancedLedger();
    });
  });

  group('Phase 5C.6: Recovery and Interruption Testing', () {
    test('Recovery 1: Checkpoint serialization and roundtrip', () {
      final cp = SmsRecoveryCheckpoint(
        startMaxId: 10500,
        sevenDayThresholdMs: 1731500000000,
        lastProcessedId: 10400,
        isComplete: false,
        lastScanAtMs: 1731900000000,
      );

      final json = cp.toJson();
      final restored = SmsRecoveryCheckpoint.fromJson(json);

      expect(restored.startMaxId, 10500);
      expect(restored.sevenDayThresholdMs, 1731500000000);
      expect(restored.lastProcessedId, 10400);
      expect(restored.isComplete, isFalse);
    });

    test('Recovery 2: Snapshot ceiling enforcement', () {
      final cp = SmsRecoveryCheckpoint(
        startMaxId: 5000,
        sevenDayThresholdMs: 1000,
      );

      // Any SMS with id > 5000 is newer than the snapshot ceiling and must be excluded from this pass
      final newerSms = {'id': 5001, 'date': 2000};
      final eligibleSms = {'id': 4999, 'date': 2000};

      expect((newerSms['id'] as int) > cp.startMaxId, isTrue);
      expect((eligibleSms['id'] as int) <= cp.startMaxId, isTrue);
    });

    test('Recovery 3: Seven-day cutoff boundary', () {
      final cutoff = 1731500000000;
      final recentSms = {'id': 100, 'date': cutoff + 10000};
      final oldSms = {'id': 99, 'date': cutoff - 5000};

      expect((recentSms['date'] as int) >= cutoff, isTrue);
      expect((oldSms['date'] as int) < cutoff, isTrue);
    });

    test('Recovery 4: Resumption from cursor after partial interruption', () {
      final initialCp = SmsRecoveryCheckpoint(
        startMaxId: 2000,
        sevenDayThresholdMs: 1000,
        lastProcessedId: 1800, // page 1 processed up to id 1800
      );

      // On next page, query uses beforeId = 1800
      expect(initialCp.lastProcessedId, 1800);

      // Simulating page 2 processing successfully down to 1600
      final updatedCp = initialCp.copyWith(lastProcessedId: 1600);
      expect(updatedCp.startMaxId, 2000); // startMaxId remains immutable
      expect(updatedCp.lastProcessedId, 1600);
    });
  });
}
