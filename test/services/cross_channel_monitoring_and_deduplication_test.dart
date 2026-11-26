import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/repositories/refund_allocations_repo.dart';
import 'package:spend_x/domain/finance/posting.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
import 'package:spend_x/services/cross_channel_monitoring_service.dart';
import 'package:spend_x/services/entity_consolidation_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory tempDir;
  late String dbPath;
  late Database db;
  late CrossChannelDeduplicationService dedupService;
  late RefundAllocationsRepo refundRepo;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_cross_monitor_test_');
    dbPath = p.join(tempDir.path, 'cross_monitor_test.db');

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
      'id': 'acc_hdfc_4545',
      'account_type': 'asset',
      'subtype': 'savings',
      'name': 'HDFC Bank A/c 4545',
      'account_number_last4': '4545',
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

  group('Cross-Channel SMS, Push & Email Tri-Stream Merging', () {
    test('SMS, Google Pay Notification, and Gmail Email sharing UTR merge into 1 event with 3 evidences', () async {
      final now = DateTime.now().toUtc();
      const utr = '432987123456';

      // 1. Telephony SMS arrives
      final smsCandidate = IncomingTransactionCandidate(
        sourceRecordId: CrossChannelDeduplicationService.buildSmsSourceId(101),
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Debited Rs. 850.00 from HDFC Bank A/c 4545 to SWIGGY UPI/$utr',
        amountMinorUnits: 85000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: utr,
        accountId: 'acc_hdfc_4545',
        merchant: 'SWIGGY',
      );

      final res1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: smsCandidate,
            txn: txn,
          ));

      expect(res1.status, DeduplicationStatus.newEventCreated);
      final eventId = res1.eventId!;

      // 2. Google Pay push notification arrives for the same spend
      final pushCandidate = IncomingTransactionCandidate(
        sourceRecordId: CrossChannelDeduplicationService.buildPushSourceId(
          'com.google.android.apps.nbu.paisa.user',
          202,
          'txn_alert',
          now.millisecondsSinceEpoch,
        ),
        sourceChannel: SourceChannel.push,
        sender: 'APP:com.google.android.apps.nbu.paisa.user:Google Pay',
        body: 'Paid ₹850 to Swiggy. UPI Ref: $utr',
        amountMinorUnits: 85000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 3)),
        externalReference: utr,
        merchant: 'Swiggy',
      );

      final res2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: pushCandidate,
            txn: txn,
          ));

      expect(res2.status, DeduplicationStatus.strongMatchMerged);
      expect(res2.eventId, eventId);

      // 3. Gmail order confirmation email arrives
      final emailCandidate = IncomingTransactionCandidate(
        sourceRecordId: CrossChannelDeduplicationService.buildEmailSourceId('msg_gmail_999'),
        sourceChannel: SourceChannel.email,
        sender: 'APP:com.google.android.gm:alerts@hdfcbank.net',
        body: 'HDFC Bank Alert: Transaction of INR 850.00 at SWIGGY, Ref: $utr',
        amountMinorUnits: 85000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 15)),
        externalReference: utr,
        merchant: 'Swiggy',
      );

      final res3 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: emailCandidate,
            txn: txn,
          ));

      expect(res3.status, DeduplicationStatus.strongMatchMerged);
      expect(res3.eventId, eventId);

      // Verify canonical event count in DB: EXACTLY 1 event exists
      final allEvents = await db.query(TablesV24.economicEvents);
      expect(allEvents.length, 1);
      expect(allEvents.first['id'], eventId);

      // Verify evidence count: EXACTLY 3 linked source evidences
      final linkedEvidence = await db.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: [eventId],
      );
      expect(linkedEvidence.length, 3);

      final sourceIds = linkedEvidence.map((e) => e['source_record_id']).toSet();
      expect(sourceIds, contains(smsCandidate.sourceRecordId));
      expect(sourceIds, contains(pushCandidate.sourceRecordId));
      expect(sourceIds, contains(emailCandidate.sourceRecordId));

      // Verify postings: EXACTLY 2 legs (1 debit expense, 1 credit bank account)
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [eventId],
      );
      expect(postings.length, 2);
    });

    test('Merchant confirmation duplicate matching merges SMS and merchant email without UTR', () async {
      final now = DateTime.now().toUtc();

      // 1. Bank SMS with card spend at Zomato (no UTR)
      final smsCandidate = IncomingTransactionCandidate(
        sourceRecordId: CrossChannelDeduplicationService.buildSmsSourceId(303),
        sourceChannel: SourceChannel.sms,
        sender: 'VM-HDFCBK',
        body: 'Spent Rs. 450.00 on HDFC Card at ZOMATO on 26-Nov',
        amountMinorUnits: 45000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountId: 'acc_hdfc_4545',
        merchant: 'ZOMATO',
      );

      final res1 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: smsCandidate,
            txn: txn,
          ));
      expect(res1.status, DeduplicationStatus.newEventCreated);
      final eventId = res1.eventId!;

      // 2. Email confirmation with booking confirmed signal
      final emailCandidate = IncomingTransactionCandidate(
        sourceRecordId: CrossChannelDeduplicationService.buildEmailSourceId('email_zomato_1'),
        sourceChannel: SourceChannel.email,
        sender: 'APP:com.google.android.gm:order@zomato.com',
        body: 'Order confirmed! Payment of Rs 450 for your Zomato order',
        amountMinorUnits: 45000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(minutes: 1)),
        merchant: 'Zomato',
      );

      final res2 = await db.transaction((txn) => dedupService.processIncomingCandidate(
            candidate: emailCandidate,
            txn: txn,
          ));

      expect(res2.status, DeduplicationStatus.strongMatchMerged);
      expect(res2.eventId, eventId);

      // Exactly 1 economic event exists
      final allEvents = await db.query(TablesV24.economicEvents);
      expect(allEvents.length, 1);
    });
  });

  group('Cross-Channel Monitoring & Self-Healing Deduplication', () {
    test('EntityConsolidationService automatically discovers and merges existing duplicate transactions', () async {
      final now = DateTime.now().toUtc();
      final nowStr = now.toIso8601String();
      const utr = '999888777666';

      // Event 1: From SMS
      final ev1Id = const Uuid().v4();
      await db.insert(TablesV24.economicEvents, {
        'id': ev1Id,
        'event_type': 'expense',
        'description': 'Expense',
        'timestamp': nowStr,
        'lifecycle_status': 'draft',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': ev1Id,
        'account_id': TablesV24.sysExpMisc,
        'direction': 'debit',
        'amount_minor_units': 120000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': ev1Id,
        'account_id': 'acc_hdfc_4545',
        'direction': 'credit',
        'amount_minor_units': 120000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [ev1Id],
      );
      await db.insert(TablesV24.evidence, {
        'id': const Uuid().v4(),
        'economic_event_id': ev1Id,
        'source_type': 'sms',
        'source_record_id': 'SRC:TELEPHONY_SMS:9001',
        'extracted_amount_minor_units': 120000,
        'extracted_timestamp': nowStr,
        'external_reference': utr,
        'body_sha256': 'hash_sms_1',
        'created_at': nowStr,
      });

      // Event 2: From Email / Notification for the same spend
      final ev2Id = const Uuid().v4();
      await db.insert(TablesV24.economicEvents, {
        'id': ev2Id,
        'event_type': 'expense',
        'description': 'Swiggy',
        'timestamp': now.add(const Duration(seconds: 10)).toIso8601String(),
        'lifecycle_status': 'draft',
        'created_at': nowStr,
        'updated_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': ev2Id,
        'account_id': TablesV24.sysExpMisc,
        'direction': 'debit',
        'amount_minor_units': 120000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.insert(TablesV24.postings, {
        'id': const Uuid().v4(),
        'economic_event_id': ev2Id,
        'account_id': 'acc_hdfc_4545',
        'direction': 'credit',
        'amount_minor_units': 120000,
        'currency': 'INR',
        'created_at': nowStr,
      });
      await db.update(
        TablesV24.economicEvents,
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [ev2Id],
      );
      await db.insert(TablesV24.evidence, {
        'id': const Uuid().v4(),
        'economic_event_id': ev2Id,
        'source_type': 'manual',
        'source_record_id': 'SRC:EMAIL:GMAIL:9002',
        'extracted_amount_minor_units': 120000,
        'extracted_timestamp': nowStr,
        'external_reference': utr,
        'body_sha256': 'hash_email_1',
        'created_at': nowStr,
      });

      // Initially, 2 active events exist
      final activeBefore = await db.query(
        TablesV24.economicEvents,
        where: "reversal_of_event_id IS NULL AND description NOT LIKE 'REVERSAL:%'",
      );
      expect(activeBefore.length, 2);

      // Run consolidation!
      final mergedCount = await EntityConsolidationService.instance.consolidate(db);
      expect(mergedCount, greaterThanOrEqualTo(1));

      // After consolidation, exactly 1 active posted event exists
      final activeAfter = await db.query(
        TablesV24.economicEvents,
        where: "lifecycle_status = 'posted' AND reversal_of_event_id IS NULL AND description NOT LIKE 'REVERSAL:%'",
      );
      expect(activeAfter.length, 1);

      // Description is enriched with "Swiggy"
      expect(activeAfter.first['description'], contains('Swiggy'));

      // Both evidences are now linked to the canonical event
      final canonicalId = activeAfter.first['id'] as String;
      final linkedEvidence = await db.query(
        TablesV24.evidence,
        where: 'economic_event_id = ?',
        whereArgs: [canonicalId],
      );
      expect(linkedEvidence.length, 2);
    });

    test('CrossChannelMonitoringService emits stats and completes cycles cleanly', () async {
      final monitor = CrossChannelMonitoringService.instance;
      expect(monitor.currentStats.isMonitoring, isFalse);

      final stats = await monitor.runCycle(reason: 'unit_test');
      expect(stats.isMonitoring, isFalse);
      expect(stats.lastMonitoredAt, isNotNull);
      expect(stats.statusMessage, isNotEmpty);
    });
  });
}
