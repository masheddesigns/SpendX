import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/sms_import_service.dart';
import 'package:spend_x/services/transaction_text_parser.dart';
import 'package:spend_x/services/merchant_normalizer.dart';
import 'package:spend_x/models/transaction.dart';
import 'package:spend_x/models/lending.dart';

void main() {
  group('Feature 1: Moved & Internal Transfers Sub-Filtering', () {
    test('Correctly classifies Moved sub-filters (card repayment, self-transfer, deposits)', () {
      final ccPaymentTx = Transaction(
        id: 'tx_cc_1',
        userId: 'user_1',
        amount: 25000,
        date: DateTime.now(),
        type: 'credit_payment',
        source: 'credit_card_payment',
        notes: 'Payment towards ICICI Credit Card',
      );

      final selfTransferTx = Transaction(
        id: 'tx_self_1',
        userId: 'user_1',
        amount: 5000,
        date: DateTime.now(),
        type: 'transfer',
        source: 'bank_transfer',
        notes: 'Transfer to Federal Bank',
      );

      final fdTransferTx = Transaction(
        id: 'tx_fd_1',
        userId: 'user_1',
        amount: 50000,
        date: DateTime.now(),
        type: 'transfer',
        source: 'bank_transfer',
        notes: 'Moved to ICICI Fixed Deposit (..1234)',
      );

      expect(ccPaymentTx.isTransferType, isTrue);
      expect(selfTransferTx.isTransferType, isTrue);
      expect(fdTransferTx.isTransferType, isTrue);

      // Verify keyword detection
      expect(ccPaymentTx.notes.toLowerCase().contains('credit card'), isTrue);
      expect(fdTransferTx.notes.toLowerCase().contains('fixed deposit'), isTrue);
    });
  });

  group('Feature 2: FD / RD Deposit Booking Detection', () {
    test('Classifies FD creation SMS as internal transfer', () {
      const fdSms = 'Your Fixed Deposit A/c No. XXXXX1234 has been created for Rs. 50,000.00 on 10-Nov-26 at 7.10% p.a.';
      final result = SmsImportService.instance.classifyMessage(fdSms, 'HDFCBK');

      expect(result.eventType, equals(SmsEventType.transfer));
      expect(result.transaction?.merchant, equals('Fixed Deposit'));
    });

    test('Classifies RD installment SMS as internal transfer', () {
      const rdSms = 'Rs 5,000.00 debited from A/c XX8434 towards RD A/c XX5678 installment.';
      final result = SmsImportService.instance.classifyMessage(rdSms, 'FEDBNK');

      expect(result.eventType, equals(SmsEventType.transfer));
      expect(result.transaction?.merchant, equals('Recurring Deposit'));
    });
  });

  group('Feature 3: Peer Lending & Settlement Architecture', () {
    test('Lending model tracks remaining balance and settlement accurately', () {
      final loan = Lending(
        personName: 'Afnas P',
        type: 'lent',
        originalAmount: 2000.0,
        paidAmount: 0.0,
      );

      expect(loan.remainingAmount, equals(2000.0));
      expect(loan.isSettled, isFalse);

      // Partial settlement
      final partial = loan.copyWith(paidAmount: 1000.0);
      expect(partial.remainingAmount, equals(1000.0));
      expect(partial.isSettled, isFalse);

      // Full settlement
      final settled = loan.copyWith(
        paidAmount: 2000.0,
        isSettled: true,
      );
      expect(settled.remainingAmount, equals(0.0));
      expect(settled.isSettled, isTrue);
    });
  });

  group('Foreign Currency & Merchant Normalization', () {
    test('Air Arabia foreign currency is cleanly preserved and normalized', () {
      const sms = 'AED 2,508.28 spent using ICICI Bank Card XX5007 on 04-Oct-26 on AIR ARABIA AUH. Avl Limit: INR 83,397.13.';
      final parsed = TransactionTextParser.parse(sms);

      expect(parsed.amount, equals(2508.28));
      final norm = MerchantNormalizer.canonicalDisplay(parsed.merchant ?? '');
      expect(norm, equals('Air Arabia'));
    });
  });
}
