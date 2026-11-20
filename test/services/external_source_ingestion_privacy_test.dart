import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/services/gmail_integration_service.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/services/sms_import_service.dart';

void main() {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;
  late String dbPath;
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_timezone'),
      (MethodCall methodCall) async => 'Asia/Kolkata',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('spendx/sms_live'),
      (MethodCall methodCall) async {
        switch (methodCall.method) {
          case 'getPendingSms':
          case 'readInboxSince':
          case 'readAllInbox':
            return <Map<String, dynamic>>[];
          default:
            return true;
        }
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (MethodCall methodCall) async => true,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
    testDir = await Directory.systemTemp.createTemp('spendx_external_ingestion_test_');
    dbPath = p.join(testDir.path, 'ext_test.db');
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

  group('External Source Ingestion & Privacy Verification', () {
    test('1. WhatsApp financial alert from verified banking bot is accepted and attributed', () async {
      // Setup existing HDFC Bank account
      final acc = BankAccount(
        name: 'HDFC Bank Account',
        bank: 'HDFC',
        last4: '1234',
        accountType: 'savings',
        balance: 10000.0,
      );
      final createdId = await AccountRepo().insertAccount(acc);

      // Ingest message arriving from WhatsApp official HDFC Bank bot
      final outcome = await LiveSmsService.instance.testProcessBody(
        'INR 650.00 debited from A/C **1234 on 20-Nov-26 to Swiggy. Avail Bal: INR 9,350.00.',
        sender: 'APP:com.whatsapp:HDFC Bank',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:101:tag:1763600000000',
      );

      expect(outcome.added, isTrue);
      expect(outcome.transaction, isNotNull);
      expect(outcome.transaction!.amount, 650.0);
      expect(outcome.transaction!.accountId, createdId);

      // Verify canonical derived balance reflects debit
      final derived = await CanonicalAccountRepository(executor: db).getDerivedBalance(createdId);
      expect(derived.paise, 935000);
    });

    test('2. WhatsApp message without financial transaction content is ignored', () async {
      final outcome = await LiveSmsService.instance.testProcessBody(
        'Hey, are we still meeting for lunch today? Let me know!',
        sender: 'APP:com.whatsapp:Rahul',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:102:tag:1763600001000',
      );

      expect(outcome.added, isFalse);
      expect(outcome.transaction, isNull);

      final events = await db.query(TablesV24.economicEvents);
      expect(events.isEmpty, isTrue, reason: 'Personal chat must create zero events');
    });

    test('3. Gmail notification preview from official bank is accepted and attributed', () async {
      final acc = BankAccount(
        name: 'ICICI Bank Account',
        bank: 'ICICI',
        last4: '5678',
        accountType: 'savings',
        balance: 20000.0,
      );
      final createdId = await AccountRepo().insertAccount(acc);

      final outcome = await LiveSmsService.instance.testProcessBody(
        'Alert: INR 1,200.00 debited from A/C **5678 on 20-Nov-26 for Amazon. Avail Bal: INR 18,800.00.',
        sender: 'APP:com.google.android.gm:alerts@icicibank.com',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.gm:201:tag:1763600002000',
      );

      expect(outcome.added, isTrue);
      expect(outcome.transaction, isNotNull);
      expect(outcome.transaction!.amount, 1200.0);
      expect(outcome.transaction!.accountId, createdId);
    });

    test('4. Bill reminder notification NEVER creates an expense transaction', () async {
      final outcome = await LiveSmsService.instance.testProcessBody(
        'Your HDFC Credit Card bill of Rs. 15,000.00 is due on 25-Nov-26. Min Due: Rs. 1,500.00.',
        sender: 'APP:com.whatsapp:HDFC Bank',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:301:tag:1763600003000',
      );

      expect(outcome.added, isFalse, reason: 'Bill reminder must NEVER create an expense transaction');
      expect(outcome.transaction, isNull);

      // Verify zero expense canonical events
      final events = await db.query(
        TablesV24.economicEvents,
        where: 'event_type = ?',
        whereArgs: ['expense'],
      );
      expect(events.isEmpty, isTrue, reason: 'Zero expense postings must be created for a bill statement');
    });

    test('5. Credit card bill payment is classified as CC Payment and NEVER creates a second expense', () async {
      // SmsImportService classifies this as creditCardPayment
      final classification = SmsImportService.instance.classifyMessage(
        'Payment of INR 5,000.00 received towards your HDFC Credit Card ending 6366 on 20-Nov-26.',
        'APP:com.whatsapp:HDFC Bank',
      );
      expect(classification.eventType, SmsEventType.creditCardPayment);
      expect(classification.transaction!.isCredit, isFalse);

      // Zero expense events created against expense categories
      final expensePostings = await db.rawQuery(
        "SELECT * FROM ${TablesV24.postings} WHERE account_id LIKE 'cat_%'",
      );
      expect(expensePostings.isEmpty, isTrue, reason: 'Credit card bill payment must never touch an expense category');
    });

    test('6. Uncertain / ambiguous match routes to Review Queue with 0 ledger postings', () async {
      // Ingest message with unknown bank and unknown account digits
      final outcome = await LiveSmsService.instance.testProcessBody(
        'INR 800.00 debited from unknown instrument on 20-Nov-26.',
        sender: 'APP:com.whatsapp:Unknown',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:501:tag:1763600005000',
      );

      expect(outcome.added, isFalse);

      final reviews = await db.query(TablesV24.reviewCandidates);
      expect(reviews.length, 1);
      expect(reviews.first['raw_payload'] as String, contains('800.00'));

      final postings = await db.query(TablesV24.postings);
      expect(postings.isEmpty, isTrue, reason: 'Uncertain match must create 0 ledger postings');
    });

    test('7. Cross-channel deduplication merges push notification and subsequent SMS with same UTR', () async {
      final acc = BankAccount(
        name: 'SBI Account',
        bank: 'SBI',
        last4: '9999',
        accountType: 'savings',
        balance: 50000.0,
      );
      await AccountRepo().insertAccount(acc);

      // Step 1: Push arrives from WhatsApp
      final outcomePush = await LiveSmsService.instance.testProcessBody(
        'INR 500.00 debited from A/C **9999 on 20-Nov-26 via UPI/632598124001/Swiggy.',
        sender: 'APP:com.whatsapp:SBI',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:601:tag:1763600006000',
      );
      expect(outcomePush.added, isTrue);

      final eventsBefore = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(eventsBefore.length, 1);

      // Step 2: Later, standard carrier SMS arrives with exact same UTR 632598124001
      final outcomeSms = await LiveSmsService.instance.testProcessBody(
        'Dear Customer, INR 500.00 debited from A/C **9999 on 20-Nov-26 via UPI Ref 632598124001 to Swiggy. Bal: 49,500.00',
        sender: 'SBIINB',
        sourceRecordId: 'SRC:TELEPHONY_SMS:7001',
      );
      expect(outcomeSms.added, isFalse);

      final eventsAfter = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(eventsAfter.length, 1, reason: 'Subsequent SMS must merge with push notification; zero duplicate economic events');
    });

    test('8. WhatsApp credit alert from verified bank bot is accepted and attributed', () async {
      final acc = BankAccount(
        name: 'ICICI Bank Account',
        bank: 'ICICI',
        last4: '5678',
        accountType: 'savings',
        balance: 20000.0,
      );
      final createdId = await AccountRepo().insertAccount(acc);

      final outcome = await LiveSmsService.instance.testProcessBody(
        'INR 25,000.00 credited to A/C **5678 on 20-Nov-26 by SALARY. Avail Bal: INR 45,000.00.',
        sender: 'APP:com.whatsapp:ICICI Bank',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:701:tag:1763600007000',
      );

      expect(outcome.added, isTrue);
      expect(outcome.transaction, isNotNull);
      expect(outcome.transaction!.amount, 25000.0);
      expect(outcome.transaction!.isIncomeType, isTrue);
      expect(outcome.transaction!.accountId, createdId);

      // Verify canonical derived balance reflects credit: 20000 + 25000 = 45000.0
      final derived = await CanonicalAccountRepository(executor: db).getDerivedBalance(createdId);
      expect(derived.paise, 4500000);
    });

    test('9. Untrusted WhatsApp sender using bank-like name without valid grammar is rejected', () async {
      final outcome = await LiveSmsService.instance.testProcessBody(
        'Click http://scam.link/verify to claim your lottery prize of INR 50,000!',
        sender: 'APP:com.whatsapp:Scammer Bank',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:702:tag:1763600007001',
      );

      expect(outcome.added, isFalse);
      expect(outcome.transaction, isNull);
      final events = await db.query(TablesV24.economicEvents);
      expect(events.isEmpty, isTrue);
    });

    test('10. Group conversation message in WhatsApp is rejected', () async {
      final outcome = await LiveSmsService.instance.testProcessBody(
        'Goa trip group: Total food expense was Rs 4500, please send Rs 900 each.',
        sender: 'APP:com.whatsapp:Goa Trip Group',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:703:tag:1763600007002',
      );

      expect(outcome.added, isFalse);
      expect(outcome.transaction, isNull);
      final events = await db.query(TablesV24.economicEvents);
      expect(events.isEmpty, isTrue);
    });

    test('11. Promotional pre-approved loan message on WhatsApp is rejected', () async {
      final outcome = await LiveSmsService.instance.testProcessBody(
        'Pre-approved personal loan of Rs 5,00,000 waiting for you! Instant loan at your fingertips. Apply now.',
        sender: 'APP:com.whatsapp:HDFC Bank',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:704:tag:1763600007003',
      );

      expect(outcome.added, isFalse);
      expect(outcome.transaction, isNull);
      final events = await db.query(TablesV24.economicEvents);
      expect(events.isEmpty, isTrue);
    });

    test('12. WhatsApp toggle disabled by default and toggle persistence', () async {
      // 1. Defaults to disabled
      expect(SettingsService.instance.whatsappIngestionEnabled, isFalse);
      expect(SettingsService.instance.gmailPreviewEnabled, isFalse);

      // 2. Enable requires explicit update
      await SettingsService.instance.setWhatsAppIngestionEnabled(true);
      expect(SettingsService.instance.whatsappIngestionEnabled, isTrue);

      // 3. Disable immediately takes effect
      await SettingsService.instance.setWhatsAppIngestionEnabled(false);
      expect(SettingsService.instance.whatsappIngestionEnabled, isFalse);
    });

    test('13. Synthetic Gmail bank credit email is accepted and credited', () async {
      final acc = BankAccount(
        name: 'HDFC Bank Account',
        bank: 'HDFC',
        last4: '1234',
        accountType: 'savings',
        balance: 10000.0,
      );
      final createdId = await AccountRepo().insertAccount(acc);

      final outcome = await LiveSmsService.instance.testProcessBody(
        'Dear Customer, Account **1234 has been credited with INR 5,000.00 on 20-Nov-26 by NEFT. Avail Bal: INR 15,000.00.',
        sender: 'APP:com.google.android.gm:alerts@hdfcbank.net',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_credit_101',
      );

      expect(outcome.added, isTrue);
      expect(outcome.transaction!.amount, 5000.0);
      expect(outcome.transaction!.isIncomeType, isTrue);
      expect(outcome.transaction!.accountId, createdId);

      final derived = await CanonicalAccountRepository(executor: db).getDerivedBalance(createdId);
      expect(derived.paise, 1500000);
    });

    test('14. Synthetic Gmail credit-card purchase alert creates card liability and expense', () async {
      final card = CreditCard(
        name: 'SBI Credit Card',
        bank: 'SBI',
        last4: '9876',
        limitAmount: 100000.0,
      );
      final cardId = await CreditRepo().insert(card);

      final outcome = await LiveSmsService.instance.testProcessBody(
        'Alert: INR 2,400.00 spent on your SBI Credit Card ending 9876 at Reliance Digital on 20-Nov-26.',
        sender: 'APP:com.google.android.gm:alerts@sbicard.com',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_card_purchase_201',
      );

      expect(outcome.added, isTrue);
      expect(outcome.transaction!.amount, 2400.0);
      expect(outcome.transaction!.accountId, cardId);

      // Verify double-entry balance in postings
      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 2);
      final debits = postings.where((p) => (p['direction'] as String) == 'debit');
      final credits = postings.where((p) => (p['direction'] as String) == 'credit');
      expect(debits.first['amount_minor_units'], 240000);
      expect(credits.first['amount_minor_units'], 240000);
      expect(credits.first['account_id'], cardId, reason: 'Credit must be to Card Liability');
    });

    test('15. Synthetic Gmail credit-card statement generates zero duplicate purchases', () async {
      final outcome = await LiveSmsService.instance.testProcessBody(
        'Your HDFC Bank Credit Card Statement for Card ending 6366: Total Due Rs 28,450.00, Min Due Rs 1,500.00. Payment Due Date: 05-Dec-26.',
        sender: 'APP:com.google.android.gm:statements@hdfcbank.net',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_stmt_301',
      );

      expect(outcome.added, isFalse);
      expect(outcome.transaction, isNull);

      final expenseEvents = await db.query(
        TablesV24.economicEvents,
        where: 'event_type = ?',
        whereArgs: ['expense'],
      );
      expect(expenseEvents.isEmpty, isTrue, reason: 'Statement notification must not create duplicate purchases');
    });

    test('16. Synthetic Gmail refund confirmation creates Dr Bank Asset, Cr Expense', () async {
      final acc = BankAccount(
        name: 'HDFC Savings Account',
        bank: 'HDFC',
        last4: '1234',
        accountType: 'savings',
        balance: 10000.0,
      );
      final accId = await AccountRepo().insertAccount(acc);

      // Ingest original purchase first with UTR 987654321012
      final purchaseOutcome = await LiveSmsService.instance.testProcessBody(
        'INR 750.00 debited from A/C **1234 on 19-Nov-26 to Swiggy. UPI Ref: 987654321012.',
        sender: 'APP:com.google.android.gm:alerts@hdfcbank.net',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_purchase_400',
      );
      expect(purchaseOutcome.added, isTrue);

      // Ingest refund referencing same UTR 987654321012
      final outcome = await LiveSmsService.instance.testProcessBody(
        'INR 750.00 refunded to A/C **1234 from Swiggy on 20-Nov-26. UPI Ref: 987654321012.',
        sender: 'APP:com.google.android.gm:alerts@hdfcbank.net',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_refund_401',
      );

      expect(outcome.added, isTrue);
      expect(outcome.transaction!.amount, 750.0);
      expect(outcome.transaction!.isIncomeType, isTrue);

      final postings = await db.query(TablesV24.postings);
      expect(postings.length, 6); // 2 opening balance, 2 purchase, 2 refund
      final refundDebits = postings.where(
        (p) => p['account_id'] == accId && p['direction'] == 'debit' && p['amount_minor_units'] == 75000,
      );
      expect(refundDebits.length, 1, reason: 'Debit to bank asset account on refund');
      final refundCredits = postings.where(
        (p) => p['direction'] == 'credit' && p['account_id'] != accId && p['amount_minor_units'] == 75000,
      );
      expect(refundCredits.length, 1, reason: 'Credit to expense category on refund');
    });

    test('17. Synthetic Gmail OTP and promotional emails are strictly rejected', () async {
      // OTP email
      final outcomeOtp = await LiveSmsService.instance.testProcessBody(
        'Your OTP for NetBanking transaction is 728192. Do not share your OTP with anyone.',
        sender: 'APP:com.google.android.gm:alerts@icicibank.com',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_otp_501',
      );
      expect(outcomeOtp.added, isFalse);

      // Promotional email
      final outcomePromo = await LiveSmsService.instance.testProcessBody(
        'Get flat 15% cashback on flight bookings with your HDFC Bank Card! Claim now.',
        sender: 'APP:com.google.android.gm:offers@hdfcbank.net',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_promo_502',
      );
      expect(outcomePromo.added, isFalse);

      // Personal email
      final outcomePersonal = await LiveSmsService.instance.testProcessBody(
        'Hi, can you review the attached project document and let me know your thoughts?',
        sender: 'APP:com.google.android.gm:alex@gmail.com',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_personal_503',
      );
      expect(outcomePersonal.added, isFalse);

      final events = await db.query(TablesV24.economicEvents);
      expect(events.isEmpty, isTrue);
    });

    test('18. Duplicate Gmail email and notification preview merge safely to single event', () async {
      final acc = BankAccount(
        name: 'ICICI Savings',
        bank: 'ICICI',
        last4: '5678',
        accountType: 'savings',
        balance: 30000.0,
      );
      await AccountRepo().insertAccount(acc);

      // Notification preview arrives first
      final outcomeNotif = await LiveSmsService.instance.testProcessBody(
        'INR 2,000.00 debited from A/C **5678 on 20-Nov-26 via UPI Ref 928374829101 to Flipkart. Bal: INR 28,000.00.',
        sender: 'APP:com.google.android.gm:alerts@icicibank.com',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.google.android.gm:901:tag:1763600009000',
      );
      expect(outcomeNotif.added, isTrue);

      final eventsFirst = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(eventsFirst.length, 1);

      // Gmail API full message sync arrives later with exact same UTR 928374829101
      final outcomeEmail = await LiveSmsService.instance.testProcessBody(
        'Dear Customer, INR 2,000.00 debited from A/C **5678 on 20-Nov-26 via UPI Ref 928374829101 to Flipkart. Avail Bal: INR 28,000.00.',
        sender: 'APP:com.google.android.gm:alerts@icicibank.com',
        sourceRecordId: 'SRC:EMAIL:GMAIL:msg_flipkart_901',
      );
      expect(outcomeEmail.added, isFalse);

      final eventsSecond = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(eventsSecond.length, 1, reason: 'Duplicate push preview and email sync MUST merge to 1 event');
    });

    test('19. Expired or unauthenticated Gmail sync fails gracefully without crash', () async {
      final result = await GmailIntegrationService.instance.syncFinancialEmails();
      expect(result.scanned, 0);
      expect(result.ingested, 0);
      expect(result.error, isNotNull);
    });

    test('20. Double-entry accounting balance verification (paise-balanced debits == credits)', () async {
      final acc = BankAccount(
        name: 'HDFC Savings Account',
        bank: 'HDFC',
        last4: '1234',
        accountType: 'savings',
        balance: 50000.0,
      );
      final accId = await AccountRepo().insertAccount(acc);

      // 1. Bank Debit (Expense)
      final debitOutcome = await LiveSmsService.instance.testProcessBody(
        'INR 1,750.00 debited from A/C **1234 on 20-Nov-26 to Zomato. Avail Bal: 48,250.00.',
        sender: 'APP:com.whatsapp:HDFC Bank',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:9901:tag:1763600099001',
      );
      expect(debitOutcome.added, isTrue);
      expect(debitOutcome.transaction!.accountId, accId);

      // 2. Bank Credit (Income)
      final creditOutcome = await LiveSmsService.instance.testProcessBody(
        'INR 10,000.00 credited to A/C **1234 on 20-Nov-26 by Dividend. Avail Bal: 58,250.00.',
        sender: 'APP:com.whatsapp:HDFC Bank',
        sourceRecordId: 'SRC:ANDROID_NOTIF:com.whatsapp:9902:tag:1763600099002',
      );
      expect(creditOutcome.added, isTrue);

      // Verify that across all generated economic events, every event has equal debits and credits in paise!
      final events = await db.query(
        TablesV24.economicEvents,
        where: "event_type != 'opening_balance'",
      );
      expect(events.length, 2);

      for (final ev in events) {
        final evId = ev['id'] as String;
        final postings = await db.query(
          TablesV24.postings,
          where: 'economic_event_id = ?',
          whereArgs: [evId],
        );
        expect(postings.length, 2, reason: 'Double-entry requires at least 2 postings per event');

        int sumDebits = 0;
        int sumCredits = 0;
        for (final p in postings) {
          final amt = p['amount_minor_units'] as int;
          final dir = p['direction'] as String;
          if (dir == 'debit') sumDebits += amt;
          if (dir == 'credit') sumCredits += amt;
        }
        expect(sumDebits, sumCredits, reason: 'Event $evId must balance: sum(debit) == sum(credit) in paise');
      }
    });
  });
}
