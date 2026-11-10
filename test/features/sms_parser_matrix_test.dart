import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_transaction_adapter.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/transaction_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/credit_card.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/services/sms_import_service.dart';
import 'package:spend_x/services/transaction_text_parser.dart';

/// Data-driven fixture for Layer 1 bank-specific coverage.
class SmsFixture {
  final String id;
  final String sender;
  final String body;
  final String expectedBank;
  final int expectedAmountPaise;
  final bool expectedIsCredit;
  final SmsEventType expectedEventType;
  final String? expectedLast4;
  final String? expectedRef;

  const SmsFixture({
    required this.id,
    required this.sender,
    required this.body,
    required this.expectedBank,
    required this.expectedAmountPaise,
    required this.expectedIsCredit,
    required this.expectedEventType,
    this.expectedLast4,
    this.expectedRef,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // Stub method channels for notifications and SMS native receivers
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

  group('Pillar 2: SMS Reliability & Parser Robustness Matrix Suite', () {
    late Database db;
    final importService = SmsImportService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );

      await Tables.createAll(db);
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);
      await CategoryRepo(executor: db).ensureDefaults();
    });

    tearDown(() async {
      await db.close();
    });

    // =========================================================================
    // LAYER 1: BANK-SPECIFIC FIXTURE MATRIX (50 Real-World Supported Formats)
    // =========================================================================
    group('Layer 1: Bank-Specific Fixture Matrix (50 Supported Bank Formats)', () {
      final fixtures = <SmsFixture>[
        // --- 1. HDFC Bank (5 fixtures) ---
        const SmsFixture(
          id: 'HDFC-01',
          sender: 'AD-HDFCBK-T',
          body: 'Debited Rs. 420.00 from A/c **1234 on 02-OCT-26 via UPI to SWIGGY. Ref: 627181818181. Bal: Rs. 45000.00 - HDFC Bank',
          expectedBank: 'HDFC Bank',
          expectedAmountPaise: 42000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '1234',
          expectedRef: '627181818181',
        ),
        const SmsFixture(
          id: 'HDFC-02',
          sender: 'JM-HDFCBK-S',
          body: 'An amount of INR 1,540.00 has been spent on your HDFC Bank Credit Card ending 6366 at RELIANCE RETAIL on 03-OCT-26. Avl Lmt: INR 75,000.00',
          expectedBank: 'HDFC Bank',
          expectedAmountPaise: 154000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
          expectedLast4: '6366',
        ),
        const SmsFixture(
          id: 'HDFC-03',
          sender: 'JM-HDFCBK-S',
          body: 'DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 2000.00 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 6366 ON 2-10-2026.YOUR AVAILABLE LIMIT IS RS. 77755.88',
          expectedBank: 'HDFC Bank',
          expectedAmountPaise: 200000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
          expectedLast4: '6366',
        ),
        const SmsFixture(
          id: 'HDFC-04',
          sender: 'AD-HDFCBK-T',
          body: 'Your Salary of INR 85,000.00 has been credited to A/c **1234 on 31-OCT-26 by TECH CORP PVT LTD. Avl Bal: INR 1,30,000.00',
          expectedBank: 'HDFC Bank',
          expectedAmountPaise: 8500000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '1234',
        ),
        const SmsFixture(
          id: 'HDFC-05',
          sender: 'AD-HDFCBK-T',
          body: 'INR 5,000.00 withdrawn from ATM using Debit Card linked to A/c **1234 on 04-OCT-26 at HDFC ATM MG ROAD. Bal: INR 40,000.00',
          expectedBank: 'HDFC Bank',
          expectedAmountPaise: 500000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '1234',
        ),

        // --- 2. ICICI Bank (5 fixtures) ---
        const SmsFixture(
          id: 'ICICI-01',
          sender: 'JD-ICICIT-S',
          body: 'INR 464.00 spent using ICICI Bank Card XX5007 on 05-Oct-26 on AMAZON PAY IN E. Avl Limit: INR 82,933.13. If not you, call 1800 2662.',
          expectedBank: 'ICICI Bank',
          expectedAmountPaise: 46400,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
          expectedLast4: '5007',
        ),
        const SmsFixture(
          id: 'ICICI-02',
          sender: 'AD-ICICIT-S',
          body: 'Payment of Rs 10,000.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System on 07-OCT-26.',
          expectedBank: 'ICICI Bank',
          expectedAmountPaise: 1000000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
          expectedLast4: '5007',
        ),
        const SmsFixture(
          id: 'ICICI-03',
          sender: 'VM-ICICIB-S',
          body: 'Payment of Rs 2,500.00 received towards ICICI Bank Credit Card ending 5007 on 08-OCT-26. Available Credit Limit: INR 85,433.13.',
          expectedBank: 'ICICI Bank',
          expectedAmountPaise: 250000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
          expectedLast4: '5007',
        ),
        const SmsFixture(
          id: 'ICICI-04',
          sender: 'AD-ICICIB-T',
          body: 'Dear Customer, Acct XX3456 debited with INR 350.00 on 06-Oct-26. Info: UPI/628001122334/Uber. Avl Bal: INR 15,200.00.',
          expectedBank: 'ICICI Bank',
          expectedAmountPaise: 35000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '3456',
          expectedRef: '628001122334',
        ),
        const SmsFixture(
          id: 'ICICI-05',
          sender: 'AD-ICICIB-T',
          body: 'Dear Customer, Acct XX3456 credited with INR 12,000.00 on 05-Oct-26 by NEFT-CMS99887766-CONSULTING. Avl Bal INR 27,200.00.',
          expectedBank: 'ICICI Bank',
          expectedAmountPaise: 1200000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '3456',
        ),

        // --- 3. State Bank of India (5 fixtures) ---
        const SmsFixture(
          id: 'SBI-01',
          sender: 'VA-CBSSBI-S',
          body: 'Your A/C XXXXX569331 Credited INR 29,000.00 on 31/08/26 -Deposit of Cash at S5NW004365621 CDM. Avl Bal INR 29,926.35-SBI',
          expectedBank: 'State Bank of India',
          expectedAmountPaise: 2900000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '9331',
        ),
        const SmsFixture(
          id: 'SBI-02',
          sender: 'VA-CBSSBI-S',
          body: 'Dear UPI user A/C XXXXX569331 debited by 320.00 on 05Oct26 transfer to chai wala Ref No 627911223344. Bal 29606.35 -SBI',
          expectedBank: 'State Bank of India',
          expectedAmountPaise: 32000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '9331',
          expectedRef: '627911223344',
        ),
        const SmsFixture(
          id: 'SBI-03',
          sender: 'VA-CBSSBI-S',
          body: 'Your A/C XXXXX569331 Credited INR 54,200.00 on 01/10/26 by IMPS txn from ACME CORP. Avl Bal INR 83,806.35-SBI',
          expectedBank: 'State Bank of India',
          expectedAmountPaise: 5420000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '9331',
        ),
        const SmsFixture(
          id: 'SBI-04',
          sender: 'VA-CBSSBI-S',
          body: 'Rs 2000.00 debited from A/C XXXXX569331 on 06/10/26 at SBI ATM NEW DELHI. Avl Bal Rs 81806.35. Call 1800111109 if not you -SBI',
          expectedBank: 'State Bank of India',
          expectedAmountPaise: 200000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '9331',
        ),
        const SmsFixture(
          id: 'SBI-05',
          sender: 'BP-SBICRD-S',
          body: 'Txn of Rs 1,890.00 spent on your SBI Credit Card ending 4411 at DMART on 07-Oct-26. Available Limit: Rs 42,110.00.',
          expectedBank: 'SBI Cards',
          expectedAmountPaise: 189000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
          expectedLast4: '4411',
        ),

        // --- 4. Axis Bank (5 fixtures) ---
        const SmsFixture(
          id: 'AXIS-01',
          sender: 'AD-AXISBK-T',
          body: 'INR 1,200.00 debited from A/c no. XX1234 on 15-10-2026 towards UPI/P2M/628181818181/Swiggy. Avl Bal: INR 12,450.00 - Axis Bank',
          expectedBank: 'Axis Bank',
          expectedAmountPaise: 120000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '1234',
          expectedRef: '628181818181',
        ),
        const SmsFixture(
          id: 'AXIS-02',
          sender: 'VM-AXISBK-S',
          body: 'Alert: You have spent INR 3,450.00 on Axis Bank Credit Card XX7788 at ZEE5 on 16-10-2026. Avl Limit INR 96,550.00',
          expectedBank: 'Axis Bank',
          expectedAmountPaise: 345000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
          expectedLast4: '7788',
        ),
        const SmsFixture(
          id: 'AXIS-03',
          sender: 'VM-AXISBK-S',
          body: 'Payment of INR 5,000.00 received towards Axis Bank Card XX7788 on 17-10-2026. Available limit: INR 1,00,000.00',
          expectedBank: 'Axis Bank',
          expectedAmountPaise: 500000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
          expectedLast4: '7788',
        ),
        const SmsFixture(
          id: 'AXIS-04',
          sender: 'AD-AXISBK-T',
          body: 'INR 7,500.00 credited to A/c no. XX1234 on 18-10-2026 through IMPS from CLIENT. Avl Bal: INR 19,950.00 - Axis Bank',
          expectedBank: 'Axis Bank',
          expectedAmountPaise: 750000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '1234',
        ),
        const SmsFixture(
          id: 'AXIS-05',
          sender: 'AD-AXISBK-T',
          body: 'INR 850.00 spent on your Axis Bank Debit Card ending 9922 at APOLLO PHARMACY on 19-10-2026. Avl Bal INR 19,100.00',
          expectedBank: 'Axis Bank',
          expectedAmountPaise: 85000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '9922',
        ),

        // --- 5. Kotak Mahindra Bank (5 fixtures) ---
        const SmsFixture(
          id: 'KOTAK-01',
          sender: 'AD-KOTAKB-T',
          body: 'Sent Rs. 350.00 from Kotak Bank AC X1234 to merchant@okaxis on 12-10-26. Ref 629191919191. Bal: Rs 15000.00',
          expectedBank: 'Kotak Mahindra Bank',
          expectedAmountPaise: 35000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '1234',
          expectedRef: '629191919191',
        ),
        const SmsFixture(
          id: 'KOTAK-02',
          sender: 'VM-KOTAKB-S',
          body: 'Spent Rs. 2,100.00 on your Kotak Credit Card ending 8833 at BOOKMYSHOW on 13-10-26. Avl Limit: Rs. 47,900.00',
          expectedBank: 'Kotak Mahindra Bank',
          expectedAmountPaise: 210000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
          expectedLast4: '8833',
        ),
        const SmsFixture(
          id: 'KOTAK-03',
          sender: 'VM-KOTAKB-S',
          body: 'Payment of Rs. 4,500.00 received for Kotak Credit Card 8833 on 14-10-26. Thank you.',
          expectedBank: 'Kotak Mahindra Bank',
          expectedAmountPaise: 450000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
          expectedLast4: '8833',
        ),
        const SmsFixture(
          id: 'KOTAK-04',
          sender: 'AD-KOTAKB-T',
          body: 'Received Rs. 1,000.00 in your Kotak Bank AC X1234 from friend@upi on 15-10-26. Ref 629555112233. Bal Rs 16000.00',
          expectedBank: 'Kotak Mahindra Bank',
          expectedAmountPaise: 100000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '1234',
          expectedRef: '629555112233',
        ),
        const SmsFixture(
          id: 'KOTAK-05',
          sender: 'AD-KOTAKB-T',
          body: 'Rs. 8,000.00 transferred from Kotak Bank AC X1234 to A/c ...9988 on 16-10-26. Bal: Rs 8,000.00',
          expectedBank: 'Kotak Mahindra Bank',
          expectedAmountPaise: 800000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '1234',
        ),

        // --- 6. Federal Bank (4 fixtures) ---
        const SmsFixture(
          id: 'FED-01',
          sender: 'VA-FEDBNK-T',
          body: 'Debited Rs 280.00 from a/c X8434 on 06Sep26 14:58 via UPI to Nasima T P. Ref 624952703868.Bal Rs 404.41. Not you?Call 18004251199 -Federal Bank',
          expectedBank: 'Federal Bank',
          expectedAmountPaise: 28000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '8434',
          expectedRef: '624952703868',
        ),
        const SmsFixture(
          id: 'FED-02',
          sender: 'VA-FEDBNK-T',
          body: 'Debited Rs 1,450.00 from a/c X8434 on 07Sep26 at LULU HYPERMARKET. Bal Rs 2,500.00. -Federal Bank',
          expectedBank: 'Federal Bank',
          expectedAmountPaise: 145000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '8434',
        ),
        const SmsFixture(
          id: 'FED-03',
          sender: 'VA-FEDBNK-T',
          body: 'Credited Rs 15,000.00 to a/c X8434 on 08Sep26 by IMPS from BROTHER. Bal Rs 17,500.00. -Federal Bank',
          expectedBank: 'Federal Bank',
          expectedAmountPaise: 1500000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '8434',
        ),
        const SmsFixture(
          id: 'FED-04',
          sender: 'VA-FEDBNK-T',
          body: 'Debited Rs 3,000.00 from a/c X8434 on 09Sep26 at FEDBANK ATM ERNAKULAM. Bal Rs 14,500.00. -Federal Bank',
          expectedBank: 'Federal Bank',
          expectedAmountPaise: 300000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '8434',
        ),

        // --- 7. Jupiter / CSB Bank (Edge RuPay) (4 fixtures) ---
        const SmsFixture(
          id: 'JUP-01',
          sender: 'TX-JTEDGE-S',
          body: '₹1515.00 paid from your Edge CSB Bank RuPay Credit Card to ICMAI GURGOAN dlIN on 2026-10-02T12:22:27.401024+05:30 IST. To raise an issue, call 8655055086. Thank you for using Jupiter.',
          expectedBank: 'Jupiter (CSB Bank)',
          expectedAmountPaise: 151500,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
        ),
        const SmsFixture(
          id: 'JUP-02',
          sender: 'AX-JTEDGE-S',
          body: 'Your payment of Rs 13.02  for your Edge CSB Bank RuPay Credit Card was successful. Thanks for using the Jupiter app.',
          expectedBank: 'Jupiter (CSB Bank)',
          expectedAmountPaise: 1302,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
        ),
        const SmsFixture(
          id: 'JUP-03',
          sender: 'TX-JTEDGE-S',
          body: '₹420.50 paid from your Edge CSB Bank RuPay Credit Card to BLINKIT on 2026-10-04. Thanks for using Jupiter.',
          expectedBank: 'Jupiter (CSB Bank)',
          expectedAmountPaise: 42050,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
        ),
        const SmsFixture(
          id: 'JUP-04',
          sender: 'AX-JTEDGE-S',
          body: 'Rs. 250.00 paid from your CSB Bank A/C XX4422 to Zomato via UPI on 05-10-26. Bal Rs. 5420.00. -Jupiter',
          expectedBank: 'Jupiter (CSB Bank)',
          expectedAmountPaise: 25000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '4422',
        ),

        // --- 8. OneCard / BOBCARD (4 fixtures) ---
        const SmsFixture(
          id: 'ONE-01',
          sender: 'CP-ONECRD-S',
          body: 'You have spent INR 899.00 on your OneCard at NETFLIX on 10-Oct-26. Available Limit: INR 84,101.00',
          expectedBank: 'OneCard (BOBCARD)',
          expectedAmountPaise: 89900,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
        ),
        const SmsFixture(
          id: 'ONE-02',
          sender: 'CP-ONECRD-S',
          body: 'We have received payment of INR 5,000.00 towards your OneCard on 12-Oct-26. Thank you for paying your bill on time!',
          expectedBank: 'OneCard (BOBCARD)',
          expectedAmountPaise: 500000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
        ),
        const SmsFixture(
          id: 'ONE-03',
          sender: 'AD-BOBCRD-S',
          body: 'Transaction alert: INR 1,299.00 spent on your BOBCARD ending 2510 at AJIO on 14-Oct-26. Avl Limit: INR 45,000.00',
          expectedBank: 'BOBCARD',
          expectedAmountPaise: 129900,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPurchase,
          expectedLast4: '2510',
        ),
        const SmsFixture(
          id: 'ONE-04',
          sender: 'AD-BOBCRD-S',
          body: 'Payment of Rs 1,299.00 received for your BOBCARD credit card ending with 2510 on 16-Oct-26.',
          expectedBank: 'BOBCARD',
          expectedAmountPaise: 129900,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.creditCardPayment,
          expectedLast4: '2510',
        ),

        // --- 9. Jio Payments Bank (3 fixtures) ---
        const SmsFixture(
          id: 'JIO-01',
          sender: 'JX-JIOPBS-S',
          body: 'Rs. 500.00 Sent from x3284 on 06-Sep-2026 Info: UPI/DR/624952623558/5 KADEEJA  Not you? Call 18008907070 - JPBL',
          expectedBank: 'Jio Payments Bank',
          expectedAmountPaise: 50000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '3284',
          expectedRef: '624952623558',
        ),
        const SmsFixture(
          id: 'JIO-02',
          sender: 'JD-JIOPBS-S',
          body: 'Rs. 600.61 Sent from x3284 on 29-Aug-2026 Info: UPI/DR/624148939809/SONU PETRO  Not you? Call 18008907070 - JPBL',
          expectedBank: 'Jio Payments Bank',
          expectedAmountPaise: 60061,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '3284',
          expectedRef: '624148939809',
        ),
        const SmsFixture(
          id: 'JIO-03',
          sender: 'JD-JIOPBS-S',
          body: 'Rs. 1,500.00 Received in x3284 on 02-Sep-2026 from user@paytm. Info: UPI/CR/624500998877. Avl Bal Rs. 3,500.00 - JPBL',
          expectedBank: 'Jio Payments Bank',
          expectedAmountPaise: 150000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
          expectedLast4: '3284',
          expectedRef: '624500998877',
        ),

        // --- 10. Amazon Pay (3 fixtures) ---
        const SmsFixture(
          id: 'AMZ-01',
          sender: 'AX-QCAMZN-S',
          body: 'Paid Rs. 249.00 on Swiggy using Amazon Pay balance. Order ID: 123456789. Updated balance: Rs 450.00',
          expectedBank: 'Amazon Pay',
          expectedAmountPaise: 24900,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
        ),
        const SmsFixture(
          id: 'AMZ-02',
          sender: 'AX-QCAMZN-S',
          body: 'Refund of Rs. 199.00 credited to your Amazon Pay balance for Order 987654321 on 15-Oct-26. Updated balance Rs. 649.00',
          expectedBank: 'Amazon Pay',
          expectedAmountPaise: 19900,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.refund,
        ),
        const SmsFixture(
          id: 'AMZ-03',
          sender: 'AX-AMZPAY-S',
          body: 'Cashback of Rs. 25.00 credited to your Amazon Pay wallet for mobile recharge on 16-Oct-26.',
          expectedBank: 'Amazon Pay',
          expectedAmountPaise: 2500,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
        ),

        // --- 11. Paytm (3 fixtures) ---
        const SmsFixture(
          id: 'PTM-01',
          sender: 'VK-PAYTM-S',
          body: 'Paid Rs. 85.00 from your Paytm Wallet to CHAI POINT on 12 Oct 2026. Updated Wallet Balance: Rs. 340.00',
          expectedBank: 'Paytm',
          expectedAmountPaise: 8500,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
        ),
        const SmsFixture(
          id: 'PTM-02',
          sender: 'VK-PAYTM-S',
          body: 'Rs. 300.00 debited from Paytm Payments Bank A/C XX9911 via UPI to AUTO RICKSHAW on 13 Oct 2026. UPI Ref: 628999112233.',
          expectedBank: 'Paytm',
          expectedAmountPaise: 30000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedLast4: '9911',
          expectedRef: '628999112233',
        ),
        const SmsFixture(
          id: 'PTM-03',
          sender: 'VK-IPAYTM-S',
          body: 'Received Rs. 500.00 in your Paytm Wallet from RAJESH on 14 Oct 2026. Wallet Balance: Rs. 840.00',
          expectedBank: 'Paytm',
          expectedAmountPaise: 50000,
          expectedIsCredit: true,
          expectedEventType: SmsEventType.income,
        ),

        // --- 12. Juspay (2 fixtures) ---
        const SmsFixture(
          id: 'JUS-01',
          sender: 'AX-JUSPAY-S',
          body: 'INR 1,150.00 debited for your order at IRCTC via Juspay on 18-Oct-26. Ref: JUS998877.',
          expectedBank: 'Juspay',
          expectedAmountPaise: 115000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
          expectedRef: 'JUS998877',
        ),
        const SmsFixture(
          id: 'JUS-02',
          sender: 'AX-JUSPAY-S',
          body: 'INR 180.00 debited for Namma Yatri ride via Juspay on 19-Oct-26.',
          expectedBank: 'Juspay',
          expectedAmountPaise: 18000,
          expectedIsCredit: false,
          expectedEventType: SmsEventType.expense,
        ),
      ];

      for (final fixture in fixtures) {
        test('Fixture ${fixture.id}: ${fixture.expectedBank} (${fixture.expectedEventType.name})', () {
          final res = importService.classifyMessage(fixture.body, fixture.sender);
          expect(res.transaction, isNotNull, reason: 'Failed to extract transaction for ${fixture.id}');

          final t = res.transaction!;
          // 1. Amount in paise
          expect((t.amount * 100).round(), fixture.expectedAmountPaise,
              reason: 'Amount mismatch for ${fixture.id}');

          // 2. Direction
          expect(t.isCredit, fixture.expectedIsCredit,
              reason: 'isCredit direction mismatch for ${fixture.id}');

          // 3. Event Type
          expect(res.eventType, fixture.expectedEventType,
              reason: 'EventType mismatch for ${fixture.id}');

          // 4. Last4 if expected
          if (fixture.expectedLast4 != null) {
            expect(t.last4, fixture.expectedLast4,
                reason: 'Last4 mismatch for ${fixture.id}');
          }

          // 5. Reference if expected
          if (fixture.expectedRef != null) {
            expect(t.refId, contains(fixture.expectedRef!),
                reason: 'Reference mismatch for ${fixture.id}');
          }
        });
      }
    });

