import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/transaction_text_parser.dart';

void main() {
  test('Air Arabia AUH SMS with foreign currency and Avl Limit suffix', () {
    const sms = 'AED 2,508.28 spent using ICICI Bank Card XX5007 on 04-Oct-26 on AIR ARABIA AUH. Avl Limit: INR 83,397.13.';
    final parsed = TransactionTextParser.parse(sms);

    expect(parsed.amount, equals(2508.28));
    expect(parsed.merchant, isNotNull);
    expect(parsed.merchant!.toLowerCase(), contains('air arabia'));
    expect(parsed.merchant!.toLowerCase().contains('avl limit'), isFalse, reason: 'Merchant must not contain trailing Avl Limit noise');
    expect(parsed.last4, equals('5007'));
  });
}
