import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/core/utils/vpa_resolver.dart';
import 'package:spend_x/services/transaction_text_parser.dart';

void main() {
  group('VpaResolver - Conservative & Confident Extraction', () {
    test('resolves direct merchant VPA handles accurately', () {
      final swiggy = VpaResolver.resolve('Paid Rs 349 to swiggy@icici for order')!;
      expect(swiggy.rawVpa, 'swiggy@icici');
      expect(swiggy.merchantName, 'Swiggy');
      expect(swiggy.isAggregator, isFalse);
      expect(swiggy.isAmbiguous, isFalse);

      final blinkit = VpaResolver.resolve('Debited INR 512 to blinkit@kotak')!;
      expect(blinkit.rawVpa, 'blinkit@kotak');
      expect(blinkit.merchantName, 'Blinkit');
      expect(blinkit.isAmbiguous, isFalse);

      final amazon = VpaResolver.resolve('Payment to amazonpay@apl successful')!;
      expect(amazon.rawVpa, 'amazonpay@apl');
      expect(amazon.merchantName, 'Amazon Pay');
      expect(amazon.isAmbiguous, isFalse);
    });

    test('resolves compound merchant.aggregator VPAs with processor separation', () {
      final uber = VpaResolver.resolve('Paid Rs 280 to uber.payu@hdfcbank via UPI')!;
      expect(uber.rawVpa, 'uber.payu@hdfcbank');
      expect(uber.merchantName, 'Uber');
      expect(uber.aggregator, 'PayU');
      expect(uber.isAggregator, isTrue);
      expect(uber.isAmbiguous, isFalse);

      final netflix = VpaResolver.resolve('Auto-debit of Rs 649 to netflix.billdesk@hdfcbank')!;
      expect(netflix.rawVpa, 'netflix.billdesk@hdfcbank');
      expect(netflix.merchantName, 'Netflix');
      expect(netflix.aggregator, 'BillDesk');
      expect(netflix.isAggregator, isTrue);

      final irctc = VpaResolver.resolve('Paid Rs 1250 to irctc.atom@icici for ticket')!;
      expect(irctc.rawVpa, 'irctc.atom@icici');
      expect(irctc.merchantName, 'IRCTC');
      expect(irctc.aggregator, 'Atom');
      expect(irctc.isAggregator, isTrue);
    });

    test('strips operational sub-prefixes/suffixes safely (e.g. order, pay, qr)', () {
      final zomato = VpaResolver.resolve('Paid Rs 420 to zomato.order@icici')!;
      expect(zomato.merchantName, 'Zomato');
      expect(zomato.isAmbiguous, isFalse);
    });

    test('rejects phone numbers and numeric VPAs from being treated as merchants', () {
      final phoneVpa = VpaResolver.resolve('Paid Rs 500 to 9876543210@upi on 12-Nov')!;
      expect(phoneVpa.rawVpa, '9876543210@upi');
      expect(phoneVpa.merchantName, isNull);
      expect(phoneVpa.isAmbiguous, isTrue);
    });

    test('rejects standalone payment aggregators from being treated as consumer merchants', () {
      final payu = VpaResolver.resolve('Paid INR 1500 to payu@icici')!;
      expect(payu.rawVpa, 'payu@icici');
      expect(payu.merchantName, isNull);
      expect(payu.isAggregator, isTrue);
      expect(payu.isAmbiguous, isTrue);

      final razorpay = VpaResolver.resolve('Debited INR 999 to razorpay@yesbank')!;
      expect(razorpay.rawVpa, 'razorpay@yesbank');
      expect(razorpay.merchantName, isNull);
      expect(razorpay.isAggregator, isTrue);
      expect(razorpay.isAmbiguous, isTrue);
    });

    test('retains uncertainty for arbitrary personal-looking VPAs without guessing P2P or merchant', () {
      final personal = VpaResolver.resolve('Sent Rs 1200 to rahul98@okaxis via Google Pay')!;
      expect(personal.rawVpa, 'rahul98@okaxis');
      expect(personal.merchantName, isNull);
      expect(personal.isAmbiguous, isTrue);
    });
  });

  group('TransactionTextParser - Full Message Extraction & Independent Decisions', () {
    test('extracts VPA, merchant, and sets expense intent without guessing bank account', () {
      const sms = 'Paid Rs 349 to swiggy@icici through UPI ref 412345678901 on 15-Nov-2026';
      final parsed = TransactionTextParser.parse(sms);

      expect(parsed.amount, 349.0);
      expect(parsed.merchant, 'Swiggy');
      expect(parsed.vpa, 'swiggy@icici');
      expect(parsed.transactionIntent, 'expense');
      expect(parsed.refId, '412345678901');
      // No bank evidence in the SMS -> must NOT guess an arbitrary funding bank
      expect(parsed.last4, isNull);
      expect(parsed.bankName, isNull);
      expect(parsed.isAmbiguous, isFalse);
    });

    test('flags ambiguous VPA transactions appropriately for review queue', () {
      const sms = 'Sent Rs 450 to 9876543210@upi ref 998877665544';
      final parsed = TransactionTextParser.parse(sms);

      expect(parsed.amount, 450.0);
      expect(parsed.vpa, '9876543210@upi');
      expect(parsed.merchant, isNull);
      expect(parsed.transactionIntent, 'expense');
      // Numeric VPA without merchant name must remain ambiguous
      expect(parsed.isAmbiguous, isTrue);
    });

    test('classifies intent independently from merchant and direction signals', () {
      // 1. Failed payment
      const failed = 'Payment of Rs 650 to Swiggy failed due to bank server timeout';
      expect(TransactionTextParser.classifyIntent(failed), 'failed');

      // 2. Obligation / statement bill without debit confirmation
      const obligation = 'Your HDFC Bank Credit Card statement generated. Total amount due Rs 18,450 by 20-Nov';
      expect(TransactionTextParser.classifyIntent(obligation), 'obligation');

      // 3. Refund / reversal
      const refund = 'INR 349.00 refunded to your account ending 4321 from Swiggy ref 99223344';
      expect(TransactionTextParser.classifyIntent(refund), 'refund');

      // 4. Card payment receipt
      const cardReceipt = 'Thank you for paying towards your credit card ending 1002. Payment of INR 5000 received';
      expect(TransactionTextParser.classifyIntent(cardReceipt), 'card_payment');

      // 5. Self-transfer
      const transfer = 'Transferred Rs 20,000 to own account via NetBanking';
      expect(TransactionTextParser.classifyIntent(transfer), 'transfer');

      // 6. Generic income credit
      const salary = 'INR 75,000.00 credited to your A/c ending 1234 on 01-Nov';
      expect(TransactionTextParser.classifyIntent(salary), 'income');

      // 7. Standard debit expense
      const debit = 'Paid Rs 199 at Starbucks using Debit Card ending 5678';
      expect(TransactionTextParser.classifyIntent(debit), 'expense');
    });

    test('correctly prioritizes VPA processor extraction with compound handle', () {
      const sms = 'Debited Rs 410 from A/c XX4321 to uber.payu@hdfcbank UPI Ref 112233445566';
      final parsed = TransactionTextParser.parse(sms);

      expect(parsed.amount, 410.0);
      expect(parsed.merchant, 'Uber');
      expect(parsed.vpa, 'uber.payu@hdfcbank');
      expect(parsed.last4, '4321');
      expect(parsed.merchantSource, 'vpa_aggregator');
      expect(parsed.transactionIntent, 'expense');
      expect(parsed.isAmbiguous, isFalse);
    });

    test('validates separation of decisions on "Paid ₹349 to Swiggy through UPI"', () {
      const sms = 'Paid ₹349 to Swiggy through UPI ref 987654321';
      final parsed = TransactionTextParser.parse(sms);

      // Decision 1: Classification / Intent
      expect(parsed.transactionIntent, 'expense');
      expect(parsed.amount, 349.0);

      // Decision 2: Merchant identification
      expect(parsed.merchant, 'Swiggy');

      // Decision 3: Financial instrument attribution
      // Explicit source evidence is ABSENT -> last4 and bankName must be null
      expect(parsed.last4, isNull);
      expect(parsed.bankName, isNull);
    });
  });
}