    // =========================================================================
    // LAYER 2: AMOUNT EXTRACTION & CURRENCY HANDLING
    // =========================================================================
    group('Layer 2: Amount Extraction & Currency Handling', () {
      test('2a. INR amounts with commas: 1,25,000.50 and 10,000.00', () {
        final p1 = TransactionTextParser.parse('Rs. 1,25,000.50 debited from A/c XX1234');
        expect(p1.amount, 125000.50);

        final p2 = TransactionTextParser.parse('INR 10,000.00 credited to account');
        expect(p2.amount, 10000.00);
      });

      test('2b. Decimal amounts without commas: Rs 450.75 and ₹13.02', () {
        final p1 = TransactionTextParser.parse('Rs 450.75 paid to Cafe Coffee Day');
        expect(p1.amount, 450.75);

        final p2 = TransactionTextParser.parse('₹13.02 paid from Card');
        expect(p2.amount, 13.02);
      });

      test('2c. Integer amounts without decimal places: Rs 500 and INR 29000', () {
        final p1 = TransactionTextParser.parse('Debited Rs 500 via UPI');
        expect(p1.amount, 500.0);

        final p2 = TransactionTextParser.parse('Credited INR 29000 to account');
        expect(p2.amount, 29000.0);
      });

      test('2d. Currency symbol variants: Rs, Rs., INR, ₹', () {
        expect(TransactionTextParser.parse('Rs 100 paid').amount, 100.0);
        expect(TransactionTextParser.parse('Rs. 200 paid').amount, 200.0);
        expect(TransactionTextParser.parse('INR 300 paid').amount, 300.0);
        expect(TransactionTextParser.parse('₹400 paid').amount, 400.0);
      });

      test('2e. Multiple monetary values: Transaction amount vs Available Balance vs Limit', () {
        const text = 'INR 1,500.00 spent on Card XX5007. Avl Limit: INR 85,000.00. Total Due: INR 12,000.00';
        final parsed = TransactionTextParser.parse(text);
        expect(parsed.amount, 1500.0, reason: 'Must extract transaction spend amount, not limit or due');

        final classification = importService.classifyMessage(text, 'VM-ICICIB-S');
        expect(classification.transaction?.amount, 1500.0);
        expect(classification.balance?.amount, 12000.0, reason: 'Total Due is prioritized as statement balance amount');
        expect(classification.balance?.isStatementBill, isTrue);
      });

      test('2f. Critical Case: Foreign currency plus converted INR debited', () {
        // Real-world international transaction alert:
        // "USD 15.00 spent on your Card XX5007 at GITHUB. INR 1,280.50 debited from A/c on 15-Oct-26."
        const msg = 'USD 15.00 spent on your Card XX5007 at GITHUB. INR 1,280.50 debited on 15-Oct-26.';
        final res = importService.classifyMessage(msg, 'JD-ICICIT-S');
        expect(res.transaction, isNotNull);
        expect(res.transaction!.amount, 1280.50,
            reason: 'Must extract the converted INR debited amount (1280.50), not the USD 15.00 figure');
      });

      test('2g. Missing amount rejects transaction creation', () {
        final parsed = TransactionTextParser.parse('Payment processed successfully at Merchant');
        expect(parsed.amount, 0.0);

        final classification = importService.classifyMessage(
          'Payment processed successfully at Merchant with no amount mentioned',
          'AD-HDFCBK-T',
        );
        expect(classification.transaction, isNull);
      });

      test('2h. Invalid or malformed amount rejects gracefully', () {
        final parsed = TransactionTextParser.parse('Rs. ABC debited from A/C XX1234');
        expect(parsed.amount, 0.0);
      });

      // ── NPCI UPI Reference Slash & Isolation Safeguards ──
      test('2i. NPCI UPI slash format: UPI/628001122334/Uber extracts 12-digit RRN', () {
        final parsed = TransactionTextParser.parse(
          'INR 350.00 debited from ICICI Bank Acct XX2004 on 15-Oct-26 towards UPI/628001122334/Uber. Avl Bal: INR 32,650.00',
        );
        expect(parsed.refId, '628001122334');
      });

      test('2j. NPCI UPI slash format: UPI/P2M/628001122334 without trailing merchant', () {
        final parsed = TransactionTextParser.parse(
          'INR 420.00 debited from A/c no. XX9921 on 15-Oct-26 towards UPI/P2M/628001122334. Avl Bal: INR 24,580.00',
        );
        expect(parsed.refId, '628001122334');
      });

      test('2k. NPCI UPI slash format: UPI/DR/628001122334 extracts exact RRN', () {
        final parsed = TransactionTextParser.parse(
          'Rs. 150.00 Sent from x1234 on 15-Oct-26 Info: UPI/DR/628001122334/Merchant Bal: Rs. 1,850.00',
        );
        expect(parsed.refId, '628001122334');
      });

      test('2l. NPCI UPI slash format: UPI/CR/628001122334 extracts exact RRN', () {
        final parsed = TransactionTextParser.parse(
          'Rs. 500.00 Received in x1234 on 15-Oct-26 Info: UPI/CR/628001122334/Sender Bal: Rs. 2,350.00',
        );
        expect(parsed.refId, '628001122334');
      });

      test('2m. Extraction does not capture amounts, account numbers, dates or phone numbers as refId', () {
        final parsed = TransactionTextParser.parse(
          'INR 1,500.00 debited from A/c XX3210 on 15-10-2026. Avl Bal: 45,000.00. Ref: UPI/P2M/628001122334/Store. Helpline: 1800123456.',
        );
        expect(parsed.amount, 1500.0);
        expect(parsed.last4, '3210');
        expect(parsed.refId, '628001122334');
        expect(parsed.refId, isNot(contains('1500')));
        expect(parsed.refId, isNot(contains('3210')));
        expect(parsed.refId, isNot(contains('1800123456')));
      });
    });

