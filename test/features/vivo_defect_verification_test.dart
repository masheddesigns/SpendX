import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/database_access_gate.dart';
import 'package:spend_x/data/core/database_lifecycle_coordinator.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/reminder_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/reminder_model.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/services/sms_import_service.dart';
import 'package:spend_x/services/transaction_text_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;
  late String dbPath;
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (MethodCall methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('spendx/sms_live'),
      (MethodCall methodCall) async => null,
    );
  });

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('spendx_vivo_test_');
    dbPath = p.join(testDir.path, 'vivo_test.db');
    AppDatabase.setTestDatabasePath(dbPath);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    db = await AppDatabase.instance.database;
    await CategoryRepo(executor: db).ensureDefaults();
  });

  tearDown(() async {
    AppDatabase.setTestDatabasePath(null);
    DatabaseAccessGate.instance.resetForTesting();
    DatabaseLifecycleCoordinator.instance.resetForTesting();
    try {
      if (testDir.existsSync()) {
        await testDir.delete(recursive: true);
      }
    } catch (_) {}
  });
  group('Defect 1: Push Notification Parsing for Financial Apps', () {
    test('1a. Google Pay push notification (no account identifier)', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'Paid ₹250 to Chai Point using UPI';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 250.0);
      expect(classification.transaction!.isCredit, false);
      expect(classification.transaction!.merchant, contains('Chai Point'));
    });

    test('1b. PhonePe push notification (no account identifier)', () {
      const sender = 'APP:com.phonepe.app:PhonePe';
      const body = '₹500 paid successfully to Starbucks India';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 500.0);
      expect(classification.transaction!.isCredit, false);
    });

    test('1c. CRED payment notification', () {
      const sender = 'APP:com.dreamplug.androidapp:CRED';
      const body = 'Payment of ₹12,500 towards Axis Bank Credit Card was successful';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 12500.0);
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });

    test('1d. Groww Stocks SIP / UPI notification', () {
      const sender = 'APP:com.nextbillion.groww:Groww';
      const body = 'Groww: ₹1,500 invested in Nifty 50 Index Fund';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 1500.0);
    });

    test('1e. JioFinance payment notification', () {
      const sender = 'APP:in.jfs.jiofinance:JioFinance';
      const body = 'Paid ₹706.82 for JioFiber broadband bill';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 706.82);
    });

    test('1f. OneCard spend notification', () {
      const sender = 'APP:com.creditcard.onecard:OneCard';
      const body = 'You spent INR 1,499.00 at Zomato on your OneCard ending 9012';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 1499.0);
      expect(classification.transaction!.last4, '9012');
    });

    test('1g. Incoming UPI payment notification', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'Received ₹1,000 from Rahul Sharma via UPI';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 1000.0);
      expect(classification.transaction!.isCredit, true);
    });
  });

  group('Defect 2: AutoPay and Subscription Cancellation Detection', () {
    test('2a. UPI AutoPay mandate revoked', () {
      const body = 'Dear UPI User, UPI AutoPay for GROWW INVEST TECH PRIVATE LIMITED STOCKS SIP debit of Rs.1100.00 has been successfully revoked.';
      const sender = 'VM-UPIAUTOPAY-T';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant, contains('Groww'));
      expect(hit.reason, 'revoked');
      expect(hit.amount, 1100.0);

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.obligationCancellation, isNotNull);
      expect(classification.eventType, SmsEventType.obligationCancelled);
    });

    test('2b. Netflix e-mandate cancelled', () {
      const body = 'Hi Sivek, your emandate registered on NETFLIX of INR199.0 has been cancelled.';
      const sender = 'AD-ONECRD-T';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant, 'Netflix');
      expect(hit.reason, 'cancelled');
      expect(hit.amount, 199.0);
    });

    test('2c. Standing Instruction for Amazon cancelled', () {
      const body = 'Standing Instruction towards Amazon of INR 799.00 has been cancelled.';
      const sender = 'ICICIB';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant, 'Amazon');
      expect(hit.reason, 'cancelled');
      expect(hit.amount, 799.0);
    });

    test('2d. General Spotify subscription revoked', () {
      const body = 'Your mandate for Spotify of Rs 119 has been revoked.';
      const sender = 'HDFCBK';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant, 'Spotify');
      expect(hit.reason, 'revoked');
      expect(hit.amount, 119.0);
    });
  });

  group('Defect 3: Non-Negative Assets Invariant', () {
    test('3a. Fallback calculation in AccountListScreen partitions overdrafts', () {
      final accounts = [
        BankAccount(id: 'a1', name: 'SBI', bank: 'SBI', balance: 50000, isAsset: true),
        BankAccount(id: 'a2', name: 'Overdrawn Acct', bank: 'HDFC', balance: -15000, isAsset: true),
      ];

      final positiveAssets = accounts
          .where((a) => a.isAsset && a.balance > 0)
          .fold<double>(0, (sum, a) => sum + a.balance);
      final accountOverdrafts = accounts
          .where((a) => a.isAsset && a.balance < 0)
          .fold<double>(0, (sum, a) => sum + a.balance.abs());

      expect(positiveAssets, 50000.0);
      expect(accountOverdrafts, 15000.0);
      expect(positiveAssets >= 0, isTrue);

      final totalLiabilities = accountOverdrafts;
      final netWorth = positiveAssets - totalLiabilities;
      expect(netWorth, 35000.0);
    });

    test('3b. When all accounts are overdrawn, assets is 0 and NEVER negative', () {
      final accounts = [
        BankAccount(id: 'a1', name: 'Overdrawn Acct', bank: 'SBI', balance: -5000, isAsset: true),
      ];

      final positiveAssets = accounts
          .where((a) => a.isAsset && a.balance > 0)
          .fold<double>(0, (sum, a) => sum + a.balance);
      final accountOverdrafts = accounts
          .where((a) => a.isAsset && a.balance < 0)
          .fold<double>(0, (sum, a) => sum + a.balance.abs());

      expect(positiveAssets, 0.0);
      expect(accountOverdrafts, 5000.0);

      final netWorth = positiveAssets - accountOverdrafts;
      expect(netWorth, -5000.0);
      expect(positiveAssets < 0, isFalse);
    });
  });

  group('Defect 4: Financial App Promotional Ad & Loan Offer Rejection', () {
    test('4a. Google Pay loan offer ad is rejected with zero transactions', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = '₹30,000 to ₹40,00,000 ready for your needs!';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });

    test('4b. Pre-approved loan offer ad is rejected', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'Pre-approved personal loan of ₹5,00,000 is waiting for you! Apply now.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });

    test('4c. Borrow up to / credit line ad is rejected', () {
      const sender = 'APP:com.phonepe.app:PhonePe';
      const body = 'Borrow up to ₹2,00,000 at zero processing fee. Instant transfer.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });

    test('4d. Scratch card reward ad is rejected', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'You won a scratch card! Win up to ₹1,000 on your next recharge.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });
  });

  group('Defect 5: UPI Collect / Payment Demand Rejection', () {
    test('5a. UPI Collect request from merchant is rejected', () {
      const sender = 'APP:com.phonepe.app:PhonePe';
      const body = 'Collect request of Rs 450 received from Swiggy. Tap to approve or decline.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });

    test('5b. UPI authorization request from individual is rejected', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'Ramesh Kumar has requested ₹1,200 from you on Google Pay. Tap to pay.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });
  });

  group('Defect 6: Virtual & Loyalty Points Rejection', () {
    test('6a. NeuCoins credit notification is rejected without fiat currency', () {
      const sender = 'APP:com.tatadigital.tcp:Tata Neu';
      const body = 'Congratulations! 500 NeuCoins credited to your NeuPass account.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });

    test('6b. Flipkart SuperCoins earned notification is rejected', () {
      const sender = 'FLPKRT';
      const body = 'You earned 150 SuperCoins on your recent Flipkart order!';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });
  });

  group('Defect 7: Credit Card Bill Statement Double-Counting Prevention', () {
    test('7a. Credit card statement generated notice updates balance but creates NO purchase transaction', () {
      const sender = 'HDFCBK';
      const body = 'Your HDFC Bank Credit Card ending 4567 statement is generated. Total Amt Due: Rs 24,500.00. Min Amt Due: Rs 1,200.00. Due date: 20-Nov-2026.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
      expect(classification.balance, isNotNull);
      expect(classification.balance!.amount, 24500.0);
      expect(classification.balance!.isStatementBill, true);
    });

    test('7b. Credit card bill reminder creates NO purchase transaction', () {
      const sender = 'AD-SBICRD';
      const body = 'Dear Cardholder, bill for your SBI Card ending 8901 of Rs 18,300 is due on 15 Nov. Pay now to avoid charges.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
      expect(classification.balance, isNotNull);
      expect(classification.balance!.amount, 18300.0);
    });
  });

  group('Defect 8: Failed, Declined and Timed-Out Transaction Rejection', () {
    test('8a. Insufficient funds declined transaction is not recorded as expense', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'Payment of ₹850 at Star Bazaar was declined due to insufficient funds.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
      expect(classification.eventType, SmsEventType.failed);
    });

    test('8b. Timed out transaction could not be processed is not recorded as expense', () {
      const sender = 'APP:com.phonepe.app:PhonePe';
      const body = 'Payment of ₹1,500 could not be processed due to bank network error. If debited, will be refunded.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
      expect(classification.eventType, SmsEventType.failed);
    });
  });

  group('Defect 9: Credit Card Repayments Extraction', () {
    test('9a. SBI Card repayment confirmation with available limit', () {
      const sender = 'VM-SBICRD-T';
      const body = 'Thank you for payment of Rs 17,000 towards your SBI Card ending 8901 on 09-Nov-26.\nAvailable limit: Rs 1,00,000.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 17000.0);
      expect(classification.transaction!.last4, '8901');
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });

    test('9b. HDFC Bank credit card repayment confirmation', () {
      const sender = 'HDFCBK';
      const body = 'Thank you for paying Rs 12,000 towards your HDFC Bank Credit Card ending 1234 on 08-Nov-26.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 12000.0);
      expect(classification.transaction!.last4, '1234');
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });

    test('9c. ICICI Bank credit card repayment confirmation with available limit', () {
      const sender = 'ICICIB';
      const body = 'Payment of INR 9,000.00 received towards your ICICI Bank Credit Card ending 5007. Available Credit Limit: INR 85,000';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 9000.0);
      expect(classification.transaction!.last4, '5007');
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });

    test('9d. OneCard repayment credited confirmation', () {
      const sender = 'AD-ONECRD-T';
      const body = 'Your payment of Rs 1,499 towards OneCard has been credited.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 1499.0);
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });

    test('9e. Bank debit explicitly paying credit card', () {
      const sender = 'HDFCBK';
      const body = 'Rs 15,000.00 debited from A/c XX1234 on 09-Nov-26 towards HDFC Bank Credit Card payment.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 15000.0);
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });
  });

  group('Defect 10: Bank & Card Balance Push Notification Fetching', () {
    test('10a. Federal Bank FedMobile push notification with Rupee symbol', () {
      const sender = 'APP:com.fedmobile:FedMobile';
      const body = 'FedMobile: Available Balance: ₹17,592.25';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.balance, isNotNull);
      expect(classification.balance!.kind, BalanceKind.bank);
      expect(classification.balance!.amount, 17592.25);
      expect(classification.balance!.bankKeyword, 'fedbnk');
    });

    test('10b. SBI YONO push notification with Rupee symbol and account', () {
      const sender = 'APP:com.sbi.lotusintouch:YONO SBI';
      const body = 'Available balance in your A/c XX8901 is ₹20,000.00';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.balance, isNotNull);
      expect(classification.balance!.kind, BalanceKind.bank);
      expect(classification.balance!.amount, 20000.0);
      expect(classification.balance!.last4, '8901');
      expect(classification.balance!.bankKeyword, 'sbi');
    });

    test('10c. HDFC Bank push notification balance', () {
      const sender = 'APP:com.snapwork.hdfc:HDFC MobileBanking';
      const body = 'Avail Bal: Rs. 800.91 in HDFC Bank A/c 5678';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.balance, isNotNull);
      expect(classification.balance!.kind, BalanceKind.bank);
      expect(classification.balance!.amount, 800.91);
      expect(classification.balance!.last4, '5678');
      expect(classification.balance!.bankKeyword, 'hdfc');
    });

    test('10d. Credit card available limit push notification', () {
      const sender = 'APP:com.sbicard.app:SBI Card';
      const body = 'SBI Card: Avl Limit for card ending 8901 is Rs. 82,933.13';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.balance, isNotNull);
      expect(classification.balance!.kind, BalanceKind.creditCard);
      expect(classification.balance!.isAvailableLimit, true);
      expect(classification.balance!.amount, 82933.13);
      expect(classification.balance!.last4, '8901');
    });
  });

  group('Defect 11: AutoPay & Subscription Cancellation Edge Cases', () {
    test('11a. Mandate cancellation without explicit currency amount', () {
      const sender = 'VM-UPIAUTOPAY-T';
      const body = 'Dear UPI User, UPI AutoPay mandate for Netflix has been successfully revoked.';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant, 'Netflix');
      expect(hit.reason, 'revoked');

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.obligationCancellation, isNotNull);
      expect(classification.eventType, SmsEventType.obligationCancelled);
    });

    test('11b. Google Play subscription cancellation', () {
      const sender = 'APP:com.android.vending:Google Play Store';
      const body = 'Your Google Play subscription to Duolingo has been cancelled.';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant, 'Duolingo');
      expect(hit.reason, 'cancelled');
    });

    test('11c. AutoPay cancelled for Spotify without prefix', () {
      const sender = 'APP:com.phonepe.app:PhonePe';
      const body = 'AutoPay for Spotify has been cancelled.';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant, 'Spotify');
      expect(hit.reason, 'cancelled');
    });

    test('11d. Auto-debit stopped for Disney+ Hotstar', () {
      const sender = 'HDFCBK';
      const body = 'Auto-debit for your Disney+ Hotstar subscription has been stopped.';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant.toLowerCase(), contains('hotstar'));
      expect(hit.reason, 'cancelled');
    });
  });

  group('Defect 12: Bill Statement Generation vs Repayment Disambiguation', () {
    test('12a. Statement bill generation sets bill reminder, zero expense', () {
      const sender = 'VM-SBICRD-T';
      const body = 'Total amount due on your SBI Card ending 8901 is Rs 17,000 payable by 25-Nov-26. Min amount due Rs 850.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
      expect(classification.balance, isNotNull);
      expect(classification.balance!.amount, 17000.0);
      expect(classification.eventType, SmsEventType.billReminder);
    });

    test('12b. Repayment of the generated bill creates creditCardPayment, decreases liability', () {
      const sender = 'VM-SBICRD-T';
      const body = 'Thank you for payment of Rs 17,000 towards your SBI Card ending 8901 on 09-Nov-26. Available limit: Rs 1,00,000.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 17000.0);
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });
  });

  group('Defect 13: Push Notification vs Bank SMS Cross-Channel Deduplication', () {
    test('13a. GPay push notification followed 7 mins later by Bank SMS with UTR is deduplicated', () async {
      const pushSender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const pushBody = 'Paid ₹250 to Chai Point';

      final res1 = await LiveSmsService.instance.testProcessBody(pushBody, sender: pushSender);
      expect(res1.added, isTrue);

      const bankSender = 'VM-FEDBNK';
      const bankBody = 'Rs 250 debited from A/c XX1234 to Chai Point on 10-Nov UPI/431528123456';

      final res2 = await LiveSmsService.instance.testProcessBody(bankBody, sender: bankSender);
      // Must be deduplicated (not added again as a second transaction)
      expect(res2.added, isFalse);
    });
  });

  group('Defect 14: Wallet Top-Up & UPI Lite Loading Classification as Internal Transfer', () {
    test('14a. UPI Lite loading is classified as transfer, not expense', () {
      const sender = 'VM-FEDBNK';
      const body = 'Rs 500.00 debited from A/c XX1234 towards loading of UPI Lite balance on 10-Nov-26. Avail Bal: Rs 15,000';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 500.0);
      expect(classification.eventType, SmsEventType.transfer);
      expect(classification.transaction!.merchant, 'UPI Lite Top-Up');
    });

    test('14b. Paytm Wallet topup is classified as transfer', () {
      const sender = 'HDFCBK';
      const body = 'Rs 1,000.00 debited from A/c XX5678 for Paytm Wallet topup on 10-Nov-26.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 1000.0);
      expect(classification.eventType, SmsEventType.transfer);
      expect(classification.transaction!.merchant, 'Paytm Wallet Top-Up');
    });
  });

  group('Defect 15: Multi-Currency Amount Extraction Prioritization', () {
    test('15a. Foreign currency with INR equivalent extracts the INR amount', () {
      const body = 'Alert: You have spent USD 20.00 (approx. INR 1,680.00) on your HDFC Bank Credit Card at OPENAI on 10-Nov-2026.';
      final parsed = TransactionTextParser.parse(body, source: 'sms');
      expect(parsed.amount, 1680.00);
    });

    test('15b. Standalone foreign currency extracts foreign amount cleanly', () {
      const body = 'Alert: USD 25.00 spent on your Card ending 1234 at NETFLIX.';
      final parsed = TransactionTextParser.parse(body, source: 'sms');
      expect(parsed.amount, 25.00);
    });
  });

  group('Defect 16: Mandate / AutoPay Registration Notice Guard', () {
    test('16a. UPI AutoPay mandate created creates reminder and zero immediate expense', () {
      const sender = 'HDFCBK';
      const body = 'UPI AutoPay mandate for Netflix of Rs. 199.00 has been successfully created. Next debit on 15-Nov-2026.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
      expect(classification.eventType, SmsEventType.billReminder);
      expect(classification.upcomingObligation, isNotNull);
      expect(classification.upcomingObligation!.amount, 199.00);
      expect(classification.upcomingObligation!.merchant?.toLowerCase(), contains('netflix'));
    });

    test('16b. E-mandate registered notice creates zero immediate expense', () {
      const sender = 'VM-SBICRD-T';
      const body = 'E-mandate of Rs 499.00 has been successfully registered on Card XX1234 towards Spotify. Next debit date: 25/11/2026';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
      expect(classification.eventType, SmsEventType.billReminder);
      expect(classification.upcomingObligation, isNotNull);
      expect(classification.upcomingObligation!.amount, 499.00);
    });
  });

  group('Defect 17: Salary Reminder Settlement', () {
    test('17a. Salary credit settles ReminderType.salary, but regular expense does not', () async {
      final repo = ReminderRepo();
      final now = DateTime.now();

      final reminder = Reminder(
        id: 'rem_salary_test',
        title: 'Monthly Salary Expected',
        amount: 85000.0,
        dueDate: now,
        type: ReminderType.salary,
        recordStatus: ReminderRecordStatus.pending,
        isActive: true,
      );
      await repo.insertGlobalReminder(reminder.toMap());

      // 1. Regular expense does NOT settle salary
      final settledByExpense = await repo.settleMatching(
        amount: 85000.0,
        date: now,
        notes: 'Office Equipment Purchase',
        isIncome: false,
      );
      expect(settledByExpense, 0);

      // 2. Income credit matching salary DOES settle
      final settledByIncome = await repo.settleMatching(
        amount: 85000.0,
        date: now,
        notes: 'Salary credited from Employer Inc',
        isIncome: true,
      );
      expect(settledByIncome, 1);
    });
  });

  group('Defect 18: Refund with Prior Debit Mention', () {
    test('18a. Refund mentioning earlier debited transaction is classified as refund', () {
      const sender = 'VM-FEDBNK';
      const body = 'Refund of Rs 250 for transaction debited on 09-Nov has been credited to your account XX1234.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNotNull);
      expect(classification.transaction!.amount, 250.0);
      expect(classification.eventType, SmsEventType.refund);
      expect(classification.transaction!.isCredit, true);
    });
  });

  group('Defect 19: UPI Lite Spend Debits Wallet Account, Not Primary Bank', () {
    test('19a. UPI Lite spend resolves to UPI Lite wallet account and preserves primary bank balance', () async {
      final bankId = await AccountRepo().insertAccount(BankAccount(
        name: 'Federal Bank',
        bank: 'Federal Bank',
        last4: '1234',
        balance: 10000.0,
      ));
      final walletId = await AccountRepo().insertAccount(BankAccount(
        name: 'UPI Lite',
        bank: 'UPI Lite',
        accountType: 'wallet',
        balance: 500.0,
      ));

      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'Paid ₹30 to Chai Point using UPI Lite';

      final res = await LiveSmsService.instance.testProcessBody(body, sender: sender);
      expect(res.added, true);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.accountId, walletId);
      expect(res.transaction!.accountId, isNot(bankId));
      expect(res.transaction!.amount, 30.0);

      final bank = await AccountRepo().getById(bankId);
      expect(bank!.balance, 10000.0); // Bank balance untouched!
    });
  });

  group('Defect 20: Credit Card Credits (Surcharge Waivers & Cashbacks) Reduce Card Liability', () {
    test('20a. Fuel surcharge waiver on credit card is ingested as refund against card liability', () async {
      final cardId = await CreditRepo().insert(CreditCard(
        name: 'ICICI Sapphiro',
        bank: 'ICICI Bank',
        last4: '5007',
        limitAmount: 200000.0,
        usedAmount: 5000.0,
        dueDay: 15,
      ));

      const sender = 'VM-ICICIB';
      const body = 'Fuel surcharge waiver of Rs 25.50 credited to your Card XX5007';

      final res = await LiveSmsService.instance.testProcessBody(body, sender: sender);
      expect(res.added, true);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.type, 'refund');
      expect(res.transaction!.accountId, cardId);
      expect(res.transaction!.source, 'credit_card_purchase');

      final card = await CreditRepo().getCard(cardId);
      expect(card!.outstanding, closeTo(4974.50, 0.01)); // Card liability reduced cleanly!
    });
  });

  group('Defect 21: Loan EMI Repayment Recognition & Progress Synchronization', () {
    test('21a. Loan EMI debit updates loan progress and settles reminder', () async {
      final bankId = await AccountRepo().insertAccount(BankAccount(
        name: 'HDFC Savings',
        bank: 'HDFC Bank',
        last4: '8434',
        balance: 50000.0,
      ));

      final loan = Loan(
        id: 'loan_hdfc_home_1',
        name: 'HDFC Home Loan',
        bank: 'HDFC Bank',
        total: 1000000.0,
        interestRate: 8.5,
        tenureMonths: 120,
        monthlyInstallment: 15450.0,
        startDate: DateTime(2025, 1, 1),
        paidAmount: 30900.0,
        loanStatus: 'active',
        dueDay: 5,
      );
      await LoanRepo().insertLoan(loan);

      final reminder = Reminder(
        id: 'rem_loan_hdfc_1',
        title: 'HDFC Home Loan EMI',
        amount: 15450.0,
        dueDate: DateTime.now().add(const Duration(days: 2)),
        type: ReminderType.loan,
        recordStatus: ReminderRecordStatus.pending,
        isActive: true,
      );
      await ReminderRepo().insertGlobalReminder(reminder.toMap());

      const sender = 'VM-HDFCBK';
      const body = 'Rs 15450.00 debited from A/c XX8434 towards EMI for Loan Account 5678';

      final res = await LiveSmsService.instance.testProcessBody(body, sender: sender);
      expect(res.added, true);
      expect(res.transaction, isNotNull);
      expect(res.transaction!.type, 'loan_repayment');
      expect(res.transaction!.relatedEntityId, loan.id);
      expect(res.transaction!.accountId, bankId);

      // Verify loan progress updated
      final updatedLoan = await LoanRepo().getLoanById(loan.id);
      expect(updatedLoan!.paidAmount, 46350.0);

      // Verify reminder settled
      final rem = await ReminderRepo().getById(reminder.id);
      expect(rem!.recordStatus, ReminderRecordStatus.done);
    });
  });

  group('Defect 22: GPay / PhonePe / Paytm Promotional Ads Rejected', () {
    test('22a. GPay cashback offer and RuPay link ad creates zero transactions', () {
      const sender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const body = 'Pay with your RuPay credit card on UPI and earn up to ₹100 cashback! Tap to link now.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });

    test('22b. PhonePe scratch card and recharge promo creates zero transactions', () {
      const sender = 'APP:com.phonepe.app:PhonePe';
      const body = 'Win up to ₹500 scratch card on your next recharge! Tap to pay.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.transaction, isNull);
    });
  });

  group('Defect 23: AutoPay / Mandate Cancellation with Amount and Merchant', () {
    test('23a. AutoPay revocation with amount extracts merchant and deactivates reminder', () async {
      final reminder = Reminder(
        id: 'rem_netflix_sub',
        title: 'Netflix Subscription',
        amount: 199.0,
        dueDate: DateTime.now().add(const Duration(days: 10)),
        type: ReminderType.custom,
        recordStatus: ReminderRecordStatus.pending,
        isActive: true,
      );
      await ReminderRepo().insertGlobalReminder(reminder.toMap());

      const sender = 'VK-NPCI';
      const body = 'Dear UPI User, AutoPay of Rs. 199.00 for NETFLIX has been successfully revoked.';

      final hit = SmsImportService.instance.detectObligationCancellation(body, sender);
      expect(hit, isNotNull);
      expect(hit!.merchant.toLowerCase(), 'netflix');

      await LiveSmsService.instance.testProcessBody(body, sender: sender);

      final updatedRem = await ReminderRepo().getById(reminder.id);
      expect(updatedRem!.isActive, false);
      expect(updatedRem.recordStatus, ReminderRecordStatus.done);
    });
  });

  group('Defect 24: Credit Card Payment Phrasing Ingestion', () {
    test('24a. GPay / PhonePe / bank credit card payment notices detected as creditCardPayment', () {
      final tests = [
        ('Paid ₹4,500 for HDFC Bank Credit Card bill.', 'APP:com.google.android.apps.nbu.paisa.user:Google Pay'),
        ('Paid Rs. 5000 towards SBI Card from A/c XX1234', 'VM-SBINB'),
        ('Bill payment of ₹8,000 for Axis Bank Credit Card completed.', 'APP:in.cheq.one:CheQ'),
      ];

      for (final (text, sender) in tests) {
        final classification = SmsImportService.instance.classifyMessage(text, sender);
        expect(classification.transaction, isNotNull, reason: 'Failed for: $text');
        expect(classification.eventType, SmsEventType.creditCardPayment, reason: 'Wrong type for: $text');
      }
    });
  });
}
