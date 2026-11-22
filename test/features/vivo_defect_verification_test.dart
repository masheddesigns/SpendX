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
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/loan.dart';
import 'package:spend_x/models/reminder_model.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/services/sms_import_service.dart';
import 'package:spend_x/services/transaction_text_parser.dart';
import 'package:spend_x/domain/credit/credit_card_service.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/models/card_statement.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/features/streak/streak_engine.dart';
import 'package:spend_x/domain/finance/safe_to_spend.dart';
import 'package:spend_x/domain/finance/money.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/services/balance_attribution.dart';
import 'package:spend_x/services/cross_channel_deduplication_service.dart';
import 'package:spend_x/data/repositories/review_repo.dart';
import 'package:spend_x/models/review_item.dart';
import 'package:spend_x/features/review_queue/providers/review_providers.dart';
import 'package:spend_x/services/entity_consolidation_service.dart';
import 'package:spend_x/core/utils/merchant_extractor.dart';
import 'package:spend_x/features/merchant_rules/data/merchant_rule_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/shared/widgets/glass/spendx_transaction_tile.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/core/utils/category_classifier.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_review_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/services/data_audit_service.dart';
import 'package:spend_x/services/inbox_audit_service.dart';
import 'package:spend_x/utils/app_format.dart';

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

    test('1d_2. Groww AutoPay debit failed notification detection', () {
      const sender = 'APP:com.nextbillion.groww:Autopay debit failed for GROWW INVEST TECH PRIVATE LIMITED STOCKS SIP';
      const body = 'Autopay debit failed for GROWW INVEST TECH PRIVATE LIMITED STOCKS SIP: Autopay debit of ₹1000.00 by GROWW INVEST TECH PRIVATE LIMITED STOCKS SIP for your account XXXXXX9331 has failed. Click to check details.';

      final classification = SmsImportService.instance.classifyMessage(body, sender);
      expect(classification.eventType, SmsEventType.failed);
      expect(classification.transaction, isNull, reason: 'Failed autopay must never create phantom expense transaction');
      expect(classification.failedObligation, isNotNull);
      expect(classification.failedObligation!.title, 'Groww Stocks SIP');
      expect(classification.failedObligation!.amount, 1000.0);
      expect(classification.failedObligation!.last4, '9331');
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
      final now = DateTime.now();
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final dateStr = '${now.day}-${months[now.month - 1]}';
      final bankBody = 'Rs 250 debited from A/c XX1234 to Chai Point on $dateStr UPI/431528123456';

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

  group('Defect 25: Cross-Source Payment App vs Bank SMS Deduplication & Balance Ingestion', () {
    test('25a. Google Pay incoming payment followed by Jio Payments Bank SMS deduplicates and updates balance', () async {
      // 1. Google Pay push notification arrives first (on 10-Nov-2026)
      const gpaySender = 'APP:com.google.android.apps.nbu.paisa.user:Google Pay';
      const gpayBody = 'RAVEENDRAN K paid you ₹6,000.00';

      final res1 = await LiveSmsService.instance.testProcessBody(
        gpayBody,
        sender: gpaySender,
        messageDate: DateTime(2026, 11, 10, 10, 30),
      );
      expect(res1.added, true);
      expect(res1.transaction, isNotNull);
      expect(res1.transaction!.amount, 6000.0);
      expect(res1.transaction!.type, 'income');
      expect(res1.transaction!.notes, 'Raveendran K');

      final initialTxCount = (await TransactionRepo().getAll()).where((t) => t.type != 'opening_balance' && t.type != 'reconciliation').length;

      // 2. Jio Payments Bank SMS arrives seconds later with account last4 and balance
      const jioSender = 'JX-JIOPBS-S';
      const jioBody = 'A/c x3284 credited with Rs. 6000.00 on 10-Nov-2026. Bal: Rs. 12742.91. - JPBL';

      final res2 = await LiveSmsService.instance.testProcessBody(jioBody, sender: jioSender);
      // Must NOT add duplicate transaction!
      expect(res2.added, false);

      final postTxCount = (await TransactionRepo().getAll()).where((t) => t.type != 'opening_balance' && t.type != 'reconciliation').length;
      expect(postTxCount, initialTxCount, reason: 'Duplicate transaction was inserted!');

      // Bank account balance must be updated to 12742.91
      final accounts = await AccountRepo().getAll();
      final jioAcc = accounts.where((a) => a.last4 == '3284').firstOrNull;
      expect(jioAcc, isNotNull);
      expect(jioAcc!.balance, 12742.91);

      // Existing transaction must be enriched with the Jio account ID
      final allTxns = await TransactionRepo().getAll();
      final incomeTx = allTxns.firstWhere((t) => t.amount == 6000.0);
      expect(incomeTx.accountId, jioAcc.id);
      expect(incomeTx.notes, 'Raveendran K');
    });

    test('25b. Repeated balance statement does not produce oscillating duplicate reconciliation records', () async {
      const jioSender = 'JX-JIOPBS-S';
      const jioBody = 'A/c x3284 credited with Rs. 6000.00 on 10-Nov-2026. Bal: Rs. 12742.91. - JPBL';

      // First attempt creates account and sets balance
      final res1 = await LiveSmsService.instance.testProcessBody(jioBody, sender: jioSender);
      expect(res1.added, true);

      // Second attempt to process the exact same message body must be ignored as duplicate
      final res2 = await LiveSmsService.instance.testProcessBody(jioBody, sender: jioSender);
      expect(res2.added, false);

      // Account balance remains stable at 12742.91
      final accounts = await AccountRepo().getAll();
      final jioAcc = accounts.where((a) => a.last4 == '3284').firstOrNull;
      expect(jioAcc, isNotNull);
      expect(jioAcc!.balance, 12742.91);
    });
  });

  group('Defect 26: Expanded Transaction Reference (UTR / RRN / Order ID) Parsing & Ingestion', () {
    test('26a. Correctly extracts UTR, RRN, IMPS ref and UPI slash references', () {
      final t1 = TransactionTextParser.parse('Paid Rs. 450 to Uber via UPI/628001122334/Uber. Ref: 628001122334');
      expect(t1.refId, '628001122334');

      final t2 = TransactionTextParser.parse('A/c *1234 debited for Rs 1200 on 10-Nov-26. UTR No. 431526789012. Avl Bal Rs 5000');
      expect(t2.refId, '431526789012');

      final t3 = TransactionTextParser.parse('Rs. 2500 debited from A/c 5678. RRN: 624952623558. Ref no. 624952623558.');
      expect(t3.refId, '624952623558');

      final t4 = TransactionTextParser.parse('Payment of Rs 999 to Amazon successful. Order ID: OD884920482019');
      expect(t4.refId, 'OD884920482019');

      final t5 = TransactionTextParser.parse('IMPS Ref No 512345678901 for Rs. 3500.00 to JOHN DOE completed');
      expect(t5.refId, '512345678901');
    });

    test('26b. Ingests externalRef and deduplicates subsequent messages with same reference', () async {
      const sms1 = 'A/c *3284 debited for Rs 500.00 on 10-Nov-26. UPI/628001122334/Swiggy. UTR: 628001122334. Avl Bal Rs 12242.91';
      final res1 = await LiveSmsService.instance.testProcessBody(sms1, sender: 'VM-JIOBNK');
      expect(res1.added, true);
      expect(res1.transaction, isNotNull);
      expect(res1.transaction!.externalRef, '628001122334');

      // Second message with identical UTR must be deduplicated
      const sms2 = 'Your bank a/c was debited with Rs 500.00 for UPI transaction. Ref no 628001122334.';
      final res2 = await LiveSmsService.instance.testProcessBody(sms2, sender: 'VK-UPIBNK');
      expect(res2.added, false);
    });
  });

  group('Defect 27: Credit Card Repayment Flow, Statement Due Decrement & Reminder Settlement', () {
    test('27a. processPayment creates canonical credit_payment transaction, decrements statement balance and settles reminder', () async {
      // 1. Setup a bank account and credit card
      final bankId = await AccountRepo().insertAccount(BankAccount(
        name: 'HDFC Savings Account',
        bank: 'HDFC',
        last4: '4321',
        accountType: 'savings',
        balance: 25000.0,
      ));

      final cardId = await CreditRepo().insert(CreditCard(
        name: 'HDFC Millennia',
        bank: 'HDFC Bank',
        last4: '9988',
        limitAmount: 100000.0,
        usedAmount: 5000.0,
        lastStatementBalance: 5000.0,
        dueDay: 25,
      ));

      // 2. Insert initial reminder for credit card due
      final reminderRepo = ReminderRepo();
      await reminderRepo.insertGlobalReminder(Reminder(
        id: 'credit_due_$cardId',
        type: ReminderType.credit,
        title: 'Credit Card Due: HDFC Millennia',
        linkedEntityId: cardId,
        dueDate: DateTime.now().add(const Duration(days: 10)),
        amount: 5000.0,
        isActive: true,
        status: ReminderStatus.upcoming,
        recordStatus: ReminderRecordStatus.pending,
        sourceType: ReminderSourceType.credit,
        sourceId: cardId,
      ).toMap());

      // 3. Process payment of 5000 towards the card
      final creditService = CreditCardService();
      await creditService.processPayment(
        cardId: cardId,
        paymentAmount: 5000.0,
        date: DateTime.now(),
        accountId: bankId,
        note: 'Payment to HDFC Millennia',
      );

      // 4. Verify canonical transaction exists in transactions table with flow
      final allTxns = await TransactionRepo().getAll();
      final paymentTx = allTxns.firstWhere((t) => t.type == 'credit_payment' && t.amount == 5000.0);
      expect(paymentTx.accountId, bankId);
      expect(paymentTx.relatedEntityId, cardId);
      expect(paymentTx.source, 'credit_card_payment');

      // 5. Verify statement balance was decremented to 0 in credit_cards table
      final updatedCard = await CreditRepo().getCard(cardId);
      expect(updatedCard, isNotNull);
      expect(updatedCard!.lastStatementBalance, 0.0);

      // 6. Verify reminder is marked done/inactive
      final updatedReminder = await reminderRepo.getById('credit_due_$cardId');
      expect(updatedReminder, isNotNull);
      expect(updatedReminder!.recordStatus, ReminderRecordStatus.done);
      expect(updatedReminder.isActive, false);
    });
  });

  group('Defect 28: Homepage Dates, Chronological Forward Waypoints, and Streak/Rhythm Calculation', () {
    test('28a. StreakEngine computeStreak tracks consecutive active days dynamically', () {
      final engine = StreakEngine();
      final now = DateTime(2026, 11, 11, 10, 0, 0); // Wednesday Nov 11
      final today = DateTime(2026, 11, 11);
      final yesterday = DateTime(2026, 11, 10);
      final twoDaysAgo = DateTime(2026, 11, 9);

      // Case 1: Transactions logged on yesterday (Nov 10) and today (Nov 11)
      final txnsActive = [
        Transaction(
          id: 't1',
          userId: 'u1',
          type: 'expense',
          amount: 250.0,
          date: yesterday.add(const Duration(hours: 14)), // Nov 10, 2 PM
          notes: 'Grocery',
          createdAt: yesterday,
          updatedAt: yesterday,
        ),
        Transaction(
          id: 't2',
          userId: 'u1',
          type: 'income',
          amount: 6000.0,
          date: today.add(const Duration(hours: 9)), // Nov 11, 9 AM
          notes: 'Freelance credit',
          createdAt: today,
          updatedAt: today,
        ),
      ];

      expect(engine.computeStreak(transactions: txnsActive, now: now), 2);

      // Case 2: Morning check before today's activity is logged (yesterday had activity)
      final txnsPendingToday = [
        Transaction(
          id: 't3',
          userId: 'u1',
          type: 'expense',
          amount: 150.0,
          date: yesterday.add(const Duration(hours: 12)),
          notes: 'Lunch',
          createdAt: yesterday,
          updatedAt: yesterday,
        ),
      ];

      // Streak stays alive from yesterday (1 day), not wiped out to 0!
      expect(engine.computeStreak(transactions: txnsPendingToday, now: now), 1);

      // Case 3: 3-day consecutive run (Nov 9, Nov 10, Nov 11)
      final txnsThreeDays = [
        ...txnsActive,
        Transaction(
          id: 't4',
          userId: 'u1',
          type: 'expense',
          amount: 50.0,
          date: twoDaysAgo.add(const Duration(hours: 18)),
          notes: 'Chai',
          createdAt: twoDaysAgo,
          updatedAt: twoDaysAgo,
        ),
      ];

      expect(engine.computeStreak(transactions: txnsThreeDays, now: now), 3);

      // Case 4: Missed both yesterday and today -> streak lapses to 0
      final txnsLapsed = [
        Transaction(
          id: 't5',
          userId: 'u1',
          type: 'expense',
          amount: 500.0,
          date: twoDaysAgo.add(const Duration(hours: 10)),
          notes: 'Old bill',
          createdAt: twoDaysAgo,
          updatedAt: twoDaysAgo,
        ),
      ];

      expect(engine.computeStreak(transactions: txnsLapsed, now: now), 0);
    });

    test('28b. Forward journey waypoints are strictly chronologically monotonic without duplicate today nodes', () {
      final now = DateTime(2026, 11, 11, 10, 0, 0); // Nov 11
      final today = DateTime(now.year, now.month, now.day);

      final commitments = [
        CommitmentItem(
          title: 'Airtel Broadband Overdue',
          amount: Money.fromRupees(999),
          dueDate: DateTime(2026, 10, 29), // 13 days overdue
          type: 'bill',
          isOverdue: true,
        ),
        CommitmentItem(
          title: 'Groww Stocks SIP',
          amount: Money.fromRupees(2000),
          dueDate: today, // Due Today (Nov 11)
          type: 'bill',
        ),
        CommitmentItem(
          title: 'Tata Neu Credit Card',
          amount: Money.fromRupees(12500),
          dueDate: DateTime(2026, 11, 19), // Future 8 days out
          type: 'credit_card',
        ),
        CommitmentItem(
          title: 'Electricity Bill',
          amount: Money.fromRupees(1800),
          dueDate: DateTime(2026, 11, 25), // Future 14 days out
          type: 'bill',
        ),
      ];

      // Partition logic as used in SafeToSpendCard
      final overdueItems = commitments.where((c) {
        final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
        return c.isOverdue || due.isBefore(today);
      }).toList();

      final dueTodayItems = commitments.where((c) {
        final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
        return !c.isOverdue && due.isAtSameMomentAs(today);
      }).toList();

      final futureItems = commitments.where((c) {
        final due = DateTime(c.dueDate.year, c.dueDate.month, c.dueDate.day);
        return !c.isOverdue && due.isAfter(today);
      }).toList()..sort((a, b) => a.dueDate.compareTo(b.dueDate));

      // Overdue is partitioned separately
      expect(overdueItems.length, 1);
      expect(overdueItems.first.title, 'Airtel Broadband Overdue');

      // Due Today is anchored to Today node
      expect(dueTodayItems.length, 1);
      expect(dueTodayItems.first.title, 'Groww Stocks SIP');

      // Forward waypoints strictly start with the NEXT FUTURE date
      final nextBill = futureItems.firstOrNull;
      final secondBill = futureItems.length > 1 ? futureItems[1] : null;

      expect(nextBill, isNotNull);
      expect(nextBill!.title, 'Tata Neu Credit Card');
      expect(nextBill.dueDate, DateTime(2026, 11, 19));

      expect(secondBill, isNotNull);
      expect(secondBill!.title, 'Electricity Bill');
      expect(secondBill.dueDate, DateTime(2026, 11, 25));

      // Strict forward chronological monotonicity:
      // Today (Nov 11) < Next Bill (Nov 19) < Second Bill (Nov 25) < Month End (Nov 30)
      expect(today.isBefore(nextBill.dueDate), isTrue);
      expect(nextBill.dueDate.isBefore(secondBill.dueDate), isTrue);
      expect(secondBill.dueDate.isBefore(DateTime(2026, 11, 30)), isTrue);
    });
  });

  group('Defect 29: Foreign Currency Spend vs Available Limit Guard', () {
    test('29a. Air Arabia foreign currency spend does NOT extract Avl Limit as amount', () {
      const sms = 'AED 2,508.28 spent using ICICI Bank Card XX5007 on 04-Oct-26 on AIR ARABIA AUH. Avl Limit: INR 83,397.13. If not you, call 1800 2662/SMS BLOCK 5007 to 9215676766.';
      final parsed = TransactionTextParser.parse(sms);
      expect(parsed, isNotNull);
      // Must NOT extract the available limit of 83397.13 as the transaction amount!
      expect(parsed!.amount, isNot(83397.13));
      expect(parsed.amount, closeTo(2508.28, 0.01));
      expect(parsed.isCredit, isFalse);
    });

    test('29b. SmsImportService._extractAmount guards against Avl Limit and Bal prefixes', () {
      const sms = 'INR 1,366.26 spent using ICICI Bank Card XX5007 on 06-Nov-26 on AMAZON PAY IN E. Avl Limit: INR 79,449.39.';
      final parsed = TransactionTextParser.parse(sms);
      expect(parsed, isNotNull);
      expect(parsed!.amount, closeTo(1366.26, 0.01));
      expect(parsed.amount, isNot(79449.39));
    });
  });

  group('Defect 30: Statement Repayments Netting & Due Calculation', () {
    test('30a. Statement repayments within 10 days before statement are correctly netted', () async {
      // 1. Create ICICI card
      final card = CreditCard(
        id: 'test_icici_5007',
        name: 'ICICI Bank Credit Card',
        bank: 'ICICI Bank',
        last4: '5007',
        limitAmount: 200000.0,
        billingDay: 9,
        dueDay: 20,
        usedAmount: 30126.61,
        lastStatementBalance: 91760.35,
      );
      await CreditRepo().insert(card);

      // Statement generated 09-Nov-26 17:56: 91,760.35
      final stmtDate = DateTime(2026, 11, 9, 17, 56);
      await CreditRepo().insertStatement(CardStatement(
        id: 'stmt_icici_nov26',
        cardId: card.id,
        startDate: DateTime(2026, 10, 9),
        endDate: stmtDate,
        statementAmount: 91760.35,
        minimumDue: 4590.00,
        generatedDate: stmtDate,
      ));

      // 2. Insert repayments around statement date:
      // - Nov 08 14:15: 15,000
      // - Nov 09 06:01: 17,000
      // - Nov 11 13:46: 31,000
      final payments = [
        (15000.0, DateTime(2026, 11, 8, 14, 15)),
        (17000.0, DateTime(2026, 11, 9, 6, 1)),
        (31000.0, DateTime(2026, 11, 11, 13, 46)),
      ];

      for (var i = 0; i < payments.length; i++) {
        final p = payments[i];
        final tx = Transaction(
          id: 'pay_test_$i',
          userId: 'test_user',
          amount: p.$1,
          type: 'credit_payment',
          categoryId: 'cat_bills',
          date: p.$2,
          notes: 'Payment towards ICICI Card XX5007',
          relatedEntityId: card.id,
        );
        await TransactionRepo().insert(tx);
      }

      // Query repayments in the 10-day statement window using canonical CreditRepo
      final windowStart = stmtDate.subtract(const Duration(days: 10));
      final cardTxns = await CreditRepo().getTransactions(card.id);
      double totalRepaid = 0.0;
      for (final t in cardTxns) {
        if (t.type == 'payment' || t.type == 'credit_payment') {
          if (t.date.isAfter(windowStart) || t.date.isAtSameMomentAs(windowStart)) {
            totalRepaid += t.amount;
          }
        }
      }

      expect(totalRepaid, 63000.0);
      final remainingDue = (91760.35 - totalRepaid).clamp(0.0, 91760.35);
      expect(remainingDue, closeTo(28760.35, 0.01));
    });
  });

  group('Remediation: Vivo Audit Defects & Invariants (Section 9)', () {
    test('1. Apay Wallet debit parsing, clean display title, and structured refId', () {
      const text = 'Your Apay Wallet balance is debited for INR 87.00. Reference Number is 668881518401';
      final parsed = TransactionTextParser.parse(text);

      expect(parsed.amount, 87.0);
      expect(parsed.isCredit, false);
      expect(parsed.merchant, 'Amazon Pay Wallet');
      expect(parsed.refId, '668881518401');

      final displayTitle = cleanTransactionDisplayTitle(parsed.merchant!);
      expect(displayTitle, 'Amazon Pay Wallet');
      expect(displayTitle, isNot(contains('debited for INR')));
    });

    test('2. Credit-card repayment acknowledgement parsing (ICICI)', () {
      const text = 'Payment of Rs 23,551.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System';
      final parsed = TransactionTextParser.parse(text);

      expect(parsed.amount, 23551.0);
      expect(parsed.last4, '5007');
      expect(parsed.merchant, 'ICICI Bank Card Repayment');

      final classification = SmsImportService.instance.classifyMessage(text, 'VM-ICICIB');
      expect(classification.eventType, SmsEventType.creditCardPayment);

      final displayTitle = cleanTransactionDisplayTitle(text, isCcPayment: true);
      expect(displayTitle, contains('ICICI Bank'));
    });

    test('3. Credit-card repayment acknowledgement parsing (HDFC)', () {
      const text = 'Payment of Rs 31,000.00 has been received on your HDFC Bank Credit Card';
      final parsed = TransactionTextParser.parse(text);

      expect(parsed.amount, 31000.0);
      expect(parsed.merchant, 'HDFC Bank Card Repayment');

      final classification = SmsImportService.instance.classifyMessage(text, 'HDFCBK');
      expect(classification.eventType, SmsEventType.creditCardPayment);

      final displayTitle = cleanTransactionDisplayTitle(text, isCcPayment: true);
      expect(displayTitle, contains('HDFC Bank'));
    });

    test('4. PolicyBazaar confirmation receipt deduplicated against card spend', () async {
      // 1. Process card spend first
      final cardSpendCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:pb_spend_1',
        sourceChannel: SourceChannel.sms,
        sender: 'JT-EDGE',
        body: '₹4515.00 paid from Edge CSB Bank RuPay Credit Card to POLICYBAZAAR on 20-Nov-2026',
        amountMinorUnits: 451500,
        direction: PostingDirection.debit,
        timestamp: DateTime(2026, 11, 20, 13, 14),
        merchant: 'PolicyBazaar',
        eventType: CanonicalEventType.cardPurchase,
      );

      final spendResult = await CrossChannelDeduplicationService()
          .processWithConflictResolution(candidate: cardSpendCandidate, db: db);
      expect(spendResult.isNewEventCreated, true);

      // 2. Process merchant confirmation receipt
      final receiptCandidate = IncomingTransactionCandidate(
        sourceRecordId: 'SRC:TELEPHONY_SMS:pb_receipt_1',
        sourceChannel: SourceChannel.sms,
        sender: 'POLICYBAZAAR',
        body: 'Hi Sivek K Raveendran, Payment of Rs. 4515 is successful for the purchase of your Twowheeler policy. ... - PolicyBazaar',
        amountMinorUnits: 451500,
        direction: PostingDirection.debit,
        timestamp: DateTime(2026, 11, 20, 13, 14, 30),
        merchant: 'PolicyBazaar',
        eventType: CanonicalEventType.expense,
      );

      final receiptResult = await CrossChannelDeduplicationService()
          .processWithConflictResolution(candidate: receiptCandidate, db: db);

      // Must be merged as duplicate, NOT create a second expense!
      expect(receiptResult.isStrongMatchMerged, true);
      expect(receiptResult.eventId, spendResult.eventId);

      // Verify canonical ledger contains exactly one economic event
      final events = await db.query(TablesV24.economicEvents);
      expect(events.length, 1);
    });

    test('5. Credit-card bill reminder: BOBCARD One', () {
      const text = 'Your BOBCARD One Credit Card bill of Rs. 2,778.88 is ready. Pay by 05 Dec, 2026';
      final classification = SmsImportService.instance.classifyMessage(text, 'BOBCARD');

      expect(classification.eventType, SmsEventType.billReminder);
      expect(classification.transaction, isNull);
      expect(classification.upcomingObligation, isNotNull);
      expect(classification.upcomingObligation!.amount, 2778.88);
      expect(classification.upcomingObligation!.dueDate, DateTime(2026, 12, 5));
    });

    test('6. Credit-card bill reminder: Edge CSB RuPay', () {
      const text = 'Your Edge CSB Bank RuPay Credit Card bill for Rs.2640.76 has been generated';
      final classification = SmsImportService.instance.classifyMessage(text, 'JT-EDGE');

      expect(classification.eventType, SmsEventType.billReminder);
      expect(classification.transaction, isNull);
      expect(classification.upcomingObligation, isNotNull);
      expect(classification.upcomingObligation!.amount, 2640.76);
    });

    test('7. Credit-card bill reminder: ICICI XX5007 Statement is sent', () {
      const text = 'ICICI Bank Credit Card XX5007 Statement is sent ... Total of Rs 91,760.35 ... is due by 20-NOV-26';
      final classification = SmsImportService.instance.classifyMessage(text, 'ICICIB');

      expect(classification.eventType, SmsEventType.billReminder);
      expect(classification.transaction, isNull);
      expect(classification.upcomingObligation, isNotNull);
      expect(classification.upcomingObligation!.amount, 91760.35);
      expect(classification.upcomingObligation!.dueDate, DateTime(2026, 11, 20));
      expect(classification.upcomingObligation!.last4, '5007');
    });

    test('8. Due date vs transaction date separation', () {
      const text = 'Total of Rs 91,760.35 is due by 20-NOV-26. Transaction on 10-Nov-2026';
      final txDate = TransactionTextParser.extractDateFromText(text);
      expect(txDate, isNotNull);
      // Due date (20-Nov-26) must NOT be picked as transaction date!
      expect(txDate!.day, 10);
      expect(txDate.month, 11);
      expect(txDate.year, 2026);
    });

    test('9. Unconfigured wallet debit routes to Review Queue with clean title and notes', () async {
      // Ensure no wallet exists in DB
      final accounts = await AccountRepo().getAll();
      expect(accounts.any((a) => a.accountType == 'wallet'), false);

      const body = 'Your Apay Wallet balance is debited for INR 87.00. Reference Number is 668881518401';
      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: 'QC-AMAZON',
        sourceRecordId: 'SRC:TELEPHONY_SMS:apay_test_1',
      );

      // Must NOT be auto-inserted into transactions
      expect(res.added, false);

      // Review Queue candidate check
      final reviewItems = await ReviewRepo().getPending();
      final item = reviewItems.where((r) => r.parsed.amount == 87.0).firstOrNull;
      expect(item, isNotNull);
      expect(item!.parsed.merchant, 'Amazon Pay Wallet');
      expect(item.parsed.refId, '668881518401');

      final displayTitle = cleanTransactionDisplayTitle(item.parsed.merchant!);
      expect(displayTitle, 'Amazon Pay Wallet');
      expect(displayTitle, isNot(contains('{')));
      expect(displayTitle, isNot(contains('debited for INR')));
    });

    test('10. Verified card payment confirmation posts directly as credit_payment without routing to Review Queue', () async {
      // Insert ICICI card
      final card = CreditCard(
        id: 'card_icici_5007',
        name: 'ICICI Bank Credit Card',
        bank: 'ICICI Bank',
        last4: '5007',
        limitAmount: 100000.0,
        usedAmount: 30000.0,
      );
      await CreditRepo().insert(card);

      const body = 'Payment of Rs 23,551.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System';
      final res = await LiveSmsService.instance.testProcessBody(
        body,
        sender: 'VM-ICICIB',
        sourceRecordId: 'SRC:TELEPHONY_SMS:icici_repay_test_1',
      );

      // Verified card payment must post directly as credit_payment
      expect(res.added, true);
      expect(res.status, isNot('review'));
      expect(res.transaction, isNotNull);
      expect(res.transaction!.type, 'credit_payment');
      expect(res.transaction!.relatedEntityId, card.id);

      // Ensure no expense transaction was created on the card
      final txns = await TransactionRepo().getAll();
      expect(txns.where((t) => t.amount == 23551.0 && t.type == 'expense').isEmpty, true);
    });

    test('11. Double-entry postings validation for card repayments', () async {
      // Create card and bank
      final card = CreditCard(
        id: 'card_bob_1',
        name: 'Bank of Baroda Card',
        bank: 'Bank of Baroda',
        last4: '1234',
        limitAmount: 50000.0,
        usedAmount: 20000.0,
      );
      await CreditRepo().insert(card);

      final bank = BankAccount(
        id: 'acc_fed_1',
        name: 'Federal Bank',
        bank: 'Federal Bank',
        last4: '8434',
        accountType: 'savings',
        balance: 50000.0,
      );
      await AccountRepo().insertAccount(bank);

      final repayTx = Transaction(
        id: 'repay_canonical_1',
        userId: 'offline_user',
        amount: 2778.88,
        type: 'credit_payment',
        accountId: bank.id,
        relatedEntityId: card.id,
        date: DateTime(2026, 11, 20, 13, 18),
        notes: 'Payment to Bank of Baroda Card',
        source: 'credit_card_payment',
      );

      await FinancialTransactionService().createTransaction(repayTx);

      // Verify double-entry canonical postings
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [repayTx.id],
      );

      expect(postings.length, 2);

      final debitLeg = postings.firstWhere((p) => p['direction'] == 'debit');
      final creditLeg = postings.firstWhere((p) => p['direction'] == 'credit');

      // Debit leg reduces card liability
      expect(debitLeg['account_id'], card.id);
      expect(debitLeg['amount_minor_units'], 277888);

      // Credit leg reduces bank asset
      expect(creditLeg['account_id'], bank.id);
      expect(creditLeg['amount_minor_units'], 277888);

      // Sum(Debits) == Sum(Credits)
      expect(debitLeg['amount_minor_units'], creditLeg['amount_minor_units']);

      // ZERO expense postings
      final expenseAccounts = await db.query(
        TablesV24.accounts,
        where: 'account_type = ?',
        whereArgs: ['expense'],
      );
      final expenseIds = expenseAccounts.map((a) => a['id']).toSet();
      expect(postings.any((p) => expenseIds.contains(p['account_id'])), false);
    });

    test('12. Zero postings for bill reminders', () async {
      final initialEventsCount = (await db.query(TablesV24.economicEvents)).length;
      final initialPostingsCount = (await db.query(TablesV24.postings)).length;
      final initialTxnCount = (await TransactionRepo().getAll()).length;

      const billBody = 'Your BOBCARD One Credit Card bill of Rs. 2,778.88 is ready. Pay by 05 Dec, 2026';
      final res = await LiveSmsService.instance.testProcessBody(
        billBody,
        sender: 'BOBCARD',
        sourceRecordId: 'SRC:TELEPHONY_SMS:bob_reminder_1',
      );

      expect(res.added, false);

      final finalEventsCount = (await db.query(TablesV24.economicEvents)).length;
      final finalPostingsCount = (await db.query(TablesV24.postings)).length;
      final finalTxnCount = (await TransactionRepo().getAll()).length;

      expect(finalEventsCount, initialEventsCount);
      expect(finalPostingsCount, initialPostingsCount);
      expect(finalTxnCount, initialTxnCount);
    });
  });

  group('Group 9: Comprehensive Remediation for Ingestion, Display, Dates & Account Attribution', () {
    test('1. Card repayment display title extracts clean bank name without sentence duplication', () {
      const text = 'Payment of Rs 23,551.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System';
      final title = cleanTransactionDisplayTitle(text, isCcPayment: true);
      expect(title, 'Payment to ICICI Bank');
      expect(title, isNot(contains('Payment of Rs')));
      expect(title, isNot(contains('{')));
    });

    test('2. Apay and policy confirmation display titles are completely sanitized', () {
      const apayText = '{"body":"Your Apay Wallet balance is debited for INR 87.00. Reference Number is 668881518401"}';
      expect(cleanTransactionDisplayTitle(apayText), 'Amazon Pay Wallet');

      const policyText = 'Hi Sivek K Raveendran, Payment of Rs. 4,515.00 has been received towards policy renewal';
      expect(cleanTransactionDisplayTitle(policyText), 'Policy Payment');

      const rawSentText = 'Rs. 5000.00 Sent from x3284 on 11-Nov to Merchant';
      final cleanSent = cleanTransactionDisplayTitle(rawSentText);
      expect(cleanSent, isNot(contains('Sent from')));
    });

    test('3. Exact message timestamp is preserved end-to-end even when body lacks printed date', () async {
      final specificDate = DateTime(2026, 11, 15, 10, 30);
      const apayBody = 'Your Apay Wallet balance is debited for INR 40.00. Reference Number is 99887766';
      
      final parsed = TransactionTextParser.parse(
        apayBody,
        source: 'sms',
        messageTimestamp: specificDate,
      );

      // Must inherit specificDate, NOT DateTime.now()
      expect(parsed.date.year, 2026);
      expect(parsed.date.month, 11);
      expect(parsed.date.day, 15);
      expect(parsed.date.hour, 10);
      expect(parsed.date.minute, 30);
    });

    test('4. Approving Apay Wallet item from Review Queue auto-links to Amazon Pay Wallet (no unlinked account)', () async {
      final rRepo = ReviewRepo();
      final item = ReviewItem(
        id: 'rev_apay_wallet_link_test',
        rawSource: 'Your Apay Wallet balance is debited for INR 100.00. Reference Number is apay_ref_test_unique_991823',
        parsed: ParsedTransaction(
          amount: 100.0,
          isCredit: false,
          rawText: 'Your Apay Wallet balance is debited for INR 100.00. Reference Number is apay_ref_test_unique_991823',
          date: DateTime(2026, 11, 14, 15, 20),
          merchant: 'Amazon Pay Wallet',
          refId: 'apay_ref_test_unique_991823',
          source: 'sms',
        ),
        confidence: 0.85,
      );

      await rRepo.insert(item);
      await approveReviewItem(item: item);

      // Verify transaction inserted
      final txs = await TransactionRepo().getAll();
      final createdTx = txs.where((t) => t.amount == 100.0 && t.externalRef?.contains('apay_ref_test_unique_991823') == true).firstOrNull;
      expect(createdTx, isNotNull);
      expect(createdTx!.accountId, isNotNull);

      // Verify the linked account is the Amazon Pay Wallet, NOT null or sys_suspense_transfer
      final linkedAccount = await AccountRepo().getById(createdTx.accountId!);
      expect(linkedAccount, isNotNull);
      expect(linkedAccount!.name, 'Amazon Pay Wallet');
      expect(linkedAccount.accountType, 'wallet');
    });

    test('5. Multi-issuer statements (Kotak, IndusInd, Scapia, RBL, Amex) classified as bill reminders', () {
      final statements = [
        'Your Kotak Bank Credit Card statement is generated. Total amount due Rs. 14,500.00 by 12-Dec-2026',
        'IndusInd Bank Credit Card XX9988 statement is ready. Total due Rs 8,230.00 payable by 18-Dec-2026',
        'Scapia Federal Credit Card bill for Rs. 5,120.00 has been generated. Due date: 22-Dec-2026',
        'Your RBL Bank Credit Card statement of Rs. 3,450.00 is due on 25-Dec-2026',
        'Amex Card ending 1004: Statement is ready. Total of Rs 42,000.00 is due by 30-Dec-2026',
      ];

      for (final stmt in statements) {
        final classification = SmsImportService.instance.classifyMessage(stmt, 'BANKCC');
        expect(classification.eventType, SmsEventType.billReminder, reason: 'Failed for: $stmt');
        expect(classification.transaction, isNull, reason: 'Must not create transaction for: $stmt');
        expect(classification.upcomingObligation, isNotNull);
      }
    });
  });

  group('Remediation: Vivo Live Defects (Nov 21 Inspection)', () {
    test('1. Merchant extraction case-insensitivity & sender ID filter', () {
      const hdfcCardSms =
          'Spent Rs.31000 On HDFC Bank Card 6366 At DREAMPLUG TECHNOLOGIES On 2026-11-05:14:49:06. Bal: Rs. 142000.00. - HDFCBK';
      final parsed = TransactionTextParser.parse(hdfcCardSms, source: 'sms');

      expect(parsed.amount, 31000.0);
      expect(parsed.last4, '6366');
      expect(parsed.merchant, 'CRED'); // Canonical via DREAMPLUG TECHNOLOGIES alias
      expect(parsed.merchant, isNot(contains('AD-HDFCBK-S')));
      expect(parsed.merchant, isNot(contains('HDFCBK')));
    });

    test('2. Credit card repayment recognition from bank UPI & card confirmations', () {
      // A. Bank UPI debits to OneCard, Jupiter, and CRED Club
      const fedToOneCard =
          'Debited Rs 2778.88 from a/c X8434 on 06-11-2026 14:15:30 via UPI to OneCard Ref: 631122334455';
      final classOneCard = SmsImportService.instance.classifyMessage(fedToOneCard, 'JK-FEDBNK-T');
      expect(classOneCard.eventType, SmsEventType.creditCardPayment);

      const fedToJupiter =
          'Debited Rs 2640.76 from a/c X8434 on 06-11-2026 14:20:10 via UPI to Jupiter Ref: 631122334456';
      final classJupiter = SmsImportService.instance.classifyMessage(fedToJupiter, 'JK-FEDBNK-T');
      expect(classJupiter.eventType, SmsEventType.creditCardPayment);

      const fedToCred =
          'Debited Rs 31000.00 from a/c X8434 on 05-11-2026 14:50:00 via UPI to CRED Club Ref: 631122334457';
      final classCred = SmsImportService.instance.classifyMessage(fedToCred, 'JK-FEDBNK-T');
      expect(classCred.eventType, SmsEventType.creditCardPayment);

      // B. Card confirmation receipts
      const oneCardReceipt =
          'Hola! that was sweet. We have received payment against your OneCard for Rs. 2,778.88. Avl Limit: INR 85,000.00';
      final classOneCardReceipt = SmsImportService.instance.classifyMessage(oneCardReceipt, 'TX-BOBONE-S');
      expect(classOneCardReceipt.eventType, SmsEventType.creditCardPayment);

      const jupiterReceipt =
          'Your payment of Rs 2640.76 for your Edge CSB Bank RuPay Credit Card was successful. Available limit is Rs 82,933.13';
      final classJupiterReceipt = SmsImportService.instance.classifyMessage(jupiterReceipt, 'AD-JTEDGE-S');
      expect(classJupiterReceipt.eventType, SmsEventType.creditCardPayment);
    });

    test('3. Merchant confirmation receipts without bank account do not create orphan expenses', () {
      const polBazReceipt =
          'Hi Sivek K Raveendran, Payment of Rs. 4515 is successful for the purchase of your Twowheeler policy. - PolicyBazaar';
      final classPolBaz = SmsImportService.instance.classifyMessage(polBazReceipt, 'JX-POLBAZ-S');
      expect(classPolBaz.eventType, SmsEventType.infoOnly);

      const districtReceipt =
          'Hurray! You are heading to the cinema. Your booking for Inception of Rs. 371.52 is confirmed. Enjoy the show! - District';
      final classDistrict = SmsImportService.instance.classifyMessage(districtReceipt, 'JX-DSTRKT-S');
      expect(classDistrict.eventType, SmsEventType.infoOnly);
    });

    test('4. Balance Attribution resolves CSB / Edge CSB / Jupiter and BOBCARD / OneCard correctly', () {
      final cards = [
        CreditCard(
          id: 'crd_csb_2834',
          name: 'Edge CSB RuPay',
          bank: 'CSB Bank',
          last4: '2834',
          limitAmount: 100000.0,
          usedAmount: 2640.76,
        ),
        CreditCard(
          id: 'crd_onecard_1234',
          name: 'BOBCARD OneCard',
          bank: 'Bank of Baroda',
          last4: '1234',
          limitAmount: 150000.0,
          usedAmount: 2778.88,
        ),
      ];

      // CSB / Jupiter attribution
      final csbAttr = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'csb',
        accounts: const [],
        cards: cards,
      );
      expect(csbAttr.matched, isTrue);
      expect(csbAttr.instrumentId, 'crd_csb_2834');

      final jupiterAttr = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'jupiter',
        accounts: const [],
        cards: cards,
      );
      expect(jupiterAttr.matched, isTrue);
      expect(jupiterAttr.instrumentId, 'crd_csb_2834');

      // BOB / OneCard attribution
      final oneCardAttr = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'onecard',
        accounts: const [],
        cards: cards,
      );
      expect(oneCardAttr.matched, isTrue);
      expect(oneCardAttr.instrumentId, 'crd_onecard_1234');

      final bobAttr = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'bobcard',
        accounts: const [],
        cards: cards,
      );
      expect(bobAttr.matched, isTrue);
      expect(bobAttr.instrumentId, 'crd_onecard_1234');
    });

    test('8c. Generalized Co-branded Credit Card and UPI Card Handle Recognition', () {
      final cards = [
        CreditCard(
          id: 'crd_kiwi',
          name: 'Kiwi Axis RuPay Credit Card',
          bank: 'Axis Bank',
          last4: '9901',
          limitAmount: 100000.0,
          usedAmount: 5000.0,
        ),
        CreditCard(
          id: 'crd_scapia',
          name: 'Scapia Federal Credit Card',
          bank: 'Federal Bank',
          last4: '8802',
          limitAmount: 200000.0,
          usedAmount: 12000.0,
        ),
        CreditCard(
          id: 'crd_tataneu',
          name: 'Tata Neu Infinity HDFC Credit Card',
          bank: 'HDFC Bank',
          last4: '7703',
          limitAmount: 150000.0,
          usedAmount: 8500.0,
        ),
        CreditCard(
          id: 'crd_flipkart',
          name: 'Flipkart Axis Bank Credit Card',
          bank: 'Axis Bank',
          last4: '6604',
          limitAmount: 120000.0,
          usedAmount: 3200.0,
        ),
      ];

      // Kiwi attribution to Axis Bank Kiwi card
      final kiwiAttr = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'kiwi',
        accounts: const [],
        cards: cards,
      );
      expect(kiwiAttr.matched, isTrue);
      expect(kiwiAttr.instrumentId, 'crd_kiwi');

      // Scapia attribution to Federal Bank Scapia card
      final scapiaAttr = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'scapia',
        accounts: const [],
        cards: cards,
      );
      expect(scapiaAttr.matched, isTrue);
      expect(scapiaAttr.instrumentId, 'crd_scapia');

      // Tata Neu attribution to HDFC card
      final tataAttr = BalanceAttribution.resolve(
        kind: BalanceKind.creditCard,
        last4: null,
        bankKeyword: 'tataneu',
        accounts: const [],
        cards: cards,
      );
      expect(tataAttr.matched, isTrue);
      expect(tataAttr.instrumentId, 'crd_tataneu');

      // UPI to Credit Card VPA handle payment detection
      const upiCcDebit = 'Rs. 5000.00 debited from A/C XX1234 to cc.9876543210@axisbank on 21-Nov-2026';
      final upiClass = SmsImportService.instance.classifyMessage(upiCcDebit, 'AD-AXISBK-S');
      expect(upiClass.eventType, SmsEventType.creditCardPayment);

      // Merchant receipts without account info classified as infoOnly
      const swiggyReceipt = 'Your Swiggy order of Rs. 450 is confirmed! Delivering in 30 mins.';
      final swiggyClass = SmsImportService.instance.classifyMessage(swiggyReceipt, 'VM-SWIGGY-S');
      expect(swiggyClass.eventType, SmsEventType.infoOnly);

      const zomatoReceipt = 'Your Zomato order of Rs. 620 has been placed successfully.';
      final zomatoClass = SmsImportService.instance.classifyMessage(zomatoReceipt, 'VK-ZOMATO-S');
      expect(zomatoClass.eventType, SmsEventType.infoOnly);

      const irctcReceipt = 'Ticket booked successfully. PNR 1234567890. Total Fare: Rs. 1450.50';
      final irctcClass = SmsImportService.instance.classifyMessage(irctcReceipt, 'AD-IRCTC-S');
      expect(irctcClass.eventType, SmsEventType.infoOnly);
    });

    test('8d. Comprehensive Credit Card Repayment & Paying Bank Extraction', () async {
      await DatabaseLifecycleCoordinator.instance.waitUntilWritable();
      final accountRepo = AccountRepo();
      final creditRepo = CreditRepo();

      // Setup user accounts: Federal Bank savings + Scapia card + OneCard
      final fedAccount = BankAccount(
        id: 'acc_test_fed_9988',
        name: 'Federal Bank A/c',
        bank: 'Federal Bank',
        last4: '9988',
        balance: 50000.0,
      );
      await accountRepo.insertAccount(fedAccount);

      final scapiaCard = CreditCard(
        id: 'crd_test_scapia_1122',
        name: 'Scapia Federal Card',
        bank: 'Federal Bank',
        last4: '1122',
        limitAmount: 150000.0,
        usedAmount: 10000.0,
      );
      await creditRepo.insert(scapiaCard);

      final oneCard = CreditCard(
        id: 'crd_test_onecard_3344',
        name: 'BOBCARD OneCard',
        bank: 'BOBCARD',
        last4: '3344',
        limitAmount: 100000.0,
        usedAmount: 15000.0,
      );
      await creditRepo.insert(oneCard);

      // 1. Bank debit SMS paying OneCard from Federal Bank
      const fedDebitSms =
          'Dear Customer, Rs 5,000.00 debited from your Federal Bank A/c ending in 9988 towards OneCard CC bill on 21-Nov-2026. Ref UPI/123456789012';

      final classification = SmsImportService.instance.classifyMessage(fedDebitSms, 'AD-FEDBNK-S');
      expect(classification.eventType, SmsEventType.creditCardPayment);

      // Process through LiveSmsService
      final outcome = await LiveSmsService.instance.testProcessBody(
        fedDebitSms,
        sender: 'AD-FEDBNK-S',
      );

      expect(outcome.added, isTrue);
      expect(outcome.transaction, isNotNull);
      final tx = outcome.transaction!;
      expect(tx.type, 'credit_payment');
      expect(tx.accountId, fedAccount.id); // Debited paying bank
      expect(tx.relatedEntityId, oneCard.id); // Target card is OneCard (NOT Scapia!)

      // 2. Loan EMI upcoming obligation detection
      const loanEmiSms =
          'Dear Customer, EMI of Rs. 14,250.00 for your Home Loan A/C ending 7766 is due on 05-Dec-2026. Please maintain sufficient balance in your account.';
      final loanHit = SmsImportService.instance.detectUpcomingObligation(loanEmiSms, 'AD-HDFCBK-S');
      expect(loanHit, isNotNull);
      expect(loanHit!.amount, 14250.00);
      expect(loanHit.reminderType, ReminderType.loan);
      expect(loanHit.isMandate, isTrue);
      expect(loanHit.dueDate.day, 5);
      expect(loanHit.dueDate.month, 12);
    });

    test('8e. Robust Indian Market Wallet Auto-Creation, Failed Payment Rejection & Card Payment Deduplication', () async {
      await DatabaseLifecycleCoordinator.instance.waitUntilWritable();
      final reviewRepo = ReviewRepo();
      final initialReviewCount = await reviewRepo.getPendingCount();

      // 1. Failed payment attempt MUST be rejected and NEVER enter Review Queue
      const failedPaymentSms =
          'We could not process your payment of ₹ 2100.00 for your Edge CSB Bank RuPay Credit Card bill. You can repay using this link https://gs.im/JTEDGE/e/wLfaGyWdLuv or pay via Jupiter app.';
      final failedClassification = SmsImportService.instance.classifyMessage(failedPaymentSms, 'AD-JTEDGE-S');
      expect(failedClassification.eventType, SmsEventType.failed);

      final failedOutcome = await LiveSmsService.instance.testProcessBody(
        failedPaymentSms,
        sender: 'AD-JTEDGE-S',
      );
      expect(failedOutcome.added, isFalse);
      expect(failedOutcome.status, isNot('review'));

      // 2. Amazon Pay Wallet debit auto-creates Amazon Pay Wallet account and does NOT go to Review Queue
      const apaySms =
          'Your Apay Wallet balance is debited for INR 10.00. Reference Number is 666774731336. If not you? call 180012001637 - SMS via Juspay';
      final apayOutcome = await LiveSmsService.instance.testProcessBody(
        apaySms,
        sender: 'VM-JUSPAY-S',
      );
      expect(apayOutcome.added, isTrue);
      expect(apayOutcome.status, isNot('review'));
      expect(apayOutcome.transaction, isNotNull);
      expect(apayOutcome.transaction!.accountId, isNotNull);

      final accounts = await AccountRepo().getAll();
      final apayAcc = accounts.where((a) => a.accountType == 'wallet' && a.name.contains('Amazon Pay')).firstOrNull;
      expect(apayAcc, isNotNull);
      expect(apayOutcome.transaction!.accountId, apayAcc!.id);

      // 3. Card payment confirmation receipt with known card (ICICI 5007) posts directly without Review Queue
      final iciciCard = CreditCard(
        id: 'crd_test_icici_5007',
        name: 'ICICI Bank Card',
        bank: 'ICICI Bank',
        last4: '5007',
        limitAmount: 200000.0,
        usedAmount: 25000.0,
      );
      await CreditRepo().insert(iciciCard);

      const iciciPaymentReceipt =
          'Payment of Rs 13,000.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System on 12-OCT-26.';
      final iciciOutcome = await LiveSmsService.instance.testProcessBody(
        iciciPaymentReceipt,
        sender: 'AD-ICICIB-S',
      );
      expect(iciciOutcome.added, isTrue);
      expect(iciciOutcome.status, isNot('review'));
      expect(iciciOutcome.transaction, isNotNull);
      expect(iciciOutcome.transaction!.type, 'credit_payment');
      expect(iciciOutcome.transaction!.relatedEntityId, iciciCard.id);

      // 4. Duplicate confirmation receipt for the same card payment merges without duplicate
      final duplicateOutcome = await LiveSmsService.instance.testProcessBody(
        iciciPaymentReceipt,
        sender: 'AD-ICICIB-S',
      );
      expect(duplicateOutcome.added, isFalse);
      expect(duplicateOutcome.status, 'matched');

      // Review Queue count did NOT increase for these verified Indian market transactions
      final finalReviewCount = await reviewRepo.getPendingCount();
      expect(finalReviewCount, initialReviewCount);
    });

    test('8f. Vivo Live Review Queue Remediation & Real-World Indian Merchant Extraction', () async {
      await DatabaseLifecycleCoordinator.instance.waitUntilWritable();

      // Setup user's OneCard xx2510
      final oneCard = CreditCard(
        id: 'crd_test_onecard_2510',
        name: 'BOBCARD OneCard',
        bank: 'BOBCARD',
        last4: '2510',
        limitAmount: 100000.0,
        usedAmount: 5000.0,
      );
      await CreditRepo().insert(oneCard);

      // 1. Tata Unistore (₹2,101.88) spend on BOBCARD OneCard 2510
      const tataUnistoreSms =
          'Superb choice! Rs. 2,101.88 spent at Tata Unistore Ltd on your BOBCARD One Credit Card xxXX2510. Reward points added. To dispute, click: https://1crd.in/OneCrd/HQL';
      final pTata = TransactionTextParser.parse(tataUnistoreSms);
      expect(pTata.amount, 2101.88);
      expect(pTata.last4, '2510');
      // Must NOT extract "Dispute" as merchant
      expect(pTata.merchant, isNot('Dispute'));
      expect(pTata.merchant, 'Tata CLiQ');
      // Category must resolve to Shopping
      final catTata = CategoryClassifier.detect(
        text: '$tataUnistoreSms ${pTata.merchant}',
        type: 'expense',
      );
      expect(catTata, 'Shopping');

      // 2. K P A Petroleum (₹937.84) fuel spend on BOBCARD OneCard 2510
      const petrolSms =
          "Tank's full! Rs. 937.84 spent at K P A Petroleum, Nilambur on your BOBCARD One Credit Card xxXX2510. Reward points added. To dispute, click: https://1crd.in/OneCrd/HQL";
      final pPetrol = TransactionTextParser.parse(petrolSms);
      expect(pPetrol.amount, 937.84);
      expect(pPetrol.last4, '2510');
      // Must NOT extract "Dispute" as merchant
      expect(pPetrol.merchant, isNot('Dispute'));
      expect(pPetrol.merchant, contains('Petroleum'));
      // Category must resolve to Transport (Fuel)
      final catPetrol = CategoryClassifier.detect(
        text: '$petrolSms ${pPetrol.merchant}',
        type: 'expense',
      );
      expect(catPetrol, 'Transport');

      // 3. YouTube (₹299.00) subscription spend on BOBCARD OneCard 2510
      const ytSms =
          "That's a hit! Rs. 299.00 spent at Youtube Cybs Si with your BOBCARD One Credit Card xxXX2510. Reward points added. To dispute, click: https://1crd.in/OneCrd/HQL";
      final pYt = TransactionTextParser.parse(ytSms);
      expect(pYt.amount, 299.00);
      expect(pYt.last4, '2510');
      expect(pYt.merchant, 'YouTube');
      // Category must resolve to Subscriptions
      final catYt = CategoryClassifier.detect(
        text: '$ytSms ${pYt.merchant}',
        type: 'expense',
      );
      expect(catYt, 'Subscriptions');

      // 4. Verification that autoResolvePendingReviewQueue fixes existing ReviewItem with 'Dispute' merchant
      final reviewRepo = ReviewRepo();
      final staleItem = ReviewItem(
        id: 'rev_test_dispute_repair',
        rawSource: tataUnistoreSms,
        parsed: ParsedTransaction(
          amount: 2101.88,
          isCredit: false,
          rawText: tataUnistoreSms,
          date: DateTime.now(),
          merchant: 'Dispute',
          last4: '2510',
          bankName: 'BOBCARD',
          method: 'card',
        ),
        confidence: 0.88,
      );
      await reviewRepo.insert(staleItem);

      // Run autoResolvePendingReviewQueue
      await autoResolvePendingReviewQueue();

      // The stale item should have been auto-approved to the OneCard
      final pending = await reviewRepo.getPending();
      expect(pending.any((item) => item.id == 'rev_test_dispute_repair'), isFalse);

      final txRepo = TransactionRepo();
      final txs = await txRepo.getAll();
      final resolvedTx = txs.where((t) => t.amount == 2101.88).firstOrNull;
      expect(resolvedTx, isNotNull);
      expect(resolvedTx!.accountId, oneCard.id);
      expect(resolvedTx.notes, contains('Tata CLiQ'));
    });

    test('8g. Generalized Real-World Indian Banking SMS Wordings, Corporate Biller Entities & Trailing Text Guards', () async {
      // 1. "Spent on <Card> at <Merchant>" (Axis Bank style)
      const axisSpendSms =
          'INR 500.00 spent on Axis Bank Card ending 1234 at SWIGGY on 21-Nov-2026. Avl Lmt INR 1,20,000.00. To dispute, SMS BLOCK CC 1234 to 5676782';
      final pAxis = TransactionTextParser.parse(axisSpendSms);
      expect(pAxis.amount, 500.00);
      expect(pAxis.last4, '1234');
      expect(pAxis.merchant, 'Swiggy');
      final catAxis = CategoryClassifier.detect(text: '$axisSpendSms ${pAxis.merchant}', type: 'expense');
      expect(catAxis, 'Food');

      // 2. Corporate legal entity: Bundl Technologies -> Swiggy
      const bundlSms =
          'Rs. 420.00 paid to BUNDL TECHNOLOGIES PVT LTD via UPI ref 123456789012. Bal Rs 15000. If not you, call 18001200 - HDFC Bank';
      final pBundl = TransactionTextParser.parse(bundlSms);
      expect(pBundl.amount, 420.00);
      expect(pBundl.merchant, 'Swiggy');
      final catBundl = CategoryClassifier.detect(text: '$bundlSms ${pBundl.merchant}', type: 'expense');
      expect(catBundl, 'Food');

      // 3. Corporate legal entity: KiranaKart Technologies -> Zepto
      const zeptoSms =
          'Rs. 320.00 debited from A/c 8434 to KIRANAKART TECHNOLOGIES on 21-Nov-2026. Ref 9988776655. Avl Bal Rs 25000 - Federal Bank';
      final pZepto = TransactionTextParser.parse(zeptoSms);
      expect(pZepto.amount, 320.00);
      expect(pZepto.merchant, 'Zepto');
      final catZepto = CategoryClassifier.detect(text: '$zeptoSms ${pZepto.merchant}', type: 'expense');
      expect(catZepto, 'Groceries');

      // 4. Trailing helpline noise & block instructions: Decathlon
      const decathlonSms =
          'Rs. 1,499.00 spent at DECATHLON SPORTS using HDFC Bank Card 5678. Not you? Call 18002586161 or SMS BLOCK CC 5678 to 7308080808';
      final pDecathlon = TransactionTextParser.parse(decathlonSms);
      expect(pDecathlon.amount, 1499.00);
      expect(pDecathlon.merchant, 'Decathlon');
      final catDecathlon = CategoryClassifier.detect(text: '$decathlonSms ${pDecathlon.merchant}', type: 'expense');
      expect(catDecathlon, 'Shopping');

      // 5. Fuel provider: Bharat Petroleum
      const bpclSms =
          'Rs 2,000.00 spent at BHARAT PETROLEUM CORP on your Card 2510. Avl Lmt Rs 90,000. Reward points added.';
      final pBpcl = TransactionTextParser.parse(bpclSms);
      expect(pBpcl.amount, 2000.00);
      expect(pBpcl.merchant, 'Bharat Petroleum');
      final catBpcl = CategoryClassifier.detect(text: '$bpclSms ${pBpcl.merchant}', type: 'expense');
      expect(catBpcl, 'Transport');

      // 6. Healthcare & Pharmacy: Apollo Pharmacy
      const apolloSms =
          'Rs 850.00 paid to APOLLO PHARMACY from A/c 8434 on 21-Nov-2026. Ref 1122334455';
      final pApollo = TransactionTextParser.parse(apolloSms);
      expect(pApollo.amount, 850.00);
      expect(pApollo.merchant, 'Apollo Pharmacy');
      final catApollo = CategoryClassifier.detect(text: '$apolloSms ${pApollo.merchant}', type: 'expense');
      expect(catApollo, 'Health');

      // 7. Investment & Broking: Zerodha
      const zerodhaSms =
          'Rs 5,000.00 debited towards ZERODHA BROKING via UPI ref 9876543210. Bal Rs 45000. Not you? Call bank';
      final pZerodha = TransactionTextParser.parse(zerodhaSms);
      expect(pZerodha.amount, 5000.00);
      expect(pZerodha.merchant, 'Zerodha');
      final catZerodha = CategoryClassifier.detect(text: '$zerodhaSms ${pZerodha.merchant}', type: 'income');
      expect(catZerodha, 'Investment');
    });

    test('8h. Comprehensive Indian Ecosystem: ATM Cash Withdrawals, Transit, QSR, Groceries, Retail, Streaming & Clearing Codes', () async {
      // 1. ATM Cash Withdrawals
      const sbiAtmSms =
          'Dear SBI User, your A/C 1234 has been debited by Rs.2,000.00 on 21Nov24 at STATE BANK ATM. Avl Bal Rs: 15,240.23';
      final pSbiAtm = TransactionTextParser.parse(sbiAtmSms);
      expect(pSbiAtm.amount, 2000.00);
      expect(pSbiAtm.merchant, 'ATM Cash Withdrawal');
      final catSbiAtm = CategoryClassifier.detect(text: '$sbiAtmSms ${pSbiAtm.merchant}', type: 'expense');
      expect(catSbiAtm, 'Others');

      const hdfcAtmSms =
          'Rs 5,000.00 withdrawn from HDFC Bank Card ending 1234 at HDFC ATM on 20-NOV-24. Avl Bal: INR 25,400.00';
      final pHdfcAtm = TransactionTextParser.parse(hdfcAtmSms);
      expect(pHdfcAtm.amount, 5000.00);
      expect(pHdfcAtm.merchant, 'ATM Cash Withdrawal');
      final catHdfcAtm = CategoryClassifier.detect(text: '$hdfcAtmSms ${pHdfcAtm.merchant}', type: 'expense');
      expect(catHdfcAtm, 'Others');

      const iciciAtmSms =
          'A/C 1234 debited for Rs 1000.00 on 15-Nov-24. Info: ATM*CASH WDL. Avl Bal: INR 12,345.00';
      final pIciciAtm = TransactionTextParser.parse(iciciAtmSms);
      expect(pIciciAtm.amount, 1000.00);
      expect(pIciciAtm.merchant, 'ATM Cash Withdrawal');

      // 2. Transit & Mobility: Namma Yatri, BluSmart, Park+
      const nammaYatriSms =
          'Paid Rs. 145.00 to MOVING TECH INNOVATIONS via UPI. Ref 1234567890';
      final pNamma = TransactionTextParser.parse(nammaYatriSms);
      expect(pNamma.amount, 145.00);
      expect(pNamma.merchant, 'Namma Yatri');
      final catNamma = CategoryClassifier.detect(text: '$nammaYatriSms ${pNamma.merchant}', type: 'expense');
      expect(catNamma, 'Transport');

      const bluSmartSms =
          'Rs 350.00 debited for BLUSMART MOBILITY on Card 2510';
      final pBlu = TransactionTextParser.parse(bluSmartSms);
      expect(pBlu.amount, 350.00);
      expect(pBlu.merchant, 'BluSmart');
      final catBlu = CategoryClassifier.detect(text: '$bluSmartSms ${pBlu.merchant}', type: 'expense');
      expect(catBlu, 'Transport');

      const parkPlusSms =
          'Rs. 100 spent at PARK+ FASTAG recharge using card 2510';
      final pPark = TransactionTextParser.parse(parkPlusSms);
      expect(pPark.amount, 100.00);
      expect(pPark.merchant, 'Park+');
      final catPark = CategoryClassifier.detect(text: '$parkPlusSms ${pPark.merchant}', type: 'expense');
      expect(catPark, 'Transport');

      // 3. QSR & Dining: EatSure (Rebel Foods), Third Wave Coffee
      const rebelSms =
          'Rs. 420.00 paid to REBEL FOODS via UPI ref 8877665544';
      final pRebel = TransactionTextParser.parse(rebelSms);
      expect(pRebel.amount, 420.00);
      expect(pRebel.merchant, 'EatSure');
      final catRebel = CategoryClassifier.detect(text: '$rebelSms ${pRebel.merchant}', type: 'expense');
      expect(catRebel, 'Food');

      const thirdWaveSms =
          'Rs. 240.00 spent at THIRD WAVE COFFEE on your Card 2510';
      final pThirdWave = TransactionTextParser.parse(thirdWaveSms);
      expect(pThirdWave.amount, 240.00);
      expect(pThirdWave.merchant, 'Third Wave Coffee');
      final catThirdWave = CategoryClassifier.detect(text: '$thirdWaveSms ${pThirdWave.merchant}', type: 'expense');
      expect(catThirdWave, 'Food');

      // 4. Groceries & Essentials: Country Delight (Beejapuri), Licious, DMart
      const countryDelightSms =
          'Rs. 890.00 debited to BEEJAPURI via UPI ref 334455';
      final pCd = TransactionTextParser.parse(countryDelightSms);
      expect(pCd.amount, 890.00);
      expect(pCd.merchant, 'Country Delight');
      final catCd = CategoryClassifier.detect(text: '$countryDelightSms ${pCd.merchant}', type: 'expense');
      expect(catCd, 'Groceries');

      const liciousSms =
          'Rs. 550.00 paid to LICIOUS via UPI';
      final pLicious = TransactionTextParser.parse(liciousSms);
      expect(pLicious.amount, 550.00);
      expect(pLicious.merchant, 'Licious');
      final catLicious = CategoryClassifier.detect(text: '$liciousSms ${pLicious.merchant}', type: 'expense');
      expect(catLicious, 'Groceries');

      const dmartSms =
          'Rs. 2,340.00 spent at DMART on your HDFC Card 6366';
      final pDmart = TransactionTextParser.parse(dmartSms);
      expect(pDmart.amount, 2340.00);
      expect(pDmart.merchant, 'DMart');
      final catDmart = CategoryClassifier.detect(text: '$dmartSms ${pDmart.merchant}', type: 'expense');
      expect(catDmart, 'Groceries');

      // 5. Retail & Fashion: Croma, Ikea
      const cromaSms =
          'Rs 15,999.00 spent at CROMA on Card 2510. Avl Lmt Rs 75,000';
      final pCroma = TransactionTextParser.parse(cromaSms);
      expect(pCroma.amount, 15999.00);
      expect(pCroma.merchant, 'Croma');
      final catCroma = CategoryClassifier.detect(text: '$cromaSms ${pCroma.merchant}', type: 'expense');
      expect(catCroma, 'Shopping');

      const ikeaSms =
          'Rs. 3,500.00 spent at IKEA INDIA using card 2510';
      final pIkea = TransactionTextParser.parse(ikeaSms);
      expect(pIkea.amount, 3500.00);
      expect(pIkea.merchant, 'Ikea');
      final catIkea = CategoryClassifier.detect(text: '$ikeaSms ${pIkea.merchant}', type: 'expense');
      expect(catIkea, 'Shopping');

      // 6. Streaming: SonyLIV, JioCinema
      const sonyLivSms =
          'Rs. 299.00 debited for SONYLIV on Card 2510';
      final pSony = TransactionTextParser.parse(sonyLivSms);
      expect(pSony.amount, 299.00);
      expect(pSony.merchant, 'SonyLIV');
      final catSony = CategoryClassifier.detect(text: '$sonyLivSms ${pSony.merchant}', type: 'expense');
      expect(catSony, 'Subscriptions');

      const jioCinemaSms =
          'Rs. 89.00 spent at JIOCINEMA on card 2510';
      final pJioCinema = TransactionTextParser.parse(jioCinemaSms);
      expect(pJioCinema.amount, 89.00);
      expect(pJioCinema.merchant, 'JioCinema');
      final catJioCinema = CategoryClassifier.detect(text: '$jioCinemaSms ${pJioCinema.merchant}', type: 'expense');
      expect(catJioCinema, 'Subscriptions');

      // 7. EV Charging: Statiq
      const statiqSms =
          'Rs 150.00 paid to STATIQ via UPI';
      final pStatiq = TransactionTextParser.parse(statiqSms);
      expect(pStatiq.amount, 150.00);
      expect(pStatiq.merchant, 'Statiq');
      final catStatiq = CategoryClassifier.detect(text: '$statiqSms ${pStatiq.merchant}', type: 'expense');
      expect(catStatiq, 'Transport');

      // 8. Gateway & Clearing Prefix Stripping: VPS*Tata Unistore, swiggy.payu
      const vpsSms =
          'Your A/C 8434 debited for Rs 450.00 at VPS*TATA UNISTORE ref 1234';
      final pVps = TransactionTextParser.parse(vpsSms);
      expect(pVps.amount, 450.00);
      expect(pVps.merchant, 'Tata CLiQ');
      final catVps = CategoryClassifier.detect(text: '$vpsSms ${pVps.merchant}', type: 'expense');
      expect(catVps, 'Shopping');

      const gatewaySms =
          'Paid Rs 350.00 to swiggy.payu on 21-Nov-2026';
      final pGateway = TransactionTextParser.parse(gatewaySms);
      expect(pGateway.amount, 350.00);
      expect(pGateway.merchant, 'Swiggy');
      final catGateway = CategoryClassifier.detect(text: '$gatewaySms ${pGateway.merchant}', type: 'expense');
      expect(catGateway, 'Food');
    });

    test('8i. Comprehensive Credit Card Number Masking, Sending (Repayments), Receiving (Spends & Dues) Ecosystem', () async {
      // 1. Masked Card Number Formats (Avoiding BIN prefix entrapment)
      const maskedStarSms =
          'Alert: Rs 937.84 spent on your Card 5424********2510 at BPCL Fuel Station. Avl Lmt Rs 75,000';
      final pMaskedStar = TransactionTextParser.parse(maskedStarSms);
      expect(pMaskedStar.amount, 937.84);
      expect(pMaskedStar.last4, '2510');
      expect(SmsImportService.extractCardLast4(maskedStarSms), '2510');

      const maskedDashesSms =
          'INR 1,450.00 charged on your Card 4512-XXXX-XXXX-6366 at SWIGGY. Avl Bal Rs 50,000';
      final pMaskedDashes = TransactionTextParser.parse(maskedDashesSms);
      expect(pMaskedDashes.amount, 1450.00);
      expect(pMaskedDashes.last4, '6366');
      expect(SmsImportService.extractCardLast4(maskedDashesSms), '6366');

      const maskedSpacesSms =
          'Rs. 500 spent on Card 5334 **** **** 2510 at SHELL PETROL';
      expect(SmsImportService.extractCardLast4(maskedSpacesSms), '2510');

      const amexSms =
          'Alert: INR 5,400 charged on your American Express Card ending 12005 at MAKE MY TRIP';
      expect(SmsImportService.extractCardLast4(amexSms), '12005');

      const dotsSms =
          'Rs. 890 spent on Card ending ...2510 at RELIANCE SMART';
      expect(SmsImportService.extractCardLast4(dotsSms), '2510');

      const colonSms =
          'Rs 1,200 spent on Card no: **6366 at CROMA';
      expect(SmsImportService.extractCardLast4(colonSms), '6366');

      // 2. Sending to Card (Bill Repayments) - Disambiguating Paying Account vs Target Card
      const repaymentDualSms =
          'Amount of Rs. 5000.00 debited from A/C XX8434 towards Credit Card ending 2510 on 21-Nov-26';
      expect(SmsImportService.extractCardLast4(repaymentDualSms), '2510');
      expect(SmsImportService.extractBankAccountLast4(repaymentDualSms), '8434');

      const weReceivedSms =
          'We have received payment of Rs 2,500.00 towards your OneCard ending 2510. Limit restored.';
      final pWeReceived = TransactionTextParser.parse(weReceivedSms);
      expect(pWeReceived.amount, 2500.00);
      expect(pWeReceived.merchant, 'OneCard Card Repayment');
      expect(SmsImportService.extractCardLast4(weReceivedSms), '2510');

      const autoDebitSms =
          'Auto-debit of INR 12,000.00 towards your Credit Card ending with 6366 was successful';
      final pAutoDebit = TransactionTextParser.parse(autoDebitSms);
      expect(pAutoDebit.amount, 12000.00);
      expect(pAutoDebit.merchant, 'Credit Card Repayment');
      expect(SmsImportService.extractCardLast4(autoDebitSms), '6366');

      // 3. Receiving on Card (Refunds, Surcharge Waivers & Fee Reversals)
      const surchargeSms =
          'Fuel surcharge waiver of Rs 23.50 credited to your Card 2510 on 21-Nov-2026';
      final cSurcharge = SmsImportService.instance.classifyMessage(surchargeSms, 'AD-BOBCRD-S');
      expect(cSurcharge.transaction, isNotNull);
      expect(cSurcharge.transaction!.isCredit, true);
      expect(cSurcharge.transaction!.last4, '2510');

      const cardCashbackSms =
          'Cashback of Rs 150.00 credited to your OneCard 2510';
      final cCashback = SmsImportService.instance.classifyMessage(cardCashbackSms, 'AD-ONECRD-S');
      expect(cCashback.transaction, isNotNull);
      expect(cCashback.transaction!.isCredit, true);
      expect(cCashback.transaction!.last4, '2510');

      // 4. Statements & Bill Generation
      const billDueSms =
          'Statement generated for your Credit Card ending 2510. Total Due: Rs 24,500.00, Min Due: Rs 1,500.00, Due Date: 15-Dec-2026';
      final cBill = SmsImportService.instance.classifyMessage(billDueSms, 'AD-BOBCRD-S');
      expect(cBill.upcomingObligation, isNotNull);
      expect(cBill.upcomingObligation!.amount, 24500.00);
      expect(cBill.upcomingObligation!.last4, '2510');
    });

    test('8j. Account Detail Ledger, Running Balances & Cash Self-Healing Reconciliation', () async {
      await DatabaseLifecycleCoordinator.instance.waitUntilWritable();
      final accountRepo = AccountRepo();
      final txRepo = TransactionRepo();

      final fedAccount = BankAccount(
        id: 'acc_test_fed_detail_8434',
        name: 'Federal Account',
        bank: 'Federal Bank',
        last4: '8434',
        balance: 50000.0,
      );
      await accountRepo.insertAccount(fedAccount);

      // Verify transactions for this account
      final tx1 = Transaction(
        id: 'tx_detail_inc_1',
        userId: 'user_1',
        amount: 10000.0,
        type: 'income',
        date: DateTime(2026, 11, 21, 10, 0),
        notes: 'Salary Credit',
        accountId: fedAccount.id,
      );
      final tx2 = Transaction(
        id: 'tx_detail_exp_2',
        userId: 'user_1',
        amount: 2500.0,
        type: 'expense',
        date: DateTime(2026, 11, 21, 12, 0),
        notes: 'Groceries',
        accountId: fedAccount.id,
      );
      final tx3 = Transaction(
        id: 'tx_detail_pay_3',
        userId: 'user_1',
        amount: 5000.0,
        type: 'credit_payment',
        date: DateTime(2026, 11, 21, 15, 0),
        notes: 'Card Repayment',
        accountId: fedAccount.id,
        relatedEntityId: 'crd_test_onecard_2510',
      );

      await txRepo.insert(tx1);
      await txRepo.insert(tx2);
      await txRepo.insert(tx3);

      final allTxns = await txRepo.getAll();
      final accountTxns = allTxns.where((t) => t.accountId == fedAccount.id || t.relatedEntityId == fedAccount.id).toList();
      accountTxns.sort((a, b) => b.date.compareTo(a.date));
      expect(accountTxns.length, 3);

      // Verify running balance calculation logic
      // Newest is tx3 (credit_payment 5000). Balance after tx3 is final balance (52,500).
      // Prior was tx2 (expense 2500). Balance before tx3 / after tx2 was 52,500 + 5000 = 57,500.
      // Prior was tx1 (income 10000). Balance before tx2 / after tx1 was 57,500 + 2500 = 60,000.
      const currentBalance = 52500.0;
      final Map<String, double> runningBalances = {};
      double rolling = currentBalance;
      for (final t in accountTxns) {
        runningBalances[t.id] = rolling;
        final bool isInflow = (t.isIncomeType && t.accountId == fedAccount.id) ||
            (t.isTransferType && t.relatedEntityId == fedAccount.id);
        final bool isOutflow = (t.isExpenseType && t.accountId == fedAccount.id) ||
            (t.isTransferType && t.accountId == fedAccount.id) ||
            (t.type == 'credit_payment' && t.accountId == fedAccount.id);

        if (isInflow) {
          rolling -= t.amount;
        } else if (isOutflow) {
          rolling += t.amount;
        }
      }

      expect(runningBalances[tx3.id], 52500.0);
      expect(runningBalances[tx2.id], 57500.0);
      expect(runningBalances[tx1.id], 60000.0);

      // Verify EntityConsolidationService reconciles any bogus CC payment mistakenly linked to Cash
      final bogusCashPayment = Transaction(
        id: 'tx_bogus_cash_pay',
        userId: 'user_1',
        amount: 31000.0,
        type: 'credit_payment',
        date: DateTime(2026, 11, 21, 14, 0),
        notes: 'Payment to ICICI Card',
        accountId: 'acc_cash_default',
        relatedEntityId: 'crd_test_onecard_2510',
      );
      await txRepo.insert(bogusCashPayment);

      final merged = await EntityConsolidationService.instance.consolidate();
      expect(merged >= 1, isTrue);

      final healedTx = await txRepo.getById('tx_bogus_cash_pay');
      expect(healedTx, isNotNull);
      expect(healedTx!.accountId, isNot('acc_cash_default'));
    });

    test('8k. Data Health Audit, Forex Recognition & NPS PRAN Review Queue Integrity', () async {
      // 1. Forex Formatting & Exchange Rate Recognition
      expect(AppFormat.extractForexFormatted('Air Arabia', 'Spent AED 2508.28 at AIR ARABIA AUH on Card 2510'), 'AED 2,508.28');
      expect(AppFormat.extractForexFormatted('OpenAI API', 'USD 20.00 debited from card'), 'USD 20.00');
      expect(AppFormat.extractForexFormatted('Dublin Coffee (EUR 15.50)'), 'EUR 15.50');
      expect(AppFormat.extractForexFormatted('Swiggy Order', 'Debited INR 450.00 from A/c 5432'), isNull);

      final fx = AppFormat.extractForexDetails('Air Arabia', 'Spent AED 2508.28 at AIR ARABIA AUH on Card 2510');
      expect(fx, isNotNull);
      expect(fx!.currencyCode, 'AED');
      expect(fx.rateToInr, 22.80);
      expect(fx.estimatedInr, closeTo(57188.78, 0.1));
      expect(fx.rateDisplay, '1 AED ≈ ₹22.80');

      // 2. DataAuditService: Transfers and CC repayments are NOT uncategorized expenses
      final txRepo = TransactionRepo();
      final transferTx = Transaction(
        id: 'tx_audit_transfer_1',
        userId: 'user_1',
        amount: 50000.0,
        type: 'transfer',
        date: DateTime.now(),
        notes: 'Transfer from Savings to Checking',
        accountId: 'acc_1',
        relatedEntityId: 'acc_2',
        categoryId: null, // Intentionally null in double-entry ledger
      );
      final ccPayTx = Transaction(
        id: 'tx_audit_ccpay_1',
        userId: 'user_1',
        amount: 25000.0,
        type: 'credit_payment',
        date: DateTime.now(),
        notes: 'Credit card bill settlement',
        accountId: 'acc_1',
        relatedEntityId: 'crd_1',
        categoryId: null, // Intentionally null in double-entry ledger
      );
      final trueUncatExpense = Transaction(
        id: 'tx_audit_expense_uncat',
        userId: 'user_1',
        amount: 1500.0,
        type: 'expense',
        date: DateTime.now(),
        notes: 'Unknown Store Purchase',
        accountId: 'acc_1',
        categoryId: null, // Genuine uncategorized expense
      );

      await txRepo.insert(transferTx);
      await txRepo.insert(ccPayTx);
      await txRepo.insert(trueUncatExpense);

      final auditIssues = await DataAuditService.instance.runAudit(force: true);
      final uncatIssue = auditIssues.where((i) => i.type == 'uncategorized').firstOrNull;
      expect(uncatIssue, isNotNull);
      // Only trueUncatExpense should be counted, NOT the 50,000 transfer or 25,000 cc payment
      expect(uncatIssue!.count, 1);
      expect(uncatIssue.transactionIds, contains('tx_audit_expense_uncat'));
      expect(uncatIssue.transactionIds, isNot(contains('tx_audit_transfer_1')));
      expect(uncatIssue.transactionIds, isNot(contains('tx_audit_ccpay_1')));

      // 3. Review candidate evidence hashing
      const sampleText = 'Dear Subscriber, contribution of Rs.409.00 has been credited to your PRAN 110023456789 towards NPS';
      final expectedFp = CanonicalTransactionAdapter.computeBodyFingerprint(sampleText);
      final item = ReviewItem(
        id: 'rev_test_nps_1',
        rawSource: sampleText,
        parsed: ParsedTransaction(
          amount: 409.0,
          isCredit: true,
          rawText: sampleText,
          date: DateTime(2026, 11, 21),
          bankName: 'PTNNPS',
          source: 'sms',
        ),
        confidence: 0.85,
        status: 'pending',
        createdAt: DateTime(2026, 11, 21),
      );

      final reviewRepo = ReviewRepo();
      await reviewRepo.insert(item);

      // Verify evidence was stored using normalized computeBodyFingerprint
      final eventRepo = CanonicalEventRepository();
      final evidence = await eventRepo.getEvidenceByFingerprint(expectedFp);
      expect(evidence, isNotNull);
      expect(evidence!.bodyFingerprint, expectedFp);

      // 4. Verify autoResolvePendingReviewQueue rejects NPS / PRAN items so queue clears
      await autoResolvePendingReviewQueue();
      final pendingAfter = await reviewRepo.getPending();
      expect(pendingAfter.any((i) => i.id == 'rev_test_nps_1'), isFalse);
    });

    test('8l. Indian Gateway Location Suffix Stripping, Dining/Pet/Airline Categorization, Spam Shield & Inter-Account Transfers', () async {
      // 1. Merchant Normalization & Gateway Suffix Stripping (RuPay, Jupiter, POS)
      const vvmSms =
          '₹2245.00 paid from your Edge CSB Bank RuPay Credit Card to VVM FOOD CHAIN LLP MALAPPURAM KLIN on 2026-11-08T18:46:40.140695+05:30 IST. To raise an issue, call 8655055086. Thank you for using Jupiter.';
      final parsedVvm = TransactionTextParser.parse(vvmSms);
      expect(parsedVvm.merchant, 'VVM Food Chain');
      final catVvm = CategoryClassifier.detect(text: vvmSms, type: 'expense');
      expect(catVvm, 'Food');

      const districtSms =
          '₹371.52 paid from your Edge CSB Bank RuPay Credit Card to DISTRICTMOVIES GURGOAN dlIN on 2026-11-16T22:25:52.944345+05:30 IST. To raise an issue, call 8655055086. Thank you for using Jupiter.';
      final parsedDistrict = TransactionTextParser.parse(districtSms);
      expect(parsedDistrict.merchant, 'District Movies');
      final catDistrict = CategoryClassifier.detect(text: districtSms, type: 'expense');
      expect(catDistrict, 'Entertainment');

      const cityFuelSms =
          'Debited Rs 1000.00 from a/c X8434 on 08Nov26 19:12 via UPI to CITY FUEL ST. Ref 631285771236.Bal Rs 17592.25. Not you?Call 18004251199 -Federal Bank';
      final parsedFuel = TransactionTextParser.parse(cityFuelSms);
      expect(parsedFuel.merchant, 'City Fuel Station');
      final catFuel = CategoryClassifier.detect(text: cityFuelSms, type: 'expense');
      expect(catFuel, 'Transport');

      const hotelAryaSms =
          'Debited Rs 515.00 from a/c X8434 on 11Nov26 21:15 via UPI to Hotel arya b. Ref 631556623901.Bal Rs 18097.25. Not you?Call 18004251199 -Federal Bank';
      final parsedArya = TransactionTextParser.parse(hotelAryaSms);
      expect(parsedArya.merchant, 'Hotel Arya');
      final catArya = CategoryClassifier.detect(text: hotelAryaSms, type: 'expense');
      expect(catArya, 'Food');

      const muddyPawsSms =
          'Debited Rs 10980.00 from a/c X8434 on 11Nov26 12:21 via UPI to Muddy Paws. Ref 631587075420.Bal Rs 6612.25. Not you?Call 18004251199 -Federal Bank';
      final parsedMuddy = TransactionTextParser.parse(muddyPawsSms);
      expect(parsedMuddy.merchant, 'Muddy Paws');
      final catMuddy = CategoryClassifier.detect(text: muddyPawsSms, type: 'expense');
      expect(catMuddy, 'Pets');

      // 2. Airline Categorization
      const airArabiaSms =
          'AED 2,508.28 spent using ICICI Bank Card XX5007 on 04-Oct-26 on AIR ARABIA AUH. Avl Limit: INR 83,397.13.';
      final catAirArabia = CategoryClassifier.detect(text: airArabiaSms, type: 'expense');
      expect(catAirArabia, 'Travel');

      // 3. Spam & Phishing Rejection Shield
      const fakeSalarySpam =
          'Your Salary Rs39800 was passed, absentinthe Working at home, Details at api.whatsapp.com/send?phone=5519984074499 Chanakyaa Law Academy';
      final spamClass = SmsImportService.instance.classifyMessage(fakeSalarySpam, 'AD-CLAONL-S');
      expect(spamClass.transaction, isNull);

      const bettingPromoSpam =
          'Parimatch: 5 Unreal Bonuses on Virtual Cricket! Deposit Rs 1,000+: http://txqn.run/dXixdH';
      final betClass = SmsImportService.instance.classifyMessage(bettingPromoSpam, '59039085');
      expect(betClass.transaction, isNull);

      // 4. Inter-Account Transfer Linking via Shared Reference
      final accRepo = AccountRepo();
      final jioAccId = await accRepo.insertAccount(
        BankAccount(
          name: 'Jio Payments Bank Account (..3284)',
          bank: 'Jio Payments Bank',
          accountType: 'savings',
          last4: '3284',
          balance: 50000.0,
        ),
      );
      final fedAccId = await accRepo.insertAccount(
        BankAccount(
          name: 'Federal Account (..8434)',
          bank: 'Federal Bank',
          accountType: 'savings',
          last4: '8434',
          balance: 10000.0,
        ),
      );

      final dedupService = CrossChannelDeduplicationService();
      final db = await AppDatabase.instance.database;

      // Leg 1: Debit from Jio Bank
      final leg1 = IncomingTransactionCandidate(
        sourceRecordId: 'SMS:JIO:IMPS:1',
        sourceChannel: SourceChannel.sms,
        amountMinorUnits: 4300000,
        direction: PostingDirection.debit,
        timestamp: DateTime(2026, 11, 11, 13, 2, 30),
        merchant: 'Sivek K Rave',
        accountId: jioAccId,
        externalReference: '631501071980',
        sender: 'JD-JIOPBS-S',
        body: 'Rs. 43000.00 Sent from x3284 on 11-Nov-2026 Info: IMPS/631501071980/Sivek K Rave Not you? Call 18008907070 - JPBL',
        eventType: CanonicalEventType.expense,
      );
      final res1 = await dedupService.processIncomingCandidate(candidate: leg1, txn: db);
      expect(res1.isNewEventCreated, isTrue);
      expect(res1.eventId, isNotNull);

      // Leg 2: Credit to Federal Bank sharing the exact same reference
      final leg2 = IncomingTransactionCandidate(
        sourceRecordId: 'SMS:FED:IMPS:2',
        sourceChannel: SourceChannel.sms,
        amountMinorUnits: 4300000,
        direction: PostingDirection.credit,
        timestamp: DateTime(2026, 11, 11, 13, 2, 50),
        merchant: 'Federal Bank',
        accountId: fedAccId,
        externalReference: '631501071980',
        sender: 'AX-FEDBNK-S',
        body: 'Rs 43000 credited to your A/c XX8434 via IMPS on 11NOV2026 13:02:50 IMPS Ref no 631501071980 Bal:Rs 49612.25 -Federal Bank',
        eventType: CanonicalEventType.income,
      );
      final res2 = await dedupService.processIncomingCandidate(candidate: leg2, txn: db);
      expect(res2.isNewEventCreated, isTrue);
      expect(res2.eventId, isNotNull);

      // Verify the canonical event was created as a linked Transfer
      final eventRepo = CanonicalEventRepository();
      final event = await eventRepo.getEvent(res2.eventId!);
      expect(event, isNotNull);
      expect(event!.canonicalType, CanonicalEventType.transfer);
      expect(event.reversalOfEventId, res1.eventId);

      // Verify double-entry postings: DR Federal Bank (asset), CR Jio Bank (asset)
      final postings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: [res2.eventId!],
        orderBy: 'sequence_number ASC',
      );
      expect(postings.length, 2);
      expect(postings[0]['account_id'], fedAccId);
      expect(postings[0]['direction'], 'debit');
      expect(postings[0]['amount_minor_units'], 4300000);
      expect(postings[1]['account_id'], jioAccId);
      expect(postings[1]['direction'], 'credit');
      expect(postings[1]['amount_minor_units'], 4300000);
    });

    test('Defect 26: Currency-less SBI UPI debit extracts amount, last4 and merchant', () {
      const body =
          'Dear UPI user A/C X9331 debited by 7291.17 on date 15Oct26 trf to OneCard Refno 665448950651 If not u? call-1800111109 for other services-18001234-SBI';
      final parsed = TransactionTextParser.parse(body);
      expect(parsed.amount, 7291.17);
      expect(parsed.last4, '9331');
      expect(parsed.isCredit, isFalse);
      expect(parsed.merchant, 'OneCard');

      final classification = SmsImportService.instance.classifyMessage(body, 'JD-SBIUPI-S');
      expect(classification.transaction?.amount, 7291.17);
      expect(classification.transaction?.last4, '9331');
      expect(classification.eventType, SmsEventType.creditCardPayment);
    });

    test('Defect 27: Jio Payments Bank UPI / IMPS with security text stripped', () {
      const upiBody =
          'Rs. 4000.00 Sent from x3284 on 14-Nov-2026 Info: UPI/DR/631888914315/Amazon Pay Not you? Call 18008907070 - JPBL';
      final parsedUpi = TransactionTextParser.parse(upiBody);
      expect(parsedUpi.amount, 4000.0);
      expect(parsedUpi.last4, '3284');
      expect(parsedUpi.merchant, 'Amazon Pay');

      const impsBody =
          'Rs. 43000.00 Sent from x3284 on 11-Nov-2026 Info: IMPS/631501071980/Sivek K Rave Not you? Call 18008907070 - JPBL';
      final parsedImps = TransactionTextParser.parse(impsBody);
      expect(parsedImps.amount, 43000.0);
      expect(parsedImps.last4, '3284');
      expect(parsedImps.merchant, 'Sivek K Rave');
    });

    test('Defect 28: MerchantExtractor and MerchantRuleRepo reject dates and months', () {
      expect(MerchantExtractor.extract('21-Nov-2026'), isEmpty);
      expect(MerchantExtractor.extract('21-Nov-2026 Info'), isEmpty);
      expect(MerchantRuleRepo.isValidKeyword('21-nov-2026'), isFalse);
      expect(MerchantRuleRepo.isValidKeyword('21-nov-2026 info'), isFalse);
      expect(MerchantRuleRepo.isValidKeyword('nov'), isFalse);
      expect(MerchantRuleRepo.isValidKeyword('november'), isFalse);
      expect(MerchantRuleRepo.isValidKeyword('swiggy'), isTrue);
    });

    test('Defect 29: Stale balance statement does not overwrite newer reconciliation', () async {
      final db = await AppDatabase.instance.database;
      final accountRepo = AccountRepo();

      // Create a test account
      final acc = BankAccount(
        name: 'Stale Check Bank Account',
        bank: 'Test Bank',
        last4: '7777',
        accountType: 'savings',
        balance: 1000.0,
        createdAt: DateTime.utc(2026, 10, 1),
      );
      final accId = await accountRepo.insertAccount(acc);

      // Newer reconciliation on Nov 20
      await accountRepo.updateBalance(
        accId,
        1500.0,
        messageDate: DateTime.utc(2026, 11, 20),
      );
      final newerDerived = await CanonicalAccountRepository().getDerivedBalance(accId);
      expect(newerDerived.toRupees, 1500.0);

      // Attempt to apply older historical balance from Oct 15
      await accountRepo.updateBalance(
        accId,
        500.0,
        messageDate: DateTime.utc(2026, 10, 15),
      );
      final derivedAfterStale = await CanonicalAccountRepository().getDerivedBalance(accId);
      // Balance MUST remain 1500.0 (stale Oct 15 update was skipped)
      expect(derivedAfterStale.toRupees, 1500.0);
    });

    test('Defect 30: Duplicate bank accounts with 6-digit vs 4-digit last4 are consolidated and anchored', () async {
      final accountRepo = AccountRepo();

      final acc1 = BankAccount(
        name: 'State Bank of India Account ...',
        bank: 'State Bank of India',
        accountType: 'savings',
        last4: '569331',
        balance: 315842.96,
      );
      await accountRepo.insertAccount(acc1);

      final acc2 = BankAccount(
        name: 'State Bank of India Account (.....)',
        bank: 'State Bank of India',
        accountType: 'savings',
        last4: '569331',
        balance: 28691.36,
      );
      await accountRepo.insertAccount(acc2);

      final preList = await accountRepo.getAccounts();
      expect(preList.where((a) => a.bank == 'State Bank of India').length, 2);

      final merged = await EntityConsolidationService.instance.consolidate();
      expect(merged, greaterThan(0));

      final postList = await accountRepo.getAccounts();
      final sbiAccounts = postList.where((a) => a.bank.toLowerCase().contains('sbi') || a.name.toLowerCase().contains('state bank')).toList();
      expect(sbiAccounts.length, 1);
      expect(sbiAccounts.first.balance, 21449.88);
    });

    test('Defect 31: Ingested notifications and SMS inherit envelope timestamp and avoid 12:00 AM midnight', () {
      final envelopeDate = DateTime(2026, 11, 21, 19, 34, 15);
      final rawText = 'A/c x3284 credited with Rs. 50.00 on 21-Nov-2026. Bal: Rs. 257.41. - JPBL';

      final parsed = TransactionTextParser.parse(
        rawText,
        source: 'notification',
        messageTimestamp: envelopeDate,
      );

      expect(parsed.amount, 50.0);
      expect(parsed.date.year, 2026);
      expect(parsed.date.month, 11);
      expect(parsed.date.day, 21);
      // Hours and minutes must match the envelope arrival time, NOT 00:00:00 (12:00 AM)
      expect(parsed.date.hour, 19);
      expect(parsed.date.minute, 34);
      expect(parsed.date.second, 15);
    });

    test('Defect 32: BankAccount supports investment asset types (stocks, mutual funds, gold, ppf, real estate)', () {
      expect(BankAccount.iconForType('stock'), 'trending_up');
      expect(BankAccount.iconForType('mutual_fund'), 'pie_chart');
      expect(BankAccount.iconForType('gold'), 'monetization_on');
      expect(BankAccount.iconForType('ppf'), 'savings');
      expect(BankAccount.iconForType('real_estate'), 'home_work');

      expect(BankAccount.colorForType('stock'), '#10B981');
      expect(BankAccount.colorForType('gold'), '#EAB308');
      expect(BankAccount.colorForType('mutual_fund'), '#EC4899');
    });
  });
}
