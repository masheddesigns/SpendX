import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/reminder_repo.dart';
import 'package:spend_x/models/reminder_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ReminderRepo repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE ${Tables.reminders} (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        type TEXT NOT NULL,
        date TEXT NOT NULL,
        repeat_type TEXT NOT NULL,
        is_completed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        linked_entity_id TEXT,
        amount REAL,
        notes TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        last_triggered_at TEXT,
        snoozed_until TEXT,
        record_status TEXT NOT NULL DEFAULT 'pending',
        source_type TEXT NOT NULL DEFAULT 'manual',
        source_id TEXT,
        next_trigger_at INTEGER
      );
    ''');
    repo = ReminderRepo(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('ReminderRepo.settleMatching tests', () {
    test('settles one-off utility bill reminder upon exact payment match', () async {
      final now = DateTime.now();
      await repo.insertGlobalReminder(
        Reminder(
          id: 'due_jio_home',
          title: 'JioHome Broadband Bill',
          amount: 706.82,
          dueDate: now.add(const Duration(days: 2)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.custom,
        ).toMap(),
      );

      final settled = await repo.settleMatching(
        amount: 706.82,
        date: now,
        notes: 'Paid towards JioHome broadband via UPI',
      );

      expect(settled, 1);
      final r = await repo.getById('due_jio_home');
      expect(r, isNotNull);
      expect(r!.isDone, isTrue);
      expect(r.isActive, isFalse);
    });

    test('rolls forward recurring monthly subscription upon expense match', () async {
      final dueDate = DateTime(2026, 10, 15);
      await repo.insertGlobalReminder(
        Reminder(
          id: 'sub_netflix',
          title: 'Netflix Subscription',
          amount: 199.0,
          dueDate: dueDate,
          recurrencePeriod: ReminderRecurrence.monthly,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.service,
        ).toMap(),
      );

      final settled = await repo.settleMatching(
        amount: 199.0,
        date: DateTime(2026, 10, 15),
        notes: 'Netflix monthly charge',
      );

      expect(settled, 1);
      final r = await repo.getById('sub_netflix');
      expect(r, isNotNull);
      expect(r!.isDone, isFalse);
      expect(r.recordStatus, ReminderRecordStatus.pending);
      // Rolled forward to November 15
      expect(r.dueDate!.month, 11);
      expect(r.dueDate!.day, 15);
      expect(r.dueDate!.year, 2026);
    });

    test('settles credit card due reminder upon full card payment', () async {
      final now = DateTime.now();
      await repo.insertGlobalReminder(
        Reminder(
          id: 'credit_due_card_hdfc',
          title: 'Credit Card Due: HDFC Regalia',
          linkedEntityId: 'card_hdfc',
          amount: 25000.0,
          dueDate: now.add(const Duration(days: 5)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.credit,
          sourceType: ReminderSourceType.credit,
        ).toMap(),
      );

      final settled = await repo.settleMatching(
        amount: 25000.0,
        date: now,
        linkedEntityId: 'card_hdfc',
        isCreditCardPayment: true,
      );

      expect(settled, 1);
      final r = await repo.getById('credit_due_card_hdfc');
      expect(r, isNotNull);
      expect(r!.isDone, isTrue);
    });

    test('decrements credit card due reminder upon partial card payment', () async {
      final now = DateTime.now();
      await repo.insertGlobalReminder(
        Reminder(
          id: 'credit_due_card_sbi',
          title: 'Credit Card Due: SBI Card',
          linkedEntityId: 'card_sbi',
          amount: 30000.0,
          dueDate: now.add(const Duration(days: 5)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.credit,
          sourceType: ReminderSourceType.credit,
        ).toMap(),
      );

      final settled = await repo.settleMatching(
        amount: 10000.0, // Partial payment
        date: now,
        linkedEntityId: 'card_sbi',
        isCreditCardPayment: true,
      );

      expect(settled, 1);
      final r = await repo.getById('credit_due_card_sbi');
      expect(r, isNotNull);
      expect(r!.isDone, isFalse); // Still pending
      expect(r.amount, 20000.0); // 30,000 - 10,000 = 20,000
    });

    test('does not settle reminder when amount or merchant do not match', () async {
      final now = DateTime.now();
      await repo.insertGlobalReminder(
        Reminder(
          id: 'due_spotify',
          title: 'Spotify Premium',
          amount: 179.0,
          dueDate: now.add(const Duration(days: 4)),
          recurrencePeriod: ReminderRecurrence.monthly,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.service,
        ).toMap(),
      );

      // Unrelated expense: Swiggy ₹450
      final settled = await repo.settleMatching(
        amount: 450.0,
        date: now,
        notes: 'Swiggy order',
      );

      expect(settled, 0);
      final r = await repo.getById('due_spotify');
      expect(r!.recordStatus, ReminderRecordStatus.pending);
    });
  });
}
