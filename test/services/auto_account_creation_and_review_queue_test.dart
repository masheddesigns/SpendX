import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/review_repo.dart';
import 'package:spend_x/features/home/widgets/home_review_indicator.dart';
import 'package:spend_x/features/review_queue/providers/review_providers.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/screens/review/review_queue_screen.dart';
import 'package:spend_x/services/live_sms_service.dart';

void main() {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;
  late String dbPath;
  late Database db;

  final List<MethodCall> notificationCalls = [];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'),
      (MethodCall methodCall) async => 'Asia/Kolkata',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (MethodCall methodCall) async {
        notificationCalls.add(methodCall);
        switch (methodCall.method) {
          case 'initialize':
            return true;
          case 'areNotificationsEnabled':
            return true;
          default:
            return null;
        }
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('spendx/sms_live'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getPendingSms' ||
            methodCall.method == 'readInboxSince' ||
            methodCall.method == 'readAllInbox') {
          return <Map<String, dynamic>>[];
        }
        return true;
      },
    );
  });

  setUp(() async {
    notificationCalls.clear();
    SharedPreferences.setMockInitialValues({});
    testDir = await Directory.systemTemp.createTemp('spendx_auto_create_test_');
    dbPath = p.join(testDir.path, 'auto_create_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    db = await AppDatabase.instance.database;
    await CategoryRepo(executor: db).ensureDefaults();
    await LiveSmsService.instance.clearDurableQuarantineForTesting();
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    try {
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Automatic Bank/Card Account Creation and Instrument-Type Safety', () {
    test('1. Explicit bank account with existing matching bank account', () async {
      final sbi = BankAccount(
        name: 'SBI Savings',
        bank: 'SBI',
        last4: '1111',
        accountType: 'savings',
        balance: 0.0,
      );
      await AccountRepo().insertAccount(sbi);

      final result = await LiveSmsService.instance.testProcessBody(
        'INR 500.00 debited from A/C **1111 on 19-Nov-26 to Grocery. Avail Bal: INR 10,000.00.',
        sender: 'SBIINB',
        sourceRecordId: 'SRC:SMS:TEST_BANK_EXISTING_01',
      );

      expect(result.added, isTrue);

      final events = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(events.length, 1);
      expect(events.first['event_type'], 'expense');

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [events.first['id']],
      );
      expect(postings.length, 2);

      // Debit leg: Expense category
      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      expect(debitLeg['amount_minor_units'], 50000);

      // Credit leg: Bank asset account
      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      expect(creditLeg['amount_minor_units'], 50000);
      expect(creditLeg['account_id'], sbi.id);

      final cards = await CreditRepo().getAll();
      expect(cards.isEmpty, isTrue);
    });

    test('2. Explicit bank account with no matching bank account but matching credit card last4 (The ₹350 test message)', () async {
      // User has an HDFC Credit Card ending in 6366, but NO bank account ending 6366
      final hdfcCard = CreditCard(
        name: 'HDFC Bank Credit Card',
        bank: 'HDFC',
        last4: '6366',
        limitAmount: 50000.0,
        usedAmount: 0.0,
      );
      final cardId = await CreditRepo().insert(hdfcCard);

      final testMessage =
          'Dear Customer, INR 350.00 debited from A/C **6366 on 19-Nov-26 to Swiggy. Avail Bal: INR 44,650.00.';

      final result = await LiveSmsService.instance.testProcessBody(
        testMessage,
        sender: 'VM-HDFCBK',
        sourceRecordId: 'SRC:SMS:TEST_HDFC_350_BANK_01',
      );

      expect(result.added, isTrue);

      // Verify a new BankAccount was auto-created
      final accounts = await AccountRepo().getAll();
      final createdBank = accounts.where((a) => a.last4 == '6366').firstOrNull;
      expect(createdBank, isNotNull);
      expect(createdBank!.isAsset, isTrue);
      expect(createdBank.bank.toLowerCase(), contains('hdfc'));

      // Verify economic event and postings
      final events = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(events.length, 1);
      final event = events.first;
      expect(event['event_type'], 'expense');

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [event['id']],
      );
      expect(postings.length, 2);

      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');

      expect(debitLeg['amount_minor_units'], 35000);
      expect(creditLeg['amount_minor_units'], 35000);

      // Invariant: MUST be credited to Bank Asset account, NEVER to the Credit Card!
      expect(creditLeg['account_id'], createdBank.id);
      expect(creditLeg['account_id'], isNot(equals(cardId)));

      final primaryAccRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [creditLeg['account_id']],
      );
      expect(primaryAccRow.first['account_type'], 'asset');

      // 1. Account balance shown in UI (via AccountRepo().getAccounts())
      final uiAccounts = await AccountRepo().getAccounts();
      final uiAccount = uiAccounts.firstWhere((a) => a.id == createdBank.id);
      expect(uiAccount.balance, 44650.0, reason: 'UI projected balance matches reported Avail Bal: ₹44,650.00');

      // 2. Canonical ledger-derived balance
      final derivedBalance = await CanonicalAccountRepository().getDerivedBalance(createdBank.id);
      expect(derivedBalance.toRupees, 44650.0, reason: 'Canonical ledger-derived balance is ₹44,650.00');

      // 3. Postings are semantically correct
      // Expense event: Dr Expense, Cr Bank
      // Opening balance reconciliation: Dr Bank (4,500,000 paise = ₹45,000), Cr sys_equity_opening (₹45,000)
      // Net derived balance: 4,500,000 - 35,000 = 4,465,000 paise (₹44,650.00)
      final allPostings = await db.query(TablesV24.postings);
      int sumDr = 0;
      int sumCr = 0;
      for (final p in allPostings) {
        if (p['direction'] == 'debit') sumDr += (p['amount_minor_units'] as int);
        if (p['direction'] == 'credit') sumCr += (p['amount_minor_units'] as int);
      }
      expect(sumDr, sumCr, reason: 'Debit and credit totals strictly balance');
      expect(sumDr, 4535000);

      // 4. No credit card account or balance is modified
      final cardAfter = await CreditRepo().getCard(cardId);
      expect(cardAfter!.usedAmount, 0.0, reason: 'Credit card used amount remains 0.0');
      expect(cardAfter.limitAmount, 50000.0, reason: 'Credit card limit remains 50,000.0');
      final cardPostings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: [cardId],
      );
      expect(cardPostings.isEmpty, isTrue, reason: 'Credit card has 0 postings');
    });

    test('3. Explicit card with existing matching card', () async {
      final iciciCard = CreditCard(
        name: 'ICICI Sapphiro',
        bank: 'ICICI Bank',
        last4: '5007',
        limitAmount: 100000.0,
        usedAmount: 0.0,
      );
      final cardId = await CreditRepo().insert(iciciCard);

      final result = await LiveSmsService.instance.testProcessBody(
        'INR 1,200.00 spent on ICICI Bank Card ending 5007 on 19-Nov-26 at Amazon.',
        sender: 'ICICIB',
        sourceRecordId: 'SRC:SMS:TEST_CARD_EXISTING_01',
      );

      expect(result.added, isTrue);

      final events = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(events.length, 1);
      expect(events.first['event_type'], 'credit_purchase');

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [events.first['id']],
      );
      expect(postings.length, 2);

      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');

      expect(debitLeg['amount_minor_units'], 120000);
      expect(creditLeg['amount_minor_units'], 120000);
      expect(creditLeg['account_id'], cardId);

      final primaryAccRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [cardId],
      );
      expect(primaryAccRow.first['account_type'], 'liability');
    });

    test('4. Explicit card with no matching card but matching bank account last4', () async {
      // User has a bank account ending in 7777, but NO credit card ending 7777
      final axisBank = BankAccount(
        name: 'Axis Bank Savings',
        bank: 'Axis Bank',
        last4: '7777',
        accountType: 'savings',
        balance: 15000.0,
      );
      final bankId = await AccountRepo().insertAccount(axisBank);

      final result = await LiveSmsService.instance.testProcessBody(
        'INR 800.00 spent on Axis Bank Credit Card ending 7777 at Flipkart.',
        sender: 'AXISBK',
        sourceRecordId: 'SRC:SMS:TEST_CARD_AUTO_CREATE_01',
      );

      expect(result.added, isTrue);

      // Verify a new CreditCard was created
      final cards = await CreditRepo().getAll();
      final createdCard = cards.where((c) => c.last4 == '7777').firstOrNull;
      expect(createdCard, isNotNull);
      expect(createdCard!.bank.toLowerCase(), contains('axis'));

      final events = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(events.length, 1);
      expect(events.first['event_type'], 'credit_purchase');

      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [events.first['id']],
      );
      expect(postings.length, 2);

      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      expect(creditLeg['amount_minor_units'], 80000);

      // Invariant: MUST be credited to new Card Liability, NEVER to the Bank Account!
      expect(creditLeg['account_id'], createdCard.id);
      expect(creditLeg['account_id'], isNot(equals(bankId)));

      final primaryAccRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [creditLeg['account_id']],
      );
      expect(primaryAccRow.first['account_type'], 'liability');

      // 1. No invented credit limit: limitAmount is 0.0
      expect(createdCard.limitAmount, 0.0, reason: 'No credit limit invented from transaction SMS');

      // 2. Outstanding liability derived from double-entry ledger is ₹800.00
      final derivedLiability = await CreditRepo().getDerivedBalance(createdCard.id);
      expect(derivedLiability.toRupees, 800.0, reason: 'Derived liability balance is ₹800.00');

      // 3. No opening balance equity events invented for the new card
      final cardObPostings = await db.rawQuery(
        '''
        SELECT p.* FROM ${TablesV24.postings} p
        JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
        WHERE p.account_id = ? AND e.event_type = 'opening_balance'
        ''',
        [createdCard.id],
      );
      expect(cardObPostings.isEmpty, isTrue, reason: 'Zero opening balance events created for new card');

      // 4. Bank account balance remains unmodified
      final bankAfter = await AccountRepo().getById(bankId);
      expect(bankAfter!.balance, 15000.0, reason: 'Bank account balance unmodified');
    });

    test('5. Unknown issuer or insufficient identifiers — Review Queue', () async {
      // Alphanumeric notification broadcast sender with no bank name or keywords in body
      final result = await LiveSmsService.instance.testProcessBody(
        'INR 250.00 debited from A/C **8888 on 19-Nov-26.',
        sender: 'VK-NOTICE',
        sourceRecordId: 'SRC:SMS:TEST_INSUFFICIENT_IDENTIFIER_01',
      );

      // Should NOT post to ledger
      expect(result.added, isFalse);

      // Invariant: Must be routed to Review Queue with UNRESOLVED_INSTRUMENT
      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      final candidate = candidates.first;
      expect(candidate['status'], 'pending');
      final payload = jsonDecode(candidate['raw_payload'] as String);
      expect(payload['reason'], 'UNRESOLVED_INSTRUMENT');

      // No postings created
      final postings = await db.query(TablesV24.postings);
      expect(postings.isEmpty, isTrue);
    });

    test('6. Multiple possible matches — Review Queue', () async {
      // Two bank accounts share the same last 4 digits
      final hdfc1 = BankAccount(
        name: 'HDFC Savings 1',
        bank: 'HDFC Bank',
        last4: '9999',
        accountType: 'savings',
        balance: 0.0,
      );
      final hdfc2 = BankAccount(
        name: 'HDFC Savings 2',
        bank: 'HDFC Bank',
        last4: '9999',
        accountType: 'savings',
        balance: 0.0,
      );
      await AccountRepo().insertAccount(hdfc1);
      await AccountRepo().insertAccount(hdfc2);

      final result = await LiveSmsService.instance.testProcessBody(
        'INR 400.00 debited from A/C **9999 on 19-Nov-26 to Cafe.',
        sender: 'VM-HDFCBK',
        sourceRecordId: 'SRC:SMS:TEST_AMBIGUOUS_MULTIPLE_01',
      );

      expect(result.added, isFalse);

      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      final candidate = candidates.first;
      expect(candidate['status'], 'pending');
      final payload = jsonDecode(candidate['raw_payload'] as String);
      expect(payload['reason'], 'AMBIGUOUS_INSTRUMENT_ATTRIBUTION');

      final postings = await db.query(TablesV24.postings);
      expect(postings.isEmpty, isTrue);
    });

    test('7. Repeated ingestion of the same source — no duplicate account or transaction', () async {
      const sourceId = 'SRC:SMS:TEST_REPEATED_INGESTION_01';
      final msg = 'INR 500.00 debited from A/C **2222 on 19-Nov-26 to Groceries.';

      // First ingestion: auto-creates bank account and posts event
      final result1 = await LiveSmsService.instance.testProcessBody(
        msg,
        sender: 'VM-HDFCBK',
        sourceRecordId: sourceId,
      );
      expect(result1.added, isTrue);

      final accountsAfterFirst = await AccountRepo().getAll();
      final eventsAfterFirst = await db.query(TablesV24.economicEvents);
      final postingsAfterFirst = await db.query(TablesV24.postings);

      expect(accountsAfterFirst.where((a) => a.last4 == '2222').length, 1);
      expect(eventsAfterFirst.length, 1);
      expect(postingsAfterFirst.length, 2);

      // Second ingestion with the same sourceRecordId
      final result2 = await LiveSmsService.instance.testProcessBody(
        msg,
        sender: 'VM-HDFCBK',
        sourceRecordId: sourceId,
      );
      expect(result2.added, isFalse);

      final accountsAfterSecond = await AccountRepo().getAll();
      final eventsAfterSecond = await db.query(TablesV24.economicEvents);
      final postingsAfterSecond = await db.query(TablesV24.postings);

      expect(accountsAfterSecond.where((a) => a.last4 == '2222').length, 1);
      expect(eventsAfterSecond.length, 1);
      expect(postingsAfterSecond.length, 2);

      // Third ingestion with DIFFERENT sourceRecordId for the SAME newly created instrument
      final result3 = await LiveSmsService.instance.testProcessBody(
        'INR 200.00 debited from A/C **2222 on 19-Nov-26 to Coffee.',
        sender: 'VM-HDFCBK',
        sourceRecordId: 'SRC:SMS:TEST_DIFF_SOURCE_02',
      );
      expect(result3.added, isTrue);

      final accountsAfterThird = await AccountRepo().getAll();
      expect(accountsAfterThird.where((a) => a.last4 == '2222').length, 1,
          reason: 'Different source for same instrument must reuse existing account, not create duplicate');
    });

    test('7b. Concurrent ingestion cannot create duplicate accounts', () async {
      // Ingest two messages for the same unregistered instrument concurrently
      final futures = [
        LiveSmsService.instance.testProcessBody(
          'INR 100.00 debited from A/C **6677 on 19-Nov-26 to Merchant A.',
          sender: 'VM-HDFCBK',
          sourceRecordId: 'SRC:SMS:TEST_CONCURRENT_01',
        ),
        LiveSmsService.instance.testProcessBody(
          'INR 200.00 debited from A/C **6677 on 19-Nov-26 to Merchant B.',
          sender: 'VM-HDFCBK',
          sourceRecordId: 'SRC:SMS:TEST_CONCURRENT_02',
        ),
      ];

      final results = await Future.wait(futures);
      expect(results.every((r) => r.added), isTrue);

      final accounts = await AccountRepo().getAll();
      final matchingAccounts = accounts.where((a) => a.last4 == '6677').toList();
      expect(matchingAccounts.length, 1,
          reason: 'Concurrent ingestion must create exactly one account');

      final postings = await db.query(
        TablesV24.postings,
        where: 'account_id = ?',
        whereArgs: [matchingAccounts.first.id],
      );
      expect(postings.length, 2, reason: 'Both transactions posted against the single auto-created account');
    });

    test('8. Account creation failure — no orphaned or incorrectly posted transaction', () async {
      // Ingest message where bank name is completely absent and cannot be determined
      final result = await LiveSmsService.instance.testProcessBody(
        'INR 999.00 debited from A/C **4444 on 19-Nov-26.',
        sender: 'UNKNOWN_SENDER',
        sourceRecordId: 'SRC:SMS:TEST_CREATION_FAILURE_01',
      );

      expect(result.added, isFalse);

      final events = await db.query(TablesV24.economicEvents);
      expect(events.isEmpty, isTrue);

      final postings = await db.query(TablesV24.postings);
      expect(postings.isEmpty, isTrue);

      // Routed cleanly to Review Queue
      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
    });

    test('9. Correct bank asset postings invariants', () async {
      final result = await LiveSmsService.instance.testProcessBody(
        'INR 1500.00 debited from A/C **5555 on 19-Nov-26 to Utility.',
        sender: 'VM-HDFCBK',
        sourceRecordId: 'SRC:SMS:TEST_BANK_POSTINGS_01',
      );
      expect(result.added, isTrue);

      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 2);

      int totalDebit = 0;
      int totalCredit = 0;
      for (final p in postings) {
        final minor = p['amount_minor_units'] as int;
        if (p['direction'] == 'debit') totalDebit += minor;
        if (p['direction'] == 'credit') totalCredit += minor;
      }
      expect(totalDebit, 150000);
      expect(totalCredit, 150000);
      expect(totalDebit, equals(totalCredit)); // Double-entry balance invariant

      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      final accRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [creditLeg['account_id']],
      );
      expect(accRow.first['account_type'], 'asset');
    });

    test('10. Correct credit-card liability postings invariants', () async {
      final result = await LiveSmsService.instance.testProcessBody(
        'INR 2500.00 spent on ICICI Bank Card ending 3333 on 19-Nov-26 at Store.',
        sender: 'ICICIB',
        sourceRecordId: 'SRC:SMS:TEST_CARD_POSTINGS_01',
      );
      expect(result.added, isTrue);

      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 2);

      int totalDebit = 0;
      int totalCredit = 0;
      for (final p in postings) {
        final minor = p['amount_minor_units'] as int;
        if (p['direction'] == 'debit') totalDebit += minor;
        if (p['direction'] == 'credit') totalCredit += minor;
      }
      expect(totalDebit, 250000);
      expect(totalCredit, 250000);
      expect(totalDebit, equals(totalCredit));

      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');
      final accRow = await db.query(
        TablesV24.accounts,
        where: 'id = ?',
        whereArgs: [creditLeg['account_id']],
      );
      expect(accRow.first['account_type'], 'liability');
    });
  });

  group('Review Queue Visibility, Pending Count, Navigation & Notification Deduplication', () {
    test('11 & 12. Review Queue count increases when item is added and decreases when resolved', () async {
      final reviewRepo = ReviewRepo();
      final initialCount = await reviewRepo.getPendingCount();
      expect(initialCount, 0);

      // Add item to Review Queue via ambiguous transaction
      await LiveSmsService.instance.testProcessBody(
        'INR 300.00 debited from A/C **1212 on 19-Nov-26.',
        sender: 'GENERIC_ALERT',
        sourceRecordId: 'SRC:SMS:TEST_COUNT_01',
      );

      final countAfterAdd = await reviewRepo.getPendingCount();
      expect(countAfterAdd, 1);

      // Resolve the item
      final pendingItems = await reviewRepo.getPending();
      expect(pendingItems.length, 1);
      final item = pendingItems.first;

      await reviewRepo.approve(item.id);

      final countAfterResolve = await reviewRepo.getPendingCount();
      expect(countAfterResolve, 0);
    });

    testWidgets('13. Homepage indicator displays pending count and navigates to Review Queue', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            reviewQueueCountProvider.overrideWith((ref) => 1),
          ],
          child: MaterialApp(
            home: const Scaffold(
              body: HomeReviewIndicator(),
            ),
          ),
        ),
      );

      await tester.pump();

      // Find the pending review indicator
      final indicatorFinder = find.byKey(const Key('home_review_queue_indicator'));
      expect(indicatorFinder, findsOneWidget);
      expect(find.text('1 transaction needs review'), findsOneWidget);

      // Tap indicator to navigate to ReviewQueueScreen
      await tester.tap(indicatorFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ReviewQueueScreen), findsOneWidget);
    });

    test('14. Notification deduplication across refreshes and process restarts', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      // Ingest message that routes to Review Queue
      await LiveSmsService.instance.testProcessBody(
        'INR 450.00 debited from A/C **3131 on 19-Nov-26.',
        sender: 'UNKNOWN_BANK',
        sourceRecordId: 'SRC:SMS:TEST_NOTIF_DEDUP_01',
      );

      final candidates = await db.query(TablesV24.reviewCandidates);
      expect(candidates.length, 1);
      final reviewId = candidates.first['id'] as String;

      // Verify the review ID was recorded in persistent SharedPreferences
      final notified = prefs.getStringList('notified_review_candidate_ids') ?? [];
      expect(notified.contains(reviewId), isTrue);

      // Re-triggering review notification for this ID must skip (deduplication)
      final initialNotifCount = notificationCalls.length;

      // Simulate re-running processMessage or drainage with the same item
      await LiveSmsService.instance.drainPending();

      // Notification must NOT be sent again
      expect(notificationCalls.length, initialNotifCount);

      // Verify resolved items are never notified
      await ReviewRepo().approve(reviewId);
      final resolvedItem = await ReviewRepo().getById(reviewId);
      expect(resolvedItem!.status, 'approved');
    });

    test('15. Failed notification display allows retry, does not prematurely mark notified', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      // Temporarily mock local_notifications to fail (simulating permission denied)
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (MethodCall methodCall) async {
          throw PlatformException(code: 'PERMISSION_DENIED', message: 'Notifications denied');
        },
      );

      // Ingest message that routes to Review Queue
      await LiveSmsService.instance.testProcessBody(
        'INR 550.00 debited from A/C **4242 on 19-Nov-26.',
        sender: 'UNKNOWN_ISSUER',
        sourceRecordId: 'SRC:SMS:TEST_NOTIF_FAIL_01',
      );

      final candidates = await db.query(TablesV24.reviewCandidates);
      final reviewId = candidates.firstWhere((c) => (c['raw_payload'] as String).contains('4242'))['id'] as String;

      // Because notification display failed, reviewId MUST NOT be persisted to notified set!
      final notifiedSet = prefs.getStringList('notified_review_candidate_ids') ?? [];
      expect(notifiedSet.contains(reviewId), isFalse,
          reason: 'Failed notification display must NOT permanently mark candidate as notified');

      // Now restore notification permission/handler
      notificationCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (MethodCall methodCall) async {
          notificationCalls.add(methodCall);
          switch (methodCall.method) {
            case 'initialize':
              return true;
            case 'areNotificationsEnabled':
              return true;
            default:
              return null;
          }
        },
      );

      // Trigger retry of pending eligible notifications (e.g. on refresh or resume)
      final retryCount = await LiveSmsService.instance.notifyEligiblePendingReviews();
      expect(retryCount, greaterThanOrEqualTo(1));
      expect(notificationCalls.isNotEmpty, isTrue);

      // Now that notification succeeded, it MUST be persisted in SharedPreferences
      final notifiedAfterRetry = prefs.getStringList('notified_review_candidate_ids') ?? [];
      expect(notifiedAfterRetry.contains(reviewId), isTrue);

      // Further retry does not re-notify
      final secondRetryCount = await LiveSmsService.instance.notifyEligiblePendingReviews();
      expect(secondRetryCount, 0);
    });
  });
}
