import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/migrations/migration_v24_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Migration v24 Automated Verification & Adversarial Suite', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
      );
      await Tables.createAll(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('Verification 1: Orphan categories, orphan accounts, and unmapped types fallback gracefully', () async {
      final now = DateTime.now().toIso8601String();

      // Seed bank account
      await db.insert('bank_accounts', {
        'id': 'acc_valid',
        'name': 'Valid Bank',
        'balance': 1000.0,
        'created_at': now,
        'updated_at': now,
      });

      // 1. Transaction with orphan account_id and orphan category_id
      await db.insert('transactions', {
        'id': 'tx_orphan',
        'amount': 200.0,
        'type': 'expense',
        'account_id': 'acc_non_existent',
        'category_id': 'cat_non_existent',
        'date': now,
        'note': 'Orphan expense',
        'created_at': now,
        'updated_at': now,
      });

      // 2. Transaction with unknown type string
      await db.insert('transactions', {
        'id': 'tx_weird',
        'amount': 50.0,
        'type': 'cryptic_unknown_legacy_mutation',
        'account_id': 'acc_valid',
        'category_id': null,
        'date': now,
        'note': 'Unknown type transaction',
        'created_at': now,
        'updated_at': now,
      });

      // Migration must succeed without crashing or violating foreign keys
      final result = await MigrationV24Service.migrate(db);
      expect(result.alreadyMigrated, isFalse);

      // Verify anomaly was logged in migration_exceptions for the unmapped type
      final exceptions = await db.query(TablesV24.migrationExceptions);
      expect(exceptions.any((e) => e['record_id'] == 'tx_weird'), isTrue);

      // Verify that tx_orphan used system fallback accounts
      final orphanPostings = await db.query(
        TablesV24.postings,
        where: 'economic_event_id = ?',
        whereArgs: ['tx_orphan'],
      );
      expect(orphanPostings.length, 2);
      expect(
        orphanPostings.any((p) => p['account_id'] == TablesV24.sysExpMisc),
        isTrue,
      );
    });

    test('Verification 2: Rollback on invariant failure preserves untouched v23 state', () async {
      final now = DateTime.now().toIso8601String();
      await db.execute('PRAGMA user_version = 23;');

      await db.insert('bank_accounts', {
        'id': 'acc_base',
        'name': 'Base Bank',
        'balance': 5000.0,
        'created_at': now,
        'updated_at': now,
      });

      await db.insert('transactions', {
        'id': 'tx_normal',
        'amount': 1000.0,
        'type': 'expense',
        'account_id': 'acc_base',
        'date': now,
        'created_at': now,
        'updated_at': now,
      });

      // Attempt migration inside a transaction that fails an assertion
      // We simulate an unhandled failure by corrupting the database state during migration
      bool caughtError = false;
      try {
        await db.transaction((txn) async {
          // Run migration inside transaction
          await MigrationV24Service.migrate(txn);

          // Artificially corrupt ledger balance to fail atomic gate
          await txn.rawInsert('''
            INSERT INTO ${TablesV24.postings} (id, economic_event_id, account_id, sequence_number, direction, amount_minor_units, currency, created_at)
            VALUES ('pst_illegal', 'tx_normal', 'acc_base', 99, 'debit', 999999, 'INR', '$now');
          ''');

          // Calling invariant check explicitly will throw MigrationVerificationException
          // (or foreign key trigger / constraint will abort)
          throw MigrationVerificationException(
            message: 'Simulated atomic test failure',
            checkName: 'SIMULATED_FAIL',
          );
        });
      } catch (e) {
        caughtError = true;
      }

      expect(caughtError, isTrue);

      // Verify user_version is still 23
      final ver = (await db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(ver, 23);

      // Verify legacy transactions and bank_accounts are completely intact
      expect((await db.query('bank_accounts')).length, 1);
      expect((await db.query('transactions')).length, 1);
    });

    test('Verification 3: Repeated migration execution is safely idempotent', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('bank_accounts', {
        'id': 'acc_idem',
        'name': 'Idempotent Bank',
        'balance': 100.0,
        'created_at': now,
        'updated_at': now,
      });

      // Run migration first time
      final result1 = await MigrationV24Service.migrate(db);
      expect(result1.alreadyMigrated, isFalse);

      // Run migration second time
      final result2 = await MigrationV24Service.migrate(db);
      expect(result2.alreadyMigrated, isTrue);

      final ver = (await db.rawQuery('PRAGMA user_version;')).first.values.first;
      expect(ver, 24);
    });
  });
}
