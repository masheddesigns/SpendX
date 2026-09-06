import 'package:flutter_test/flutter_test.dart';

import 'package:spend_x/models/reminder_model.dart';
import 'package:spend_x/services/sms_import_service.dart';

void main() {
  final service = SmsImportService.instance;

  group('SmsImportService.classifyMessage', () {
    test('detects a bank debit as an expense', () {
      final result = service.classifyMessage(
        'Debited Rs 280.00 from a/c X8434 on 06Sep26 14:58 via UPI to '
        'Nasima T P. Ref 624952703868.Bal Rs 404.41. Not you?Call '
        '18004251199 -Federal Bank',
        'VA-FEDBNK-T',
      );
      final t = result.transaction;
      expect(t, isNotNull);
      expect(t!.amount, 280.0);
      expect(t.isCredit, isFalse);
      expect(t.merchant, contains('Nasima'));
      // Trailing balance should also be detected.
      expect(result.balance, isNotNull);
      expect(result.balance!.amount, 404.41);
    });

    test('detects a bank credit as income', () {
      final result = service.classifyMessage(
        'Your A/C XXXXX569331 Credited INR 29,000.00 on 31/08/26 -Deposit '
        'of Cash at S5NW004365621 CDM. Avl Bal INR 29,926.35-SBI',
        'VA-CBSSBI-S',
      );
      final t = result.transaction;
      expect(t, isNotNull);
      expect(t!.amount, 29000.0);
      expect(t.isCredit, isTrue);
      expect(result.balance!.amount, 29926.35);
    });

    test('extracts the UPI merchant from the reference', () {
      final result = service.classifyMessage(
        'Rs. 500.00 Sent from x3284 on 06-Sep-2026 Info: '
        'UPI/DR/624952623558/5 KADEEJA  Not you? Call 18008907070 - JPBL',
        'JX-JIOPBS-S',
      );
      final t = result.transaction;
      expect(t, isNotNull);
      expect(t!.amount, 500.0);
      expect(t.isCredit, isFalse);
      expect(t.merchant, '5 KADEEJA');
    });

    test('filters upcoming/emandate notices', () {
      final result = service.classifyMessage(
        'Hi Sivek, you have an upcoming debit for the emandate registered '
        'on NETFLIX of INR199.0 on 30/8/2026.',
        'CP-OneCrd-S',
      );
      expect(result.transaction, isNull);
    });

    test('filters UPI-mandate notices', () {
      final result = service.classifyMessage(
        'UPI-Mandate successfully created towards Anomaly for Rs15000.00 -SBI',
        'VA-CBSSBI-S',
      );
      expect(result.transaction, isNull);
    });

    test('filters bonus/claim promotions', () {
      final result = service.classifyMessage(
        '100 INR Bonus is expiring soon. Claim now on Stake! '
        'FREE BONUS: go.stake.com/8D5C3',
        'JK-STKXXX-S',
      );
      expect(result.transaction, isNull);
    });

    test('filters bill-generated notices', () {
      final result = service.classifyMessage(
        'Your Edge CSB Bank RuPay Credit Card bill for Rs.786.45 has been '
        'generated. Tap here to track your card.',
        'VM-JTEDGE-S',
      );
      expect(result.transaction, isNull);
    });

    test('filters statement notices', () {
      final result = service.classifyMessage(
        'ICICI Bank Credit Card XX5007 Statement is sent to sk****ek@gmail.com',
        'VM-ICICIB-S',
      );
      expect(result.transaction, isNull);
    });

    test('filters registration notices', () {
      final result = service.classifyMessage(
        'ETMXXXXX6L registered in Commodity Derivatives Segment with broker '
        'INDSTOCKS PRIVATE LIMITED',
        'JK-NSESMS-S',
      );
      expect(result.transaction, isNull);
    });

    test('keeps a real UPI send transaction', () {
      final result = service.classifyMessage(
        'Rs. 600.61 Sent from x3284 on 29-Aug-2026 Info: '
        'UPI/DR/624148939809/SONU PETRO  Not you? Call 18008907070 - JPBL',
        'JD-JIOPBS-S',
      );
      expect(result.transaction, isNotNull);
      expect(result.transaction!.merchant, 'SONU PETRO');
    });
  });

  group('Reminder model round-trip', () {
    test('toMap/fromMap preserves fields', () {
      final due = DateTime(2026, 9, 15, 9, 0);
      final reminder = Reminder(
        id: 'rem-1',
        type: ReminderType.salary,
        title: 'Salary Due',
        dueDate: due,
        amount: 50000,
        isActive: true,
        status: ReminderStatus.upcoming,
        recordStatus: ReminderRecordStatus.pending,
        sourceType: ReminderSourceType.salary,
        sourceId: 'pay-1',
        linkedEntityId: 'pay-1',
      );

      final restored = Reminder.fromMap(reminder.toMap());
      expect(restored.id, 'rem-1');
      expect(restored.type, ReminderType.salary);
      expect(restored.dueDate, due);
      expect(restored.amount, 50000);
      expect(restored.sourceType, ReminderSourceType.salary);
      expect(restored.sourceId, 'pay-1');
      expect(restored.recordStatus, ReminderRecordStatus.pending);
      expect(restored.status, isNot(ReminderStatus.inactive));
    });

    test('done reminders are read back as inactive', () {
      final reminder = Reminder(
        id: 'rem-2',
        type: ReminderType.loan,
        title: 'EMI Due',
        dueDate: DateTime(2026, 9, 10),
        isActive: false,
        status: ReminderStatus.inactive,
        recordStatus: ReminderRecordStatus.done,
        sourceType: ReminderSourceType.loan,
      );
      final restored = Reminder.fromMap(reminder.toMap());
      expect(restored.recordStatus, ReminderRecordStatus.done);
      expect(restored.status, ReminderStatus.inactive);
    });

    test('parses legacy description encoding', () {
      final restored = Reminder.fromMap({
        'id': 'legacy-1',
        'title': 'Loan EMI Due',
        'description': 'loan:inst-123',
        'type': 'loan',
        'date': '2026-10-01T09:00:00.000',
        'repeat_type': 'once',
        'is_completed': 0,
        'created_at': '2026-01-01T00:00:00.000',
      });
      expect(restored.sourceType, ReminderSourceType.loan);
      expect(restored.linkedEntityId, 'inst-123');
      expect(restored.dueDate, DateTime(2026, 10, 1, 9, 0));
    });
  });
}