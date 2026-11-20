import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/transaction.dart' as m_tx;
import 'package:spend_x/domain/finance/economic_event.dart';
import 'package:spend_x/domain/finance/posting.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/live_sms_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;
  late String dbPath;
  late Database db;

  const mockChannel = MethodChannel('spendx/sms_live');
  final List<String> removedPendingIds = [];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (MethodCall methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      mockChannel,
      (MethodCall methodCall) async {
        if (methodCall.method == 'removePendingSms') {
          final ids = (methodCall.arguments as Map)['sourceRecordIds'] as List;
          removedPendingIds.addAll(ids.cast<String>());
          return true;
        }
        if (methodCall.method == 'clearPendingSms') {
          return true;
        }
        return null;
      },
    );
  });

  setUp(() async {
    removedPendingIds.clear();
    SharedPreferences.setMockInitialValues({});
    testDir = await Directory.systemTemp.createTemp('spendx_tagged_test_');
    dbPath = p.join(testDir.path, 'tagged_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    db = await AppDatabase.instance.database;
    await CategoryRepo(executor: db).ensureDefaults();
    await LiveSmsService.instance.clearDurableQuarantineForTesting();

    // Seed test bank accounts and credit cards
    final sbi = BankAccount(
      name: 'State Bank of India',
      bank: 'SBI',
      last4: '1111',
      accountType: 'savings',
      balance: 0.0,
    );
    await AccountRepo().insertAccount(sbi);

    final hdfc = BankAccount(
      name: 'HDFC Bank Account',
      bank: 'HDFC',
      last4: '2222',
      accountType: 'savings',
      balance: 0.0,
    );
    await AccountRepo().insertAccount(hdfc);

    final regalia = CreditCard(
      name: 'HDFC Regalia',
      bank: 'HDFC',
      last4: '6366',
      limitAmount: 150000.0,
      usedAmount: 0.0,
      dueDay: 15,
      billingDay: 25,
    );
    await CreditRepo().insert(regalia);
  });

  tearDown(() async {
    try {
      await AppDatabase.instance.close();
    } catch (_) {}
    AppDatabase.setTestDatabasePath(null);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    try {
      if (testDir.existsSync()) {
        await testDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Phase 1.4 Tagged Ingestion Attribution Remediation Tests', () {
    test('1. Tagged bank debit posts against the correct bank asset', () async {
      const sender = 'VM-SBIINB';
      const body = 'Your A/C ending 1111 is debited for Rs. 500.00 on 19-Nov-26 at Swiggy. Ref: UPI/632412345678';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763560000000:a1b2c3d4';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isTrue);

      // Verify Economic Event
      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);
      final ev = events.first;
      expect(ev['event_type'], 'expense');

      // Verify Postings: Bank Asset credited (reducing balance), Category debited
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [ev['id']],
        orderBy: 'sequence_number ASC',
      );
      expect(postings.length, 2);

      // Debit leg (Expense category)
      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      expect(debitLeg['amount_minor_units'], 50000);
      expect(debitLeg['account_id'], isNot(equals('acc_cash_default')));

      // Credit leg (Bank Asset)
      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      expect(creditLeg['amount_minor_units'], 50000);
      final accounts = await AccountRepo().getAll();
      final sbiAcc = accounts.firstWhere((a) => a.last4 == '1111');
      expect(creditLeg['account_id'], equals(sbiAcc.id));
      expect(creditLeg['account_id'], isNot(equals('acc_cash_default')));
    });

    test('2. Tagged bank credit posts against the correct bank asset and income category', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Rs 15,000.00 credited to your A/c ending 2222 on 19-Nov-26 towards Salary. Ref: UPI/778899123456';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763561000000:b2c3d4e5';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isTrue);

      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);
      final ev = events.first;
      expect(ev['event_type'], 'income');

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [ev['id']],
      );
      expect(postings.length, 2);

      // For income: Bank Asset is DEBITED (asset increased), Category is CREDITED
      final accounts = await AccountRepo().getAll();
      final hdfcAcc = accounts.firstWhere((a) => a.last4 == '2222');

      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      expect(debitLeg['account_id'], equals(hdfcAcc.id));
      expect(debitLeg['amount_minor_units'], 1500000);

      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      expect(creditLeg['amount_minor_units'], 1500000);
      expect(creditLeg['account_id'], isNot(equals('acc_cash_default')));
    });

    test('3. Tagged credit-card purchase posts against the correct card liability', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Alert: Rs 2,499.00 spent on your HDFC Bank Card ending 6366 at Amazon on 19-Nov-26.';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763562000000:c3d4e5f6';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isTrue);

      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);
      final ev = events.first;
      expect(ev['event_type'], 'credit_purchase');

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [ev['id']],
      );
      expect(postings.length, 2);

      final cards = await CreditRepo().getAll();
      final regaliaCard = cards.firstWhere((c) => c.last4 == '6366');

      // Credit purchase: Card Liability is CREDITED (liability increased), Expense Category is DEBITED
      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      expect(creditLeg['account_id'], equals(regaliaCard.id));
      expect(creditLeg['amount_minor_units'], 249900);

      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      expect(debitLeg['amount_minor_units'], 249900);
      expect(debitLeg['account_id'], isNot(equals('acc_cash_default')));
    });

    test('4. Tagged card payment settles the liability against the paying bank account', () async {
      const sender = 'VM-HDFCBK';
      const body = 'Thank you for payment of Rs 5,000.00 towards your HDFC Credit Card 6366 from A/c 2222 on 19-Nov-26.';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763563000000:d4e5f6a1';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isTrue);

      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);
      final ev = events.first;
      expect(ev['event_type'], 'liability_settlement');

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [ev['id']],
      );
      expect(postings.length, 2);

      final accounts = await AccountRepo().getAll();
      final hdfcAcc = accounts.firstWhere((a) => a.last4 == '2222');
      final cards = await CreditRepo().getAll();
      final regaliaCard = cards.firstWhere((c) => c.last4 == '6366');

      // Card payment: Card Liability is DEBITED (liability decreased), Paying Bank Asset is CREDITED (asset decreased)
      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      expect(debitLeg['account_id'], equals(regaliaCard.id));
      expect(debitLeg['amount_minor_units'], 500000);

      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      expect(creditLeg['account_id'], equals(hdfcAcc.id));
      expect(creditLeg['amount_minor_units'], 500000);
    });

    test('5. Ambiguous instrument attribution goes to Review Queue', () async {
      // Create a second bank account with duplicate last4 to induce genuine ambiguity
      final sbi2 = BankAccount(
        name: 'SBI Joint Account',
        bank: 'SBI',
        last4: '1111',
        accountType: 'savings',
        balance: 0.0,
      );
      await AccountRepo().insertAccount(sbi2);

      const sender = 'VM-SBIINB';
      const body = 'Rs 750.00 debited from your A/C ending 1111 at Coffee Day on 19-Nov-26.';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763564000000:e5f6a1b2';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      // Not added as posted transaction
      expect(res.added, isFalse);

      // Zero posted economic events
      final postedEvents = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(postedEvents.length, 0);

      // Zero postings created
      final allPostings = await db.query(TablesV24.postings);
      expect(allPostings.length, 0);

      // Candidate safely staged in review_candidates with evidence
      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      expect(candidates.first['suggested_amount_minor_units'], 75000);

      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 1);
      expect(evidence.first['economic_event_id'], isNull);
    });

    test('6. Two identical legitimate transactions remain separate when source identities establish they are distinct', () async {
      const sender = 'VM-METRO';
      const body = 'Rs 40.00 debited from A/c ending 1111 for Metro travel ticket.';
      const sourceId1 = 'SRC:TELEPHONY_BROADCAST:0:1763565000000:f6a1b2c3';
      const sourceId2 = 'SRC:TELEPHONY_BROADCAST:0:1763565120000:a1b2c3d4'; // 2 mins later

      final res1 = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId1,
      );
      final res2 = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId2,
      );

      expect(res1.added, isTrue);
      expect(res2.added, isTrue);

      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 2);

      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 2);
    });

    test('7. Broadcast and inbox representations of one SMS do not create two economic events', () async {
      const sender = 'VM-SBIINB';
      const body = 'Debited Rs 1,200.00 from A/c 1111 at Flipkart on 19-Nov UPI/556677889900.';
      const broadcastSourceId = 'SRC:TELEPHONY_BROADCAST:0:1763566000000:11223344';
      const inboxSourceId = 'SRC:TELEPHONY_SMS:9988';

      // 1. Ingest live broadcast
      final res1 = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: broadcastSourceId,
      );
      expect(res1.added, isTrue);

      // 2. Ingest same message via inbox scanner catch-up
      final res2 = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: inboxSourceId,
      );
      expect(res2.added, isFalse);

      // Exactly 1 posted economic event
      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);

      // Both evidence records linked to that single event
      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 2);
      expect(evidence[0]['economic_event_id'], equals(events.first['id']));
      expect(evidence[1]['economic_event_id'], equals(events.first['id']));
    });

    test('8. Repeated notification delivery does not create duplicate economic events', () async {
      const sender = 'APP:com.phonepe.app:PhonePe';
      const body = 'Paid ₹350 to Starbucks on PhonePe';
      const notifSourceId = 'SRC:ANDROID_NOTIF:com.phonepe.app:88::1763567000000';

      final res1 = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: notifSourceId,
      );
      expect(res1.added, isTrue);

      // Redeliver identical notification (e.g. service reconnection)
      final res2 = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: notifSourceId,
      );
      expect(res2.added, isFalse);

      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);
      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 1);
    });

    test('9. SMS and push evidence for the same transaction are linked only when sufficient evidence exists', () async {
      const utr = '889900112233';
      const pushSender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const pushBody = 'Paid ₹400 to Dominos. UPI Ref $utr';
      const pushSourceId = 'SRC:ANDROID_NOTIF:com.google.android.apps.nbu.paisa.user:101::1763568000000';

      const bankSender = 'VM-HDFCBK';
      const bankBody = 'Rs 400.00 debited from A/c 2222 at Dominos UPI/$utr';
      const bankSourceId = 'SRC:TELEPHONY_BROADCAST:0:1763568005000:55667788';

      final res1 = await LiveSmsService.instance.testProcessBody(
        pushBody,
        sender: pushSender,
        sourceRecordId: pushSourceId,
      );
      expect(res1.added, isTrue);

      final res2 = await LiveSmsService.instance.testProcessBody(
        bankBody,
        sender: bankSender,
        sourceRecordId: bankSourceId,
      );
      expect(res2.added, isFalse);

      // Exactly 1 economic event created
      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);

      // Both push and bank evidence linked to event
      final evidence = await db.query(TablesV24.evidence);
      expect(evidence.length, 2);
      expect(evidence[0]['economic_event_id'], equals(events.first['id']));
      expect(evidence[1]['economic_event_id'], equals(events.first['id']));
    });

    test('10. Partial queue failures do not repost successful items or lose failed items', () async {
      // Set up a mock where item 1 succeeds, item 2 fails transiently
      const source1 = 'SRC:TELEPHONY_BROADCAST:0:1763569000000:success01';
      const source2 = 'SRC:TELEPHONY_BROADCAST:0:1763569001000:fail02';

      var callCount = 0;
      LiveSmsService.testProcessBodyInterceptor = (sender, body) async {
        callCount++;
        if (body.contains('FAIL_TRIGGER')) {
          throw const FileSystemException('database is locked');
        }
      };

      try {
        LiveSmsService.instance.addLiveBufferForTesting(
          'VM-SBIINB',
          'Rs 100 debited from A/c 1111 at Tea Stall.',
          source1,
        );
        LiveSmsService.instance.addLiveBufferForTesting(
          'VM-SBIINB',
          'FAIL_TRIGGER: Rs 200 debited from A/c 1111.',
          source2,
        );

        await LiveSmsService.instance.flushLiveBufferForTesting();

        // Item 1 succeeded and created event
        final events = await db.query(
          TablesV24.economicEvents,
          where: 'lifecycle_status = ?',
          whereArgs: ['posted'],
        );
        expect(events.length, 1);

        // Item 2 failed transiently and remains in live buffer for retry
        expect(LiveSmsService.instance.bufferCountForTesting, 1);
        expect(LiveSmsService.instance.getFailureCountForTesting(source2), 1);

        // Second pass: item 1 is NOT in buffer; item 2 now succeeds
        LiveSmsService.testProcessBodyInterceptor = null;
        await LiveSmsService.instance.flushLiveBufferForTesting();

        // Buffer now empty
        expect(LiveSmsService.instance.bufferCountForTesting, 0);

        // Total 2 events (one for item 1, one for item 2; ZERO duplicates of item 1)
        expect(callCount, greaterThanOrEqualTo(2));
        final finalEvents = await db.query(
          TablesV24.economicEvents,
          where: 'lifecycle_status = ?',
          whereArgs: ['posted'],
        );
        expect(finalEvents.length, 2);
      } finally {
        LiveSmsService.testProcessBodyInterceptor = null;
        LiveSmsService.instance.clearLiveBufferForTesting();
      }
    });

    test('11. Unattributed financial SMS (missing bank name and last4) results in Review Queue', () async {
      const sender = 'VM-BANKTX';
      const body = 'Rs 150.00 debited at Local Bakery on 19-Nov-26.'; // No bank name, no last4
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763570000000:unatt01';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isFalse);

      // Zero posted economic events
      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 0);

      // Zero ledger postings
      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);

      // Candidate safely staged in review_candidates with UNRESOLVED_INSTRUMENT reason
      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      expect(candidates.first['raw_payload'], contains('UNRESOLVED_INSTRUMENT'));
    });

    test('12. Unknown instrument does not create an acc_cash_default posting', () async {
      const sender = 'VM-UNKNOWN';
      const body = 'Debited Rs 320.00 from Account XX9999 at Store on 19-Nov-26.'; // 9999 does not exist
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763571000000:unatt02';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isFalse);

      // Zero postings to acc_cash_default
      final cashPostings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: ['acc_cash_default'],
      );
      expect(cashPostings, isEmpty);

      // Zero total postings
      final allPostings = await db.query(TablesV24.postings);
      expect(allPostings, isEmpty);
    });

    test('13. Explicit manual cash entry still works and posts to acc_cash_default', () async {
      final cats = await CategoryRepo(executor: db).getAll();
      final foodCat = cats.first;

      final manualTx = m_tx.Transaction(
        id: 'manual_cash_01',
        amount: 150.0,
        userId: 'offline_user',
        type: 'expense',
        accountId: 'acc_cash_default',
        categoryId: foodCat.id,
        notes: 'Coffee with friends',
        date: DateTime.now(),
      );

      await FinancialTransactionService().createTransaction(manualTx);

      final events = await db.query(
        TablesV24.economicEvents,
        where: 'lifecycle_status = ?',
        whereArgs: ['posted'],
      );
      expect(events.length, 1);

      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 2);

      final debit = postings.firstWhere((p) => p['direction'] == 'debit');
      expect(debit['account_id'], foodCat.id);
      expect(debit['amount_minor_units'], 15000);

      final credit = postings.firstWhere((p) => p['direction'] == 'credit');
      expect(credit['account_id'], 'acc_cash_default');
      expect(credit['amount_minor_units'], 15000);
    });

    test('14. Two genuine identical purchases within 60 seconds with distinct references are preserved as separate events', () async {
      final now = DateTime.now();
      final candidate1 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_BROADCAST:0:1763572000000:tx1',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-SBIINB',
        body: 'Rs 20 debited from A/c 1111 for Metro Ticket. UTR 111122223331',
        amountMinorUnits: 2000,
        direction: PostingDirection.debit,
        timestamp: now,
        externalReference: '111122223331',
        accountNumberLast4: '1111',
        accountId: 'acc_sbi_1111',
        counterpartyAccountId: 'cat_transport',
        eventType: CanonicalEventType.expense,
      );

      final candidate2 = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_BROADCAST:0:1763572030000:tx2',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-SBIINB',
        body: 'Rs 20 debited from A/c 1111 for Metro Ticket. UTR 111122223332',
        amountMinorUnits: 2000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 30)),
        externalReference: '111122223332',
        accountNumberLast4: '1111',
        accountId: 'acc_sbi_1111',
        counterpartyAccountId: 'cat_transport',
        eventType: CanonicalEventType.expense,
      );

      final res1 = await CrossChannelDeduplicationService().processWithConflictResolution(
        candidate: candidate1,
        db: db,
      );
      final res2 = await CrossChannelDeduplicationService().processWithConflictResolution(
        candidate: candidate2,
        db: db,
      );

      expect(res1.isNewEventCreated, isTrue);
      expect(res2.isNewEventCreated, isTrue);
      expect(res1.eventId, isNot(equals(res2.eventId)));

      final events = await db.query(TablesV24.economicEvents, where: 'lifecycle_status = ?', whereArgs: ['posted']);
      expect(events.length, 2);
    });

    test('15. Unreferenced cross-channel SMS and push pair with matching attributes routes to Review Queue (no auto-merge)', () async {
      final now = DateTime.now();

      final smsCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_BROADCAST:0:1763573000000:unrefSms',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-SBIINB',
        body: 'Your A/C 1111 is debited for Rs 500 at Cafe.',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now,
        accountNumberLast4: '1111',
        accountId: 'acc_sbi_1111',
        counterpartyAccountId: 'cat_food',
        eventType: CanonicalEventType.expense,
      );

      final pushCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.phonepe.app:99::1763573005000',
        sourceChannel: SourceChannel.push,
        sender: 'APP:com.phonepe.app',
        body: 'Paid Rs 500 to Cafe.',
        amountMinorUnits: 50000,
        direction: PostingDirection.debit,
        timestamp: now.add(const Duration(seconds: 5)),
        accountNumberLast4: '1111',
        accountId: 'acc_sbi_1111',
        counterpartyAccountId: 'cat_food',
        eventType: CanonicalEventType.expense,
      );

      final res1 = await CrossChannelDeduplicationService().processWithConflictResolution(
        candidate: smsCandidate,
        db: db,
      );
      expect(res1.isNewEventCreated, isTrue);

      final res2 = await CrossChannelDeduplicationService().processWithConflictResolution(
        candidate: pushCandidate,
        db: db,
      );

      // Must NOT auto-merge! Must route to Review Queue
      expect(res2.isRoutedToReviewQueue, isTrue);
      expect(res2.reviewReason, 'CROSS_CHANNEL_UNREFERENCED_ACCOUNT_MATCH');

      // Ledger still has exactly 1 event
      final events = await db.query(TablesV24.economicEvents, where: 'lifecycle_status = ?', whereArgs: ['posted']);
      expect(events.length, 1);
    });

    test('16. Bank refund posts Debit: Bank Asset, Credit: Expense Category with balanced paise', () async {
      // 1. Seed original purchase: ₹450 debit at Swiggy
      const origSender = 'VM-SBIINB';
      const origBody = 'Rs 450.00 debited from A/c 1111 at Swiggy on 19-Nov-26. Ref: UPI/888899990000';
      const origSourceId = 'SRC:TELEPHONY_BROADCAST:0:1763573900000:origSwiggy';
      final origRes = await LiveSmsService.instance.testProcessBody(
        origBody,
        sender: origSender,
        sourceRecordId: origSourceId,
      );
      expect(origRes.added, isTrue);

      // 2. Ingest bank refund referencing the same transaction
      const sender = 'VM-SBIINB';
      const body = 'Your A/c ending 1111 is credited with Rs 450.00 on 19-Nov-26 by Refund Swiggy. Ref: UPI/888899990000';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763574000000:refundBank';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isTrue);

      final refundEvents = await db.query(
        TablesV24.economicEvents,
        where: 'event_type = ? AND lifecycle_status = ?',
        whereArgs: ['refund', 'posted'],
      );
      expect(refundEvents.length, 1);
      final refundEventId = refundEvents.first['id'];

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [refundEventId],
      );
      expect(postings.length, 2);

      // Persisted Postings Assertions:
      final debit = postings.firstWhere((p) => p['direction'] == 'debit');
      final credit = postings.firstWhere((p) => p['direction'] == 'credit');

      expect(debit['amount_minor_units'], 45000);
      expect(credit['amount_minor_units'], 45000);
      expect(debit['amount_minor_units'], equals(credit['amount_minor_units']));

      final accounts = await AccountRepo().getAll();
      final sbiAcc = accounts.firstWhere((a) => a.last4 == '1111');

      // Debit leg: Bank Asset
      expect(debit['account_id'], sbiAcc.id);
      final debitAcc = await db.query(TablesV24.accounts, where: 'id = ?', whereArgs: [debit['account_id']]);
      expect(debitAcc.first['account_type'], 'asset');

      // Credit leg: Expense Category
      final creditAcc = await db.query(TablesV24.accounts, where: 'id = ?', whereArgs: [credit['account_id']]);
      expect(creditAcc.first['account_type'], 'expense');
    });

    test('17. Credit-card refund posts Debit: Card Liability, Credit: Expense Category with balanced paise', () async {
      // 1. Seed original credit card purchase: ₹1,200 at Amazon
      const origSender = 'HDFCBK';
      const origBody = 'Spent Rs. 1,200.00 on your HDFC Bank Credit Card ending 6366 at Amazon on 19-Nov-26. Ref: UPI/999888777666';
      const origSourceId = 'SRC:TELEPHONY_BROADCAST:0:1763574900000:origAmz';
      final origRes = await LiveSmsService.instance.testProcessBody(
        origBody,
        sender: origSender,
        sourceRecordId: origSourceId,
      );
      expect(origRes.added, isTrue);

      // 2. Ingest credit card refund referencing the same transaction
      const sender = 'HDFCBK';
      const body = 'Refund of Rs. 1,200.00 credited to your HDFC Bank Credit Card ending 6366 on 19-Nov-26 from Amazon. Ref: UPI/999888777666';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763575000000:refundCc';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isTrue);

      final refundEvents = await db.query(
        TablesV24.economicEvents,
        where: 'event_type = ? AND lifecycle_status = ?',
        whereArgs: ['refund', 'posted'],
      );
      expect(refundEvents.length, 1);
      final refundEventId = refundEvents.first['id'];

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [refundEventId],
      );
      expect(postings.length, 2);

      final debit = postings.firstWhere((p) => p['direction'] == 'debit');
      final credit = postings.firstWhere((p) => p['direction'] == 'credit');

      expect(debit['amount_minor_units'], 120000);
      expect(credit['amount_minor_units'], 120000);
      expect(debit['amount_minor_units'], equals(credit['amount_minor_units']));

      final cards = await CreditRepo().getAll();
      final regalia = cards.firstWhere((c) => c.last4 == '6366');

      // Debit leg: Credit-Card Liability
      expect(debit['account_id'], regalia.id);
      final debitAcc = await db.query(TablesV24.accounts, where: 'id = ?', whereArgs: [debit['account_id']]);
      expect(debitAcc.first['account_type'], 'liability');

      // Credit leg: Expense Category
      final creditAcc = await db.query(TablesV24.accounts, where: 'id = ?', whereArgs: [credit['account_id']]);
      expect(creditAcc.first['account_type'], 'expense');
    });

    test('18. Unsupported/future event type fails closed to Review Queue with zero postings', () async {
      final accounts = await AccountRepo().getAll();
      final sbiAcc = accounts.firstWhere((a) => a.last4 == '1111');

      final candidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_BROADCAST:0:1763576000000:unsupported',
        sourceChannel: SourceChannel.sms,
        sender: 'VM-BANK',
        body: 'Capital adjustment note.',
        amountMinorUnits: 100000,
        direction: PostingDirection.debit,
        timestamp: DateTime.now(),
        accountNumberLast4: '1111',
        accountId: sbiAcc.id,
        counterpartyAccountId: 'acc_equity',
        eventType: CanonicalEventType.adjustment, // Unsupported in live ingestion
      );

      final res = await CrossChannelDeduplicationService().processWithConflictResolution(
        candidate: candidate,
        db: db,
      );

      expect(res.isRoutedToReviewQueue, isTrue);
      expect(res.reviewReason, 'UNSUPPORTED_EVENT_TYPE');

      // Zero posted events
      final events = await db.query(TablesV24.economicEvents, where: 'lifecycle_status = ?', whereArgs: ['posted']);
      expect(events, isEmpty);

      // Zero postings
      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);
    });

    test('19. Credit-card payment with missing paying bank routes to Review Queue with no ledger postings', () async {
      const sender = 'HDFCBK';
      const body = 'Payment of Rs 5000.00 received towards your HDFC Credit Card 6366 on 19-Nov-26.';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763577000000:noPayingBank';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isFalse);

      final events = await db.query(TablesV24.economicEvents, where: 'lifecycle_status = ?', whereArgs: ['posted']);
      expect(events, isEmpty);

      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);

      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      expect(candidates.first['raw_payload'], contains('UNRESOLVED_PAYING_BANK'));
    });

    test('20. Credit-card payment with missing target card routes to Review Queue with no ledger postings', () async {
      const sender = 'VM-SBIINB';
      const body = 'Rs 4000.00 debited from a/c 1111 towards Credit Card 9999 bill on 19-Nov-26.';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763578000000:noTargetCard';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isFalse);

      final events = await db.query(TablesV24.economicEvents, where: 'lifecycle_status = ?', whereArgs: ['posted']);
      expect(events, isEmpty);

      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);

      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      expect(candidates.first['raw_payload'], contains('UNRESOLVED_TARGET_CARD'));
    });

    test('21. Credit-card payment with multiple matching cards routes to Review Queue with no ledger postings', () async {
      // Insert a second card with duplicate last4 6366 to induce ambiguity
      final regalia2 = CreditCard(
        name: 'HDFC Business Regalia',
        bank: 'HDFC',
        last4: '6366',
        limitAmount: 200000.0,
        usedAmount: 0.0,
        dueDay: 20,
        billingDay: 5,
      );
      await CreditRepo().insert(regalia2);

      const sender = 'HDFCBK';
      const body = 'Payment of Rs 3000.00 debited from a/c 1111 received towards your HDFC Credit Card 6366 on 19-Nov-26.';
      const sourceId = 'SRC:TELEPHONY_BROADCAST:0:1763579000000:multiCard';

      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: sender,
        sourceRecordId: sourceId,
      );

      expect(res.added, isFalse);

      final events = await db.query(TablesV24.economicEvents, where: 'lifecycle_status = ?', whereArgs: ['posted']);
      expect(events, isEmpty);

      final postings = await db.query(TablesV24.postings);
      expect(postings, isEmpty);

      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      expect(candidates.first['raw_payload'], contains('UNRESOLVED_TARGET_CARD'));
    });
  });
}