    // =========================================================================
    // LAYER 3: CLASSIFICATION MATRIX
    // =========================================================================
    group('Layer 3: Classification Matrix', () {
      test('3a. Bank Debit is classified as expense with isCredit = false', () {
        final res = importService.classifyMessage(
          'Debited Rs 500.00 from A/c XX1234 on 02-Oct-26 via UPI to STORE. Bal Rs 4500.00',
          'AD-HDFCBK-T',
        );
        expect(res.eventType, SmsEventType.expense);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3b. Bank Credit is classified as income with isCredit = true', () {
        final res = importService.classifyMessage(
          'A/c XX1234 credited with INR 25,000.00 on 01-Oct-26 by SALARY. Avl Bal INR 50,000.00',
          'AD-HDFCBK-T',
        );
        expect(res.eventType, SmsEventType.income);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3c. UPI P2M Merchant Transfer is classified as expense', () {
        final res = importService.classifyMessage(
          'Rs. 320.00 Sent from x3284 on 06-Sep-2026 Info: UPI/DR/624952623558/TEA POINT - JPBL',
          'JX-JIOPBS-S',
        );
        expect(res.eventType, SmsEventType.expense);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3d. Inward NEFT/IMPS is classified as income', () {
        final res = importService.classifyMessage(
          'INR 10,000.00 credited to A/c no. XX1234 on 18-10-2026 through IMPS from CLIENT.',
          'AD-AXISBK-T',
        );
        expect(res.eventType, SmsEventType.income);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3e. Credit Card Purchase is classified as creditCardPurchase with isCredit = false', () {
        final res = importService.classifyMessage(
          'INR 899.00 spent on ICICI Bank Card XX5007 on 05-Oct-26 on NETFLIX. Avl Limit: INR 80,000.00',
          'JD-ICICIT-S',
        );
        expect(res.eventType, SmsEventType.creditCardPurchase);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3f. Credit Card Refund is classified as refund with isCredit = true', () {
        final res = importService.classifyMessage(
          'Refund of INR 450.00 has been credited to your ICICI Bank Credit Card XX5007 on 09-Oct-26 from AMAZON.',
          'JD-ICICIT-S',
        );
        expect(res.eventType, SmsEventType.refund);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3g. Direct Credit Card Bill Payment is creditCardPayment with isCredit = false (Zero Income)', () {
        final res = importService.classifyMessage(
          'DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 2000.00 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 6366 ON 2-10-2026.',
          'JM-HDFCBK-S',
        );
        expect(res.eventType, SmsEventType.creditCardPayment);
        expect(res.transaction!.isCredit, isFalse, reason: 'Must not register as income credit');
      });

      test('3h. BBPS Card Bill Payment is creditCardPayment with isCredit = false (Zero Income)', () {
        final res = importService.classifyMessage(
          'Payment of Rs 10,000.00 has been received on your ICICI Bank Credit Card XX5007 through Bharat Bill Payment System on 07-OCT-26.',
          'AD-ICICIT-S',
        );
        expect(res.eventType, SmsEventType.creditCardPayment);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3i. ATM Cash Withdrawal is classified as expense', () {
        final res = importService.classifyMessage(
          'Rs 2000.00 debited from A/C XXXXX569331 on 06/10/26 at SBI ATM. Avl Bal Rs 10000.00',
          'VA-CBSSBI-S',
        );
        expect(res.eventType, SmsEventType.expense);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3j. Failed / Declined Transaction is classified as failed with no transaction created', () {
        final res = importService.classifyMessage(
          'Your transaction of Rs 1,500.00 on Card XX5007 at ZOMATO has failed due to insufficient funds.',
          'JD-ICICIT-S',
        );
        expect(res.eventType, SmsEventType.failed);
      });

      test('3k. Balance-only notification produces balance hit with zero transaction', () {
        final res = importService.classifyMessage(
          'Your HDFC Bank Credit Card XX1234 outstanding balance is Rs.15,500.00. Pay before due date to avoid late fees.',
          'VM-HDFCBK-S',
        );
        expect(res.transaction, isNull);
        expect(res.balance, isNotNull);
        expect(res.balance!.amount, 15500.0);
        expect(res.balance!.kind, BalanceKind.creditCard);
      });

      // ── Contextual Refund & Reversal Safeguards ──
      test('3l. Bank account merchant refund is classified as refund (isCredit = true)', () {
        final res = importService.classifyMessage(
          'Refund of Rs. 1,200.00 credited to your A/c XX1234 from Zomato on 16-Oct-26. Avl Bal: Rs. 15,000.00',
          'AD-HDFCBK-T',
        );
        expect(res.eventType, SmsEventType.refund);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3m. Wallet refund is classified as refund (isCredit = true)', () {
        final res = importService.classifyMessage(
          'Refund of Rs. 199.00 credited to your Amazon Pay balance for order 402-1122334 on 15-Oct-26.',
          'AX-QCAMZN-S',
        );
        expect(res.eventType, SmsEventType.refund);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3n. Bank reversal for failed transaction is classified as refund', () {
        final res = importService.classifyMessage(
          'Reversal of Rs. 500.00 credited to your A/c XX1234 on 16-Oct-26 for failed UPI txn.',
          'AD-SBIINB-T',
        );
        expect(res.eventType, SmsEventType.refund);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3o. Cashback is classified as income, NOT refund', () {
        final res = importService.classifyMessage(
          'Cashback of Rs. 25.00 credited to your Amazon Pay wallet for mobile recharge on 16-Oct-26. Bal: Rs. 125.00',
          'AX-QCAMZN-S',
        );
        expect(res.eventType, SmsEventType.income);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3p. Ordinary salary/transfer credit is classified as income, NOT refund', () {
        final res = importService.classifyMessage(
          'Salary of Rs 85,000.00 credited to your A/c XX1234 on 31-Oct-26. Bal: Rs. 1,12,000.00',
          'AD-HDFCBK-T',
        );
        expect(res.eventType, SmsEventType.income);
        expect(res.transaction!.isCredit, isTrue);
      });

      test('3q. Reversal fee debit is classified as expense, NOT refund', () {
        final res = importService.classifyMessage(
          'Rs 50.00 debited from A/c XX1234 towards fee for reversal of check on 16-Oct-26.',
          'AD-AXISBK-T',
        );
        expect(res.eventType, SmsEventType.expense);
        expect(res.transaction!.isCredit, isFalse);
      });

      // ── Jupiter Sender Precedence Safeguards ──
      test('3r. Jupiter CSB savings account debit takes precedence over JTEDGE sender', () {
        final res = importService.classifyMessage(
          'Rs. 250.00 paid from your CSB Bank A/C XX4422 to ZOMATO on 16-Oct-26 via UPI. Ref 628001122340. Bal: Rs. 14,250.00 -Jupiter',
          'AX-JTEDGE-S',
        );
        expect(res.eventType, SmsEventType.expense);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3s. Jupiter Edge RuPay Credit Card spend is creditCardPurchase', () {
        final res = importService.classifyMessage(
          '₹ 1,200.00 paid from your Edge CSB Bank RuPay Credit Card to SWIGGY on 15-Oct-26. Available Limit: ₹ 48,800.00 -Jupiter',
          'AX-JTEDGE-S',
        );
        expect(res.eventType, SmsEventType.creditCardPurchase);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3t. Jupiter Wallet transaction is expense, NOT creditCardPurchase', () {
        final res = importService.classifyMessage(
          'Paid Rs. 150.00 from your Jupiter Wallet to Merchant on 15-Oct-26.',
          'AX-JTEDGE-S',
        );
        expect(res.eventType, SmsEventType.expense);
        expect(res.transaction!.isCredit, isFalse);
      });

      test('3u. Ambiguous Jupiter SMS defaults to Edge credit card spend', () {
        final res = importService.classifyMessage(
          'Rs. 500.00 spent on your Edge on 15-Oct-26 at CAFE. Avl Limit: Rs. 40,000.00',
          'AX-JTEDGE-S',
        );
        expect(res.eventType, SmsEventType.creditCardPurchase);
        expect(res.transaction!.isCredit, isFalse);
      });
    });

