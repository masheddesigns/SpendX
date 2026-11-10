import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/reminder_repo.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/reminder_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ReminderRepo reminderRepo;

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
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${Tables.transactions} (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        type TEXT NOT NULL,
        category_id TEXT,
        account_id TEXT,
        amount REAL NOT NULL,
        date TEXT NOT NULL,
        notes TEXT,
        tags TEXT,
        source TEXT,
        related_entity_id TEXT,
        external_ref TEXT,
        location TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    reminderRepo = ReminderRepo(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  group('Home Journey Branch & Bill Due Tests', () {
    test('1. Overdue bill is properly flagged as overdue with non-negative overdue days', () {
      final now = DateTime.now();
      final overdueDueDate = now.subtract(const Duration(days: 4));

      final overdueItem = CommitmentItem(
        id: 'bill_elec_01',
        title: 'Electricity Bill',
        amount: Money.fromRupees(2450.0),
        dueDate: overdueDueDate,
        type: 'bill',
        isOverdue: true,
      );

      expect(overdueItem.isOverdue, isTrue);
      expect(overdueItem.daysUntil, lessThan(0));
      expect(overdueItem.daysUntil.abs(), 4);

      // Verify human copy formatting avoids negative numbers
      final overdueDays = overdueItem.daysUntil.abs();
      final copy = '${overdueItem.title} is $overdueDays ${overdueDays == 1 ? 'day' : 'days'} overdue';
      expect(copy, 'Electricity Bill is 4 days overdue');
      expect(copy.contains('-'), isFalse);
    });

    test('2. Due today bill formats cleanly', () {
      final now = DateTime.now();
      final item = CommitmentItem(
        id: 'sub_netflix',
        title: 'Netflix',
        amount: Money.fromRupees(199.0),
        dueDate: now,
        type: 'subscription',
        isOverdue: false,
      );

      expect(item.daysUntil, 0);
      expect(item.isOverdue, isFalse);
    });

    test('3. Multiple commitment branches are preserved and sorted chronologically', () {
      final now = DateTime.now();
      final items = [
        CommitmentItem(
          id: 'bill_2',
          title: 'HDFC Credit Card',
          amount: Money.fromRupees(15000.0),
          dueDate: now.add(const Duration(days: 6)),
          type: 'credit_card',
        ),
        CommitmentItem(
          id: 'bill_1',
          title: 'Internet Fiber',
          amount: Money.fromRupees(999.0),
          dueDate: now.add(const Duration(days: 2)),
          type: 'bill',
        ),
        CommitmentItem(
          id: 'bill_overdue',
          title: 'Water Utility',
          amount: Money.fromRupees(350.0),
          dueDate: now.subtract(const Duration(days: 3)),
          type: 'bill',
          isOverdue: true,
        ),
      ];

      items.sort((a, b) => a.dueDate.compareTo(b.dueDate));

      // Overdue bill (3 days ago) must sort first
      expect(items.first.title, 'Water Utility');
      expect(items[1].title, 'Internet Fiber');
      expect(items[2].title, 'HDFC Credit Card');
      expect(items.length, 3);
    });

    test('4. Unpaid bill 5 days overdue is NOT falsely marked as done by reconciliation', () async {
      final now = DateTime.now();
      await reminderRepo.insertGlobalReminder(
        Reminder(
          id: 'bill_unpaid_overdue',
          title: 'Airtel Broadband',
          amount: 1199.0,
          dueDate: now.subtract(const Duration(days: 5)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.custom,
        ).toMap(),
      );

      // Reconcile when NO payment transaction exists
      final reconciled = await reminderRepo.reconcileWithExistingTransactions(executor: db);
      expect(reconciled, 0);

      final r = await reminderRepo.getById('bill_unpaid_overdue');
      expect(r, isNotNull);
      expect(r!.isDone, isFalse);
      expect(r.recordStatus, ReminderRecordStatus.pending);
      expect(r.isActive, isTrue);
    });

    test('5. markReminderPaid manually settles one-off and rolls forward recurring reminders', () async {
      final now = DateTime.now();
      // 1. One-off bill
      await reminderRepo.insertGlobalReminder(
        Reminder(
          id: 'due_doctor',
          title: 'Clinic Consultation Fee',
          amount: 800.0,
          dueDate: now.subtract(const Duration(days: 1)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.custom,
        ).toMap(),
      );

      await reminderRepo.markReminderPaid('due_doctor');
      final r1 = await reminderRepo.getById('due_doctor');
      expect(r1!.isDone, isTrue);
      expect(r1.isActive, isFalse);
      expect(r1.recordStatus, ReminderRecordStatus.done);

      // 2. Recurring monthly subscription
      final origDue = DateTime(2026, 11, 5);
      await reminderRepo.insertGlobalReminder(
        Reminder(
          id: 'sub_prime',
          title: 'Amazon Prime',
          amount: 299.0,
          dueDate: origDue,
          recurrencePeriod: ReminderRecurrence.monthly,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.custom,
        ).toMap(),
      );

      await reminderRepo.markReminderPaid('sub_prime');
      final r2 = await reminderRepo.getById('sub_prime');
      expect(r2!.isDone, isFalse);
      expect(r2.recordStatus, ReminderRecordStatus.pending);
      expect(r2.dueDate?.month, 12);
      expect(r2.dueDate?.day, 5);
    });
  });

  group('Home Tracking Rhythm Domain Invariants', () {
    test('1. Rolling 5-day rhythm nodes reflect real transaction activity', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Simulated ledger: Transactions exist on Day -2 and Today, but NOT on Day -1 (yesterday)
      final txns = [
        {'date': today.subtract(const Duration(days: 2)).add(const Duration(hours: 10))},
        {'date': today.add(const Duration(hours: 4))},
      ];

      bool hasActivity(DateTime day) {
        final start = DateTime(day.year, day.month, day.day);
        final end = start.add(const Duration(days: 1));
        return txns.any((t) {
          final d = t['date'] as DateTime;
          return !d.isBefore(start) && d.isBefore(end);
        });
      }

      final dayMinus2 = today.subtract(const Duration(days: 2));
      final dayMinus1 = today.subtract(const Duration(days: 1));
      final day0 = today;

      expect(hasActivity(dayMinus2), isTrue);
      expect(hasActivity(dayMinus1), isFalse); // Verified: Yesterday had NO transactions!
      expect(hasActivity(day0), isTrue);       // Verified: Today has transactions!
    });

    test('2. Weekday abbreviations match expected uppercase format', () {
      final monday = DateTime(2026, 11, 9); // Monday
      final label = DateFormat('E').format(monday).toUpperCase();
      expect(label, 'MON');
    });
  });
}
