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

    test('reconcileWithExistingTransactions marks past paid credit card bill as completed', () async {
      final now = DateTime.now();
      // 1. Existing transaction in DB: ₹25,000 paid to HDFC credit card 10 days ago
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${Tables.transactions} (
          id TEXT PRIMARY KEY,
          user_id TEXT,
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

      await db.insert(Tables.transactions, {
        'id': 'tx_pay_hdfc_25k',
        'user_id': 'offline_user',
        'type': 'credit_payment',
        'amount': 25000.0,
        'date': now.subtract(const Duration(days: 10)).toIso8601String(),
        'notes': 'Payment towards HDFC Bank Credit Card',
        'source': 'credit_card_payment',
        'related_entity_id': 'card_hdfc_6366',
        'created_at': now.subtract(const Duration(days: 10)).toIso8601String(),
        'updated_at': now.subtract(const Duration(days: 10)).toIso8601String(),
      });

      // 2. Pending reminder for HDFC Credit Card Bill due around that time
      await repo.insertGlobalReminder(
        Reminder(
          id: 'sms_due_hdfc_credit_card_2026_10',
          title: 'HDFC Credit Card Bill',
          amount: 25000.0,
          dueDate: now.subtract(const Duration(days: 5)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.credit,
          linkedEntityId: 'card_hdfc_6366',
        ).toMap(),
      );

      final count = await repo.reconcileWithExistingTransactions(executor: db);
      expect(count, 1);

      final r = await repo.getById('sms_due_hdfc_credit_card_2026_10');
      expect(r, isNotNull);
      expect(r!.isDone, isTrue);
      expect(r.recordStatus, ReminderRecordStatus.done);
    });

    test('reconcileWithExistingTransactions auto-settles credit card bill when card statement is zero', () async {
      final repo = ReminderRepo(database: db);
      final now = DateTime.now();

      await TablesV24.createAllV24(db);

      await db.execute('''
        CREATE TABLE IF NOT EXISTS credit_cards (
          id TEXT PRIMARY KEY,
          last_statement_balance REAL NOT NULL DEFAULT 0
        );
      ''');

      await db.insert('accounts', {
        'id': 'card_hdfc_real',
        'name': 'HDFC Card',
        'institution_name': 'HDFC',
        'account_type': 'liability',
        'subtype': 'credit_card',
        'account_number_last4': '6366',
        'currency': 'INR',
        'credit_limit_minor_units': 15000000,
        'billing_cycle_day': 1,
        'payment_due_day': 20,
        'is_active': 1,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });

      await db.insert('credit_cards', {
        'id': 'card_hdfc_real',
        'last_statement_balance': 0.0,
      });

      await repo.insertGlobalReminder(
        Reminder(
          id: 'sms_due_hdfc_zero_stmt',
          title: 'HDFC Credit Card Bill',
          amount: 25000.0,
          dueDate: now.subtract(const Duration(days: 9)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.credit,
          linkedEntityId: 'card_hdfc_real',
        ).toMap(),
      );

      final count = await repo.reconcileWithExistingTransactions(executor: db);
      expect(count, greaterThanOrEqualTo(1));

      final r = await repo.getById('sms_due_hdfc_zero_stmt');
      expect(r, isNotNull);
      expect(r!.isDone, isTrue);
      expect(r.recordStatus, ReminderRecordStatus.done);
    });

    test('reconcileWithExistingTransactions auto-expires ancient overdue reminders older than 3 days', () async {
      final repo = ReminderRepo(database: db);
      final now = DateTime.now();

      // Reminder from 20 days ago (past billing cycle)
      await repo.insertGlobalReminder(
        Reminder(
          id: 'sms_due_anomaly_old',
          title: 'Anomaly AutoPay',
          amount: 929.0,
          dueDate: now.subtract(const Duration(days: 20)),
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.custom,
        ).toMap(),
      );

      final count = await repo.reconcileWithExistingTransactions(executor: db);
      expect(count, greaterThanOrEqualTo(1));

      final r = await repo.getById('sms_due_anomaly_old');
      expect(r, isNotNull);
      expect(r!.isDone, isTrue);
      expect(r.recordStatus, ReminderRecordStatus.done);
    });

    test('reconcileWithExistingTransactions matches and settles against canonical V24 postings', () async {
      final repo = ReminderRepo(database: db);
      final now = DateTime.now();

      await TablesV24.createAllV24(db);

      // Post a V24 economic event & posting for Netflix ₹199
      await db.insert(TablesV24.economicEvents, {
        'id': 'ev_netflix_199',
        'event_type': 'expense',
        'lifecycle_status': 'posted',
        'timestamp': now.subtract(const Duration(days: 1)).toIso8601String(),
        'description': 'Netflix Subscription',
        'currency': 'INR',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });

      await db.insert(TablesV24.postings, {
        'id': 'post_netflix_199',
        'economic_event_id': 'ev_netflix_199',
        'account_id': 'acc_test_bank',
        'direction': 'debit',
        'amount_minor_units': 19900,
        'currency': 'INR',
        'sequence_number': 1,
        'created_at': now.toIso8601String(),
      });

      // Active reminder for Netflix due today
      await repo.insertGlobalReminder(
        Reminder(
          id: 'sms_due_netflix_today',
          title: 'Netflix Subscription',
          amount: 199.0,
          dueDate: now,
          recurrencePeriod: ReminderRecurrence.none,
          recordStatus: ReminderRecordStatus.pending,
          type: ReminderType.custom,
        ).toMap(),
      );

      final count = await repo.reconcileWithExistingTransactions(executor: db);
      expect(count, greaterThanOrEqualTo(1));

      final r = await repo.getById('sms_due_netflix_today');
      expect(r, isNotNull);
      expect(r!.isDone, isTrue);
      expect(r.recordStatus, ReminderRecordStatus.done);
    });
  });
}