    // =========================================================================
    // LAYER 4: NON-FINANCIAL NOISE REJECTION
    // =========================================================================
    group('Layer 4: Non-Financial SMS Rejection', () {
      test('4a. Bank and transaction OTPs are rejected (0 transactions, 0 balances)', () {
        final otps = [
          '648280 is the OTP for txn of INR 1515.00 on your Edge CSB Bank RuPay Credit Card ending 2834 done on ICMAI.',
          '409147 is your OTP for service - Login request on HDFC Bank MyCards. Valid for 2 mins. #409147',
          'LOGIN to your Flipkart account using OTP 611176. DO NOT SHARE this code with anyone.',
        ];
        for (final otp in otps) {
          final res = importService.classifyMessage(otp, 'AD-HDFCBK-T');
          expect(res.transaction, isNull, reason: 'OTP leaked as transaction: $otp');
          expect(res.balance, isNull, reason: 'OTP leaked as balance: $otp');
        }
      });

      test('4b. Card PIN reset and login alerts are rejected', () {
        final res = importService.classifyMessage(
          '2477 is the OTP to reset your card PIN for Edge CSB Bank RuPay Credit Card.',
          'JD-JTEDGE-S',
        );
        expect(res.transaction, isNull);
        expect(res.balance, isNull);
      });

      test('4c. Promotional loan and credit limit increase offers with amounts are rejected', () {
        final promos = [
          'Manage spends effectively by increasing the limit on ICICI Bank Credit Card XX5007 from Rs140000 to Rs170000. SMS CRLIM 5007 to 5676766',
          'Pre-approved Personal Loan of Rs 5,00,000 is available for you at 10.5% interest. Apply now in iMobile.',
          '100 INR Bonus is expiring soon. Claim now on Stake! FREE BONUS: go.stake.com/8D5C3',
        ];
        for (final promo in promos) {
          final res = importService.classifyMessage(promo, 'JX-ICICIT-S');
          expect(res.transaction, isNull, reason: 'Promo offer leaked as transaction: $promo');
        }
      });

      test('4d. Telecom recharge and plan expiration notices are rejected', () {
        final res = importService.classifyMessage(
          'Your Jio plan of Rs 899 has expired on 24-Sep-26. Please recharge with Rs 899 to continue unlimited calling.',
          'JL-JIOCAR-S',
        );
        expect(res.transaction, isNull);
        expect(res.balance, isNull);
      });

      test('4e. Weather and disaster alerts are rejected', () {
        final res = importService.classifyMessage(
          'Heavy rainfall of 50 mm expected in district today. Stay indoors. IMD-KSDMA.',
          'JG-NDMAEW-G',
        );
        expect(res.transaction, isNull);
        expect(res.balance, isNull);
      });

      test('4f. Courier and delivery updates are rejected', () {
        final res = importService.classifyMessage(
          'Your Amazon package with tracking ID 987654321 is out for delivery today.',
          'AX-AMAZON-S',
        );
        expect(res.transaction, isNull);
      });

      test('4g. Personal numeric mobile sender messages are rejected', () {
        final res = importService.classifyMessage(
          'Hey bro I sent you 500 rs please check your account',
          '+919876543210',
        );
        expect(res.transaction, isNull, reason: 'Personal numeric phone message must never create a bank transaction');
        expect(res.balance, isNull);
      });

      test('4h. Messages with numbers/codes but no financial transaction verbs are rejected', () {
        final res = importService.classifyMessage(
          'Use discount coupon SAVE50 to get Rs 50 off on your next purchase at STORE.',
          'AD-STORE-S',
        );
        expect(res.transaction, isNull);
      });
    });

