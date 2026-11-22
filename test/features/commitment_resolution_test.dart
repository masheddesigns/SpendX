import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/credit_card.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Commitment Settlement and Payment Recognition Tests', () {
    late Database db;
    late CanonicalAccountRepository accountRepo;
    late CanonicalEventRepository eventRepo;
    late CanonicalFinancialQueryRepository queryRepo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await TablesV24.createAllV24(db);
      await TablesV24.installTriggers(db);
      await TablesV24.seedSystemAccounts(db);

      // Create legacy tables for transitional compatibility
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${Tables.creditCards} (
          id TEXT PRIMARY KEY,
          user_id TEXT,
          name TEXT,
          bank TEXT,
          last4 TEXT,
          limit_amount REAL,
          billing_day INTEGER,
          due_day INTEGER,
          card_type TEXT,
          color TEXT,
          used_amount REAL DEFAULT 0.0,
          last_statement_balance REAL DEFAULT 0.0,
          created_at TEXT
        );
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${Tables.reminders} (
          id TEXT PRIMARY KEY,
          user_id TEXT,
          title TEXT,
          amount REAL,
          date TEXT,
          type TEXT,
          is_active INTEGER DEFAULT 1,
          is_completed INTEGER DEFAULT 0,
          record_status TEXT,
          linked_entity_id TEXT,
          snoozed_until TEXT,
          last_triggered_at TEXT,
          created_at TEXT
        );
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${Tables.recurring_templates} (
          id TEXT PRIMARY KEY,
          user_id TEXT,
          name TEXT,
          amount REAL,
          type TEXT,
          category_id TEXT,
          frequency TEXT,
          interval INTEGER,
          day_of_month INTEGER,
          day_of_week INTEGER,
          last_generated TEXT,
          next_generation TEXT,
          is_active INTEGER DEFAULT 1,
          created_at TEXT
        );
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${Tables.transactions} (
          id TEXT PRIMARY KEY,
          user_id TEXT,
          type TEXT,
          category_id TEXT,
          account_id TEXT,
          amount REAL,
          currency TEXT DEFAULT 'INR',
          date TEXT,
          notes TEXT,
          tags TEXT,
          source TEXT,
          related_entity_id TEXT,
          external_ref TEXT,
          location TEXT,
          is_deleted INTEGER DEFAULT 0,
          created_at TEXT,
          updated_at TEXT
        );
      ''');

      accountRepo = CanonicalAccountRepository(executor: db);
      eventRepo = CanonicalEventRepository(executor: db);
      queryRepo = CanonicalFinancialQueryRepository(executor: db);

      final now = DateTime.now();
      final dueDay = now.add(const Duration(days: 3)).day;

      await db.insert(TablesV24.accounts, {
        'id': 'card_hdfc_regalia',
        'account_type': 'liability',
        'subtype': 'credit_card',
        'name': 'HDFC Regalia',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'institution_name': 'HDFC',
        'account_number_last4': '1234',
        'credit_limit_minor_units': 10000000,
        'billing_cycle_day': 1,
        'payment_due_day': dueDay,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
    });

    tearDown(() async {
      await db.close();
    });

    test('Statement balance shows as commitment when unpaid and due within 14 days', () async {
      final now = DateTime.now();
      final dueDay = now.add(const Duration(days: 3)).day;

      await db.insert(Tables.creditCards, {
        'id': 'card_hdfc_regalia',
        'user_id': 'offline_user',
        'name': 'HDFC Regalia',
        'bank': 'HDFC',
        'last4': '1234',
        'limit_amount': 100000.0,
        'billing_day': 1,
        'due_day': dueDay,
        'used_amount': 15000.0,
        'last_statement_balance': 15000.0,
        'created_at': now.toIso8601String(),
      });

      final calc = await queryRepo.getSafeToSpend();
      expect(calc.commitmentItems.any((c) => c.id == 'card_hdfc_regalia'), isTrue);
      expect(calc.knownCommitments14d.toRupees, 15000.0);
    });

    test('Marking card cycle settled in SharedPreferences immediately clears commitment', () async {
      final now = DateTime.now();
      final nextDue = CreditCard.safeDate(now.year, now.month, now.add(const Duration(days: 3)).day);

      await db.insert(Tables.creditCards, {
        'id': 'card_hdfc_regalia',
        'user_id': 'offline_user',
        'name': 'HDFC Regalia',
        'bank': 'HDFC',
        'last4': '1234',
        'limit_amount': 100000.0,
        'billing_day': 1,
        'due_day': nextDue.day,
        'used_amount': 15000.0,
        'last_statement_balance': 15000.0,
        'created_at': now.toIso8601String(),
      });

      // Before settlement: commitment exists
      var calc = await queryRepo.getSafeToSpend();
      expect(calc.commitmentItems.any((c) => c.id == 'card_hdfc_regalia'), isTrue);

      // Simulate tapping "Mark Paid" (clears statement balance and sets cycleKey)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('card_settled_card_hdfc_regalia_${nextDue.year}_${nextDue.month}', true);
      await db.rawUpdate('UPDATE ${Tables.creditCards} SET last_statement_balance = 0 WHERE id = ?', ['card_hdfc_regalia']);

      // After settlement: commitment is completely gone
      calc = await queryRepo.getSafeToSpend();
      expect(calc.commitmentItems.any((c) => c.id == 'card_hdfc_regalia'), isFalse);
      expect(calc.knownCommitments14d.toRupees, 0.0);
    });

    test('Recent credit_payment transaction automatically reconciles and clears statement due', () async {
      final now = DateTime.now();
      final dueDay = now.add(const Duration(days: 3)).day;

      await db.insert(Tables.creditCards, {
        'id': 'card_hdfc_regalia',
        'user_id': 'offline_user',
        'name': 'HDFC Regalia',
        'bank': 'HDFC',
        'last4': '1234',
        'limit_amount': 100000.0,
        'billing_day': 1,
        'due_day': dueDay,
        'used_amount': 15000.0,
        'last_statement_balance': 15000.0,
        'created_at': now.toIso8601String(),
      });

      // Insert credit card payment transaction made 2 days ago
      await db.insert(Tables.transactions, {
        'id': 'tx_pay_1',
        'user_id': 'offline_user',
        'type': 'credit_payment',
        'account_id': 'acc_bank_sbi',
        'related_entity_id': 'card_hdfc_regalia',
        'amount': 15000.0,
        'date': now.subtract(const Duration(days: 2)).toIso8601String(),
        'notes': 'Payment to HDFC Regalia',
        'source': 'credit_card_payment',
        'is_deleted': 0,
        'created_at': now.toIso8601String(),
      });

      final calc = await queryRepo.getSafeToSpend();
      // Should automatically recognize payment and not show as due
      expect(calc.commitmentItems.any((c) => c.id == 'card_hdfc_regalia'), isFalse);
      expect(calc.knownCommitments14d.toRupees, 0.0);
    });
  });
}
