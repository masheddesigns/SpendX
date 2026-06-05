import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/features/sms/services/sms_parser.dart';

void main() {
  group('SmsParser security message filtering', () {
    test('ignores OTP messages that mention a transaction amount', () {
      final parsed = SmsParser.parse(
        sender: 'VK-HDFC',
        body:
            'OTP 123456 for online transaction of Rs.500.00 at MERCHANT is valid for 5 minutes. Do not share.',
        timestampMillis: DateTime(2026, 4, 16).millisecondsSinceEpoch,
      );

      expect(parsed, isNull);
    });

    test('ignores verification messages with payment wording', () {
      final parsed = SmsParser.parse(
        sender: 'JD-JIO',
        body:
            'Use code 998877 to verify payment of INR 239.00 from account XX3284. Never share this code.',
        timestampMillis: DateTime(2026, 4, 16).millisecondsSinceEpoch,
      );

      expect(parsed, isNull);
    });

    test('still parses completed debit transaction messages', () {
      final parsed = SmsParser.parse(
        sender: 'VK-HDFC',
        body:
            'Rs.500.00 debited from A/c XX3284 at AMAZON on 16-Apr-26. Avl Bal Rs.8,533.24.',
        timestampMillis: DateTime(2026, 4, 16).millisecondsSinceEpoch,
      );

      expect(parsed, isNotNull);
      expect(parsed!.amount, 500);
      expect(parsed.last4, '3284');
      expect(parsed.isCredit, isFalse);
    });
  });
}