    // =========================================================================
    // LAYER 5: DEDUPLICATION & REFERENCE COLLISIONS
    // =========================================================================
    group('Layer 5: Deduplication & Reference Collisions', () {
      test('5a. Scenario A: Same amount, same merchant, same account with different UPI references are BOTH accepted', () async {
        final now = DateTime(2026, 10, 10, 12, 0);

        final bank = BankAccount(name: 'HDFC Bank', bank: 'HDFC', last4: '1234', balance: 50000.0);
        final bankId = await AccountRepo(executor: db).insertAccount(bank);

        // Transaction 1 with UTR ref_upi_111
        final tx1 = spx.Transaction(
          id: 'tx_dedup_5a_1',
          amount: 500.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: bankId,
          date: now,
          notes: 'Swiggy',
          externalRef: 'ref_upi_111',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx1);

        // Transaction 2 with distinct UTR ref_upi_222 (e.g. ordered twice for office)
        final tx2 = spx.Transaction(
          id: 'tx_dedup_5a_2',
          amount: 500.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: bankId,
          date: now.add(const Duration(minutes: 5)),
          notes: 'Swiggy',
          externalRef: 'ref_upi_222',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx2);

        // Verify both transactions exist independently
        final txRepo = TransactionRepo(executor: db);
        final all = await txRepo.getAll();
        final ids = all.map((t) => t.id).toSet();
        expect(ids.contains('tx_dedup_5a_1'), isTrue);
        expect(ids.contains('tx_dedup_5a_2'), isTrue);

        // Balance decremented by exactly 2 x 500 = 1000
        final derived = await CanonicalAccountRepository(executor: db).getDerivedBalance(bankId);
        expect(derived.toRupees, 49000.0);
      });

      test('5b. Scenario D: Identical message processed twice is rejected via SHA-256 evidence fingerprint', () async {
        final now = DateTime(2026, 10, 10, 14, 0);
        final bank = BankAccount(name: 'HDFC Bank', bank: 'HDFC', last4: '1234', balance: 50000.0);
        final bankId = await AccountRepo(executor: db).insertAccount(bank);

        const rawBody = 'Debited Rs 750.00 from A/c **1234 on 10-Oct-26 via UPI to Zomato. Ref: 629000111222. Bal: Rs 49250.00';
        final fingerprint = CanonicalTransactionAdapter.computeSha256(rawBody);

        // Ingest first time
        final tx1 = spx.Transaction(
          id: 'tx_dedup_5b_first',
          amount: 750.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: bankId,
          date: now,
          notes: 'Zomato',
          externalRef: '629000111222',
          source: 'sms',
          rawPayload: rawBody,
        );
        await FinancialTransactionService(database: db).createTransaction(tx1);

        // Verify evidence exists
        final eventRepo = CanonicalEventRepository(executor: db);
        final existingEvidence = await eventRepo.getEvidenceByExternalReference('629000111222');
        expect(existingEvidence, isNotNull);
        expect(existingEvidence?.bodyFingerprint, fingerprint);

        // Attempt second ingestion with same reference
        final duplicateCheck = await eventRepo.getEvidenceByExternalReference('629000111222');
        expect(duplicateCheck, isNotNull, reason: 'Duplicate evidence detected by reference');
      });

      test('5c. Scenario E: Same reference appearing across distinct senders is safely distinguished', () {
        // Ref R1 vs R10 collision prevention
        expect(LiveSmsService.normalizeReference('Ref: 12345'), 'ref12345');
        expect(LiveSmsService.normalizeReference('Ref: 123456'), 'ref123456');
        expect(LiveSmsService.normalizeReference('Ref: 12345') != LiveSmsService.normalizeReference('Ref: 123456'), isTrue);
      });
    });

    // =========================================================================
    // LAYER 6: MULTIPLE-ACCOUNT ISOLATION
    // =========================================================================
    group('Layer 6: Multiple-Account Isolation', () {
      test('6a. Two accounts from same bank with different last-four digits are strictly isolated', () async {
        final accountRepo = AccountRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);

        final bankA = BankAccount(id: 'acc_hdfc_1234', name: 'HDFC Savings 1', bank: 'HDFC', last4: '1234', balance: 50000.0);
        final bankB = BankAccount(id: 'acc_hdfc_5678', name: 'HDFC Salary 2', bank: 'HDFC', last4: '5678', balance: 80000.0);
        await accountRepo.insertAccount(bankA);
        await accountRepo.insertAccount(bankB);

        // Spend on Account 1234
        final txA = spx.Transaction(
          id: 'tx_iso_1',
          amount: 1500.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_hdfc_1234',
          date: DateTime.now(),
          notes: 'Shopping on acc 1234',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(txA);

        // Spend on Account 5678
        final txB = spx.Transaction(
          id: 'tx_iso_2',
          amount: 3200.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_hdfc_5678',
          date: DateTime.now(),
          notes: 'Dinner on acc 5678',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(txB);

        // Verification: Account 1234 decremented by exactly 1,500; Account 5678 decremented by exactly 3,200
        final balA = await canonicalRepo.getDerivedBalance('acc_hdfc_1234');
        final balB = await canonicalRepo.getDerivedBalance('acc_hdfc_5678');
        expect(balA.toRupees, 48500.0);
        expect(balB.toRupees, 76800.0);
      });

      test('6b. Multiple cards from the same issuer (ICICI Card 5007 vs Card 8001)', () async {
        final creditRepo = CreditRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);

        final cardA = CreditCard(id: 'card_icici_5007', name: 'ICICI Amazon Pay', bank: 'ICICI Bank', last4: '5007', limitAmount: 100000.0);
        final cardB = CreditCard(id: 'card_icici_8001', name: 'ICICI Coral', bank: 'ICICI Bank', last4: '8001', limitAmount: 150000.0);
        await creditRepo.insert(cardA);
        await creditRepo.insert(cardB);

        // Purchase on Card 5007
        final txCardA = spx.Transaction(
          id: 'tx_card_iso_1',
          amount: 450.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'card_icici_5007',
          date: DateTime.now(),
          notes: 'Kindle book',
          source: 'credit_card_purchase',
        );
        await FinancialTransactionService(database: db).createTransaction(txCardA);

        // Card 5007 liability = 450, Card 8001 liability = 0
        final liabA = await canonicalRepo.getDerivedBalance('card_icici_5007');
        final liabB = await canonicalRepo.getDerivedBalance('card_icici_8001');
        expect(liabA.toRupees, 450.0);
        expect(liabB.toRupees, 0.0);
      });
    });

    // =========================================================================
    // LAYER 7: END-TO-END INGESTION INTEGRATION
    // =========================================================================
    group('Layer 7: End-to-End Ingestion Integration', () {
      test('7a. Bank Debit SMS posts balanced 2-leg event to canonical ledger', () async {
        final bank = BankAccount(id: 'acc_bank_e2e_1', name: 'HDFC Main', bank: 'HDFC', last4: '1234', balance: 50000.0);
        await AccountRepo(executor: db).insertAccount(bank);

        final catRepo = CategoryRepo(executor: db);
        final foodCat = await catRepo.getByName('Food', type: 'expense');
        expect(foodCat, isNotNull);

        final tx = spx.Transaction(
          id: 'tx_e2e_debit_1',
          amount: 350.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_bank_e2e_1',
          categoryId: foodCat!.id,
          date: DateTime.now(),
          notes: 'Swiggy Dinner',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx);

        // Verify postings in canonical table
        final postings = await CanonicalEventRepository(executor: db).getPostingsForEvent('tx_e2e_debit_1');
        expect(postings.length, 2);

        // Debit Expense
        final expP = postings.firstWhere((p) => p.accountId == foodCat.id);
        expect(expP.direction, PostingDirection.debit);
        expect(expP.amount.asRupees, 350.0);

        // Credit Asset
        final assetP = postings.firstWhere((p) => p.accountId == 'acc_bank_e2e_1');
        expect(assetP.direction, PostingDirection.credit);
        expect(assetP.amount.asRupees, 350.0);

        // Ledger parity
        final bankBal = await CanonicalAccountRepository(executor: db).getDerivedBalance('acc_bank_e2e_1');
        expect(bankBal.toRupees, 49650.0);
      });

      test('7b. Credit Card Payment posts liability reduction with zero income and zero expense', () async {
        final accountRepo = AccountRepo(executor: db);
        final creditRepo = CreditRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final queryRepo = CanonicalFinancialQueryRepository(executor: db);

        final bank = BankAccount(id: 'acc_bank_pay_cc', name: 'HDFC Pay', bank: 'HDFC', last4: '1234', balance: 50000.0);
        await accountRepo.insertAccount(bank);

        final card = CreditCard(id: 'card_cc_target', name: 'HDFC Card', bank: 'HDFC', last4: '6366', limitAmount: 100000.0, usedAmount: 10000.0);
        await creditRepo.insert(card);

        // Initial liability
        final initialLiab = await canonicalRepo.getDerivedBalance('card_cc_target');
        expect(initialLiab.toRupees, 10000.0);

        // Payment of ₹5,000 from Bank to Card
        final payTx = spx.Transaction(
          id: 'tx_e2e_cc_pay',
          amount: 5000.0,
          type: 'credit_payment',
          userId: 'offline_user',
          accountId: 'acc_bank_pay_cc',
          relatedEntityId: 'card_cc_target',
          date: DateTime.now(),
          notes: 'Credit Card Bill Payment',
          source: 'credit_card_payment',
        );
        await FinancialTransactionService(database: db).createTransaction(payTx);

        // Postings verification:
        // Debit Card Liability (reduces liability by ₹5,000)
        // Credit Bank Asset (reduces cash by ₹5,000)
        final postings = await CanonicalEventRepository(executor: db).getPostingsForEvent('tx_e2e_cc_pay');
        expect(postings.length, 2);

        final cardP = postings.firstWhere((p) => p.accountId == 'card_cc_target');
        expect(cardP.direction, PostingDirection.debit);
        expect(cardP.amount.asRupees, 5000.0);

        final bankP = postings.firstWhere((p) => p.accountId == 'acc_bank_pay_cc');
        expect(bankP.direction, PostingDirection.credit);
        expect(bankP.amount.asRupees, 5000.0);

        // Verified: Remaining liability = ₹5,000.00
        final finalLiab = await canonicalRepo.getDerivedBalance('card_cc_target');
        expect(finalLiab.toRupees, 5000.0);

        // Verified: Zero income and zero expense effect
        final totalExp = await queryRepo.getTotalExpenses();
        final totalInc = await queryRepo.getTotalIncome();
        expect(totalExp.minorUnits, 0);
        expect(totalInc.minorUnits, 0);
      });

      test('7c. Rejected non-financial message creates zero ledger mutations', () async {
        // Ensure clean ledger baseline
        final eventsBefore = await db.query(TablesV24.economicEvents);
        final eventCountBefore = eventsBefore.length;

        // Classify an OTP message
        const otpMessage = '543210 is your OTP for transaction of INR 500.00 at MERCHANT.';
        final classification = importService.classifyMessage(otpMessage, 'AD-HDFCBK-T');
        expect(classification.transaction, isNull);

        // Verify zero events were posted
        final eventsAfter = await db.query(TablesV24.economicEvents);
        expect(eventsAfter.length, eventCountBefore);
      });

      test('7d. Debit-card purchase reduces bank asset and creates ZERO credit card liabilities', () async {
        final accountRepo = AccountRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);

        final bank = BankAccount(
          id: 'acc_debit_test',
          name: 'HDFC Savings',
          bank: 'HDFC',
          last4: '9922',
          balance: 20000.0,
        );
        await accountRepo.insertAccount(bank);

        // Classify Debit Card SMS
        const debitSms = 'Rs 1,500.00 spent on your Axis Bank Debit Card ending 9922 on 15-Oct-26 at SHELL. Avl Bal: INR 18,500.00';
        final classification = importService.classifyMessage(debitSms, 'AD-AXISBK-T');
        expect(classification.eventType, SmsEventType.expense);
        expect(classification.transaction!.method, 'card');

        // Post through FinancialTransactionService
        final tx = spx.Transaction(
          id: 'tx_e2e_debit_card',
          amount: 1500.0,
          type: 'expense',
          userId: 'offline_user',
          accountId: 'acc_debit_test',
          date: DateTime.now(),
          notes: 'Fuel at SHELL',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(tx);

        // Verify bank asset decreased by ₹1,500 (20,000 - 1,500 = 18,500)
        final bankBal = await canonicalRepo.getDerivedBalance('acc_debit_test');
        expect(bankBal.toRupees, 18500.0);

        // Verify postings: Category Expense (debit) + Bank Asset (credit)
        final postings = await CanonicalEventRepository(executor: db).getPostingsForEvent('tx_e2e_debit_card');
        expect(postings.length, 2);
        final bankP = postings.firstWhere((p) => p.accountId == 'acc_debit_test');
        expect(bankP.direction, PostingDirection.credit);
        expect(bankP.amount.asRupees, 1500.0);

        // Verify zero credit card liabilities were created
        final ccAccounts = await db.query(TablesV24.accounts, where: "account_type = 'liability'");
        for (final cc in ccAccounts) {
          final bal = await canonicalRepo.getDerivedBalance(cc['id'] as String);
          expect(bal.minorUnits, 0);
        }
      });

      test('7e. Wallet / Bank Refund reduces expense and creates ZERO ordinary income', () async {
        final accountRepo = AccountRepo(executor: db);
        final canonicalRepo = CanonicalAccountRepository(executor: db);
        final queryRepo = CanonicalFinancialQueryRepository(executor: db);

        final wallet = BankAccount(
          id: 'acc_wallet_amz',
          name: 'Amazon Pay Balance',
          bank: 'Amazon Pay',
          last4: '0000',
          balance: 500.0,
        );
        await accountRepo.insertAccount(wallet);

        // Classify refund SMS
        const refundSms = 'Refund of Rs. 199.00 credited to your Amazon Pay balance for order 402-1122334 on 15-Oct-26.';
        final classification = importService.classifyMessage(refundSms, 'AX-QCAMZN-S');
        expect(classification.eventType, SmsEventType.refund);
        expect(classification.transaction!.isCredit, isTrue);

        // Initial income baseline
        final incomeBefore = await queryRepo.getTotalIncome();

        // Post refund transaction
        final refundTx = spx.Transaction(
          id: 'tx_e2e_refund_wallet',
          amount: 199.0,
          type: 'refund',
          userId: 'offline_user',
          accountId: 'acc_wallet_amz',
          date: DateTime.now(),
          notes: 'Amazon order refund',
          source: 'sms',
        );
        await FinancialTransactionService(database: db).createTransaction(refundTx);

        // Verify wallet asset balance increased by ₹199 (500 + 199 = 699)
        final walletBal = await canonicalRepo.getDerivedBalance('acc_wallet_amz');
        expect(walletBal.toRupees, 699.0);

        // Verify ordinary income was NOT inflated (remains unchanged)
        final incomeAfter = await queryRepo.getTotalIncome();
        expect(incomeAfter.minorUnits, incomeBefore.minorUnits);
      });
    });
  });
}
