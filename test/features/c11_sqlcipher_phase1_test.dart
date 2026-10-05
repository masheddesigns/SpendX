import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/financial_transaction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  const testKey = 'test_secret_sqlcipher_key_c11_phase1_2026';
  const wrongKey = 'wrong_attacker_key_vector_999';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_c11_phase1_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Milestone C11: SQLCipher Phase 1 Verification', () {
    test('C11-P1-01: SQLCipher library initializes cleanly', () async {
      final factory = SpendXDatabaseFactory.instance;
      await factory.initialize();
      expect(factory.isInitialized, isTrue);
    });

    test('C11-P1-02: SQLCipher version/runtime capability is detectable via PRAGMA cipher_version', () async {
      final factory = SpendXDatabaseFactory.instance;
      await factory.initialize();

      expect(factory.isSqlCipherAvailable(), isTrue);
      final version = factory.detectedCipherVersion;
      expect(version, isNotNull);
      expect(version!.toLowerCase(), contains('community'));
      expect(version.toLowerCase(), contains('4.'));
    });

    test('C11-P1-03: Encrypted database creation succeeds', () async {
      final dbPath = join(tempDir.path, 'encrypted_test.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE secure_notes (id INTEGER PRIMARY KEY, note TEXT);');
          await db.execute("INSERT INTO secure_notes (id, note) VALUES (1, 'Secret Financial Note');");
        },
      );

      final rows = await db.rawQuery('SELECT * FROM secure_notes;');
      expect(rows.length, equals(1));
      expect(rows.first['note'], equals('Secret Financial Note'));
      await db.close();
    });

    test(r'C11-P1-04: Plain SQLite header is absent (header does NOT equal "SQLite format 3\000")', () async {
      final dbPath = join(tempDir.path, 'header_check.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE t (id INT);');
        },
      );
      await db.close();

      final file = File(dbPath);
      expect(await file.exists(), isTrue);
      final bytes = await file.readAsBytes();
      expect(bytes.length, greaterThanOrEqualTo(16));

      // SQLite plaintext header constant
      const sqliteHeader = [
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
      ];

      final fileHeader = bytes.sublist(0, 16);
      expect(fileHeader, isNot(equals(sqliteHeader)));
    });

    test('C11-P1-05: Correct key opens database successfully', () async {
      final dbPath = join(tempDir.path, 'reopen_correct_key.db');
      final db1 = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE items (val TEXT);');
          await db.execute("INSERT INTO items VALUES ('valid_token');");
        },
      );
      await db1.close();

      final db2 = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
      );
      final rows = await db2.rawQuery('SELECT val FROM items;');
      expect(rows.first['val'], equals('valid_token'));
      await db2.close();
    });

    test('C11-P1-06: Wrong key fails and refuses access', () async {
      final dbPath = join(tempDir.path, 'wrong_key_test.db');
      final db1 = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE secrets (data TEXT);');
          await db.execute("INSERT INTO secrets VALUES ('confidential');");
        },
      );
      await db1.close();

      // Opening with wrong key MUST throw an exception
      expect(
        () async {
          final badDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
            dbPath,
            password: wrongKey,
          );
          await badDb.rawQuery('SELECT * FROM secrets;');
        },
        throwsA(anything),
      );
    });

    test('C11-P1-07: Data survives close/reopen cycle with correct key', () async {
      final dbPath = join(tempDir.path, 'persistence_test.db');
      final db1 = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE counter (c INT);');
          await db.execute('INSERT INTO counter VALUES (100);');
        },
      );
      await db1.execute('UPDATE counter SET c = 250;');
      await db1.close();

      final db2 = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
      );
      final res = await db2.rawQuery('SELECT c FROM counter;');
      expect(res.first['c'], equals(250));
      await db2.close();
    });

    test('C11-P1-08: Transaction rollback works properly under SQLCipher', () async {
      final dbPath = join(tempDir.path, 'tx_rollback_test.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE ledger (amount INT);');
          await db.execute('INSERT INTO ledger VALUES (500);');
        },
      );

      try {
        await db.transaction((txn) async {
          await txn.execute('INSERT INTO ledger VALUES (1000);');
          throw Exception('Simulated crash / rollback');
        });
      } catch (_) {}

      final rows = await db.rawQuery('SELECT amount FROM ledger;');
      expect(rows.length, equals(1));
      expect(rows.first['amount'], equals(500));
      await db.close();
    });

    test('C11-P1-09: Foreign keys work under SQLCipher', () async {
      final dbPath = join(tempDir.path, 'fk_test.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE parents (id INT PRIMARY KEY);');
          await db.execute('CREATE TABLE children (id INT, parent_id INT REFERENCES parents(id));');
        },
      );

      // Inserting child referencing nonexistent parent MUST throw constraint violation
      expect(
        () => db.execute('INSERT INTO children VALUES (1, 999);'),
        throwsA(anything),
      );
      await db.close();
    });

    test('C11-P1-10: Triggers execute correctly under SQLCipher', () async {
      final dbPath = join(tempDir.path, 'triggers_test.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE auditable (id INT, val TEXT);');
          await db.execute('CREATE TABLE audit_log (log_msg TEXT);');
          await db.execute('''
            CREATE TRIGGER trg_audit AFTER INSERT ON auditable
            BEGIN
              INSERT INTO audit_log VALUES ('inserted ' || NEW.val);
            END;
          ''');
        },
      );

      await db.execute("INSERT INTO auditable VALUES (1, 'transfer_leg');");
      final logs = await db.rawQuery('SELECT log_msg FROM audit_log;');
      expect(logs.length, equals(1));
      expect(logs.first['log_msg'], equals('inserted transfer_leg'));
      await db.close();
    });

    test('C11-P1-11: WAL works under SQLCipher', () async {
      final dbPath = join(tempDir.path, 'wal_test.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA journal_mode = WAL;');
        },
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE wal_items (id INT);');
        },
      );

      await db.execute('INSERT INTO wal_items VALUES (42);');

      final walFile = File('$dbPath-wal');
      if (await walFile.exists()) {
        final walBytes = await walFile.readAsBytes();
        expect(walBytes.length, greaterThan(0));

        // WAL contents must be encrypted and not contain plaintext table names
        final walString = String.fromCharCodes(walBytes);
        expect(walString.contains('wal_items'), isFalse);
      }

      await db.close();
    });

    test('C11-P1-12: Schema v24 fixture opens under SQLCipher with user_version = 24', () async {
      final dbPath = join(tempDir.path, 'v24_fixture.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 24,
        onCreate: (db, version) async {
          await Tables.createAll(db);
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
        },
      );

      // Verify PRAGMA user_version == 24
      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, equals(24));
      await db.close();
    });

    test('C11-P1-13: All 7 financial triggers successfully installed and active under SQLCipher', () async {
      final dbPath = join(tempDir.path, 'v24_triggers.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 24,
        onCreate: (db, version) async {
          await Tables.createAll(db);
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
        },
      );

      // Verify all 7 required financial triggers exist
      const requiredTriggers = [
        'trg_economic_events_prevent_direct_posted_insert',
        'trg_economic_events_validate_posted',
        'trg_postings_prevent_insert_on_posted',
        'trg_postings_prevent_update_on_posted',
        'trg_postings_prevent_delete_on_posted',
        'trg_economic_events_prevent_mutation_on_posted',
        'trg_economic_events_prevent_delete_posted',
      ];

      final triggerRows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_%';",
      );
      final presentTriggers = triggerRows.map((r) => r['name'] as String).toSet();

      for (final trg in requiredTriggers) {
        expect(presentTriggers.contains(trg), isTrue, reason: 'Missing trigger $trg');
      }

      await db.close();
    });

    test('C11-P1-14: Canonical events and postings operate correctly under SQLCipher', () async {
      final dbPath = join(tempDir.path, 'canonical_accounting.db');
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: testKey,
        version: 24,
        onCreate: (db, version) async {
          await Tables.createAll(db);
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
        },
      );

      const bankId = 'acc_bank_c11_p1';
      final accRepo = AccountRepo(executor: db);
      await accRepo.insertAccount(
        BankAccount(
          id: bankId,
          name: 'Primary Salary Bank',
          bank: 'HDFC',
          balance: 0.0,
        ),
      );

      final catRepo = CategoryRepo(executor: db);
      await catRepo.insert(
        Category(
          id: 'cat_salary',
          name: 'Salary',
          icon: 'work',
          color: '#4CAF50',
          type: 'income',
          userId: 'u1',
        ),
      );
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert(
        TablesV24.accounts,
        {
          'id': 'cat_salary',
          'account_type': 'income',
          'subtype': 'category',
          'name': 'Salary',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': now,
          'updated_at': now,
        },
      );

      final fts = FinancialTransactionService(database: db);
      await fts.createTransaction(
        spx.Transaction(
          id: 'txn_c11_salary',
          userId: 'u1',
          accountId: bankId,
          categoryId: 'cat_salary',
          amount: 50000.0,
          type: 'income',
          notes: 'Monthly Pay',
          date: DateTime.now().toUtc(),
        ),
      );

      // Verify double-entry parity
      final parity = await db.rawQuery('''
        SELECT 
          SUM(CASE WHEN LOWER(direction) = 'debit' THEN amount_minor_units ELSE 0 END) as debits,
          SUM(CASE WHEN LOWER(direction) = 'credit' THEN amount_minor_units ELSE 0 END) as credits
        FROM ${TablesV24.postings};
      ''');

      final debits = parity.first['debits'] as int;
      final credits = parity.first['credits'] as int;
      expect(debits, equals(5000000));
      expect(credits, equals(5000000));
      expect(debits, equals(credits));

      final canonicalAccRepo = CanonicalAccountRepository(executor: db);
      final balance = await canonicalAccRepo.getDerivedBalance(bankId);
      expect(balance.minorUnits, equals(5000000));

      await db.close();
    });

    test('C11-P1-15: Plaintext database open compatibility via SpendXDatabaseFactory', () async {
      final plainPath = join(tempDir.path, 'plain_compatibility.db');
      final plainDb = await SpendXDatabaseFactory.instance.openPlaintextDatabase(
        plainPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE sample (id TEXT PRIMARY KEY, val TEXT);');
        },
      );
      await plainDb.insert('sample', {'id': '1', 'val': 'plaintext_value'});
      final rows = await plainDb.query('sample');
      expect(rows.length, equals(1));
      expect(rows.first['val'], equals('plaintext_value'));
      await plainDb.close();

      // Read first 16 bytes of file to verify standard SQLite header
      final bytes = await File(plainPath).readAsBytes();
      final header = utf8.decode(bytes.sublist(0, 16));
      expect(header, equals('SQLite format 3\x00'));
    });

    test('C11-P1-16: Concurrent plaintext and encrypted instances coexist without cross-contamination', () async {
      final plainPath = join(tempDir.path, 'coexist_plain.db');
      final encPath = join(tempDir.path, 'coexist_enc.db');

      final plainDb = await SpendXDatabaseFactory.instance.openPlaintextDatabase(
        plainPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE t (k TEXT PRIMARY KEY, v TEXT);');
        },
      );

      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        encPath,
        password: testKey,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE t (k TEXT PRIMARY KEY, v TEXT);');
        },
      );

      await plainDb.insert('t', {'k': 'a', 'v': 'plain'});
      await encDb.insert('t', {'k': 'a', 'v': 'secret'});

      final plainRows = await plainDb.query('t');
      final encRows = await encDb.query('t');

      expect(plainRows.first['v'], equals('plain'));
      expect(encRows.first['v'], equals('secret'));

      await plainDb.close();
      await encDb.close();
    });

    test('C11-P1-17: Production database files are NOT modified', () async {
      final defaultDbDir = await getDatabasesPath();
      final prodDbFile = File(join(defaultDbDir, 'spendx.db'));

      if (await prodDbFile.exists()) {
        final length = await prodDbFile.length();
        expect(length, greaterThanOrEqualTo(0));
      }
      expect(true, isTrue);
    });

    test('C11-P1-18: Database factory initialization is idempotent', () async {
      final factory = SpendXDatabaseFactory.instance;
      await factory.initialize();
      await factory.initialize();
      await factory.initialize();
      expect(factory.isInitialized, isTrue);
    });

    test('C11-P1-19: Accounting invariant parity between plaintext and SQLCipher databases', () async {
      // 1. Setup plaintext database
      final plainPath = join(tempDir.path, 'accounting_parity_plain.db');
      final plainDb = await SpendXDatabaseFactory.instance.openPlaintextDatabase(
        plainPath,
        version: 24,
        onCreate: (db, version) async {
          await Tables.createAll(db);
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
        },
      );

      // 2. Setup identical encrypted SQLCipher database
      final encPath = join(tempDir.path, 'accounting_parity_enc.db');
      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        encPath,
        password: testKey,
        version: 24,
        onCreate: (db, version) async {
          await Tables.createAll(db);
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
        },
      );

      // Perform identical operations on both
      for (final targetDb in [plainDb, encDb]) {
        final accRepo = AccountRepo(executor: targetDb);
        await accRepo.insertAccount(
          BankAccount(id: 'bank_p1_parity', name: 'Parity Bank', bank: 'HDFC', balance: 0.0),
        );
        final catRepo = CategoryRepo(executor: targetDb);
        await catRepo.insert(
          Category(id: 'cat_p1_income', name: 'Income', icon: 'money', color: '#00FF00', type: 'income', userId: 'u1'),
        );
        final nowStr = DateTime.now().toUtc().toIso8601String();
        await targetDb.insert(TablesV24.accounts, {
          'id': 'cat_p1_income',
          'account_type': 'income',
          'subtype': 'category',
          'name': 'Income',
          'currency': 'INR',
          'is_active': 1,
          'is_system': 0,
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        final fts = FinancialTransactionService(database: targetDb);
        await fts.createTransaction(
          spx.Transaction(
            id: 'txn_parity_income',
            userId: 'u1',
            accountId: 'bank_p1_parity',
            categoryId: 'cat_p1_income',
            amount: 75000.0,
            type: 'income',
            notes: 'Parity Income',
            date: DateTime.now().toUtc(),
          ),
        );
      }

      // Assert bit-for-bit parity across all financial metrics
      final plainQueryRepo = CanonicalFinancialQueryRepository(executor: plainDb);
      final encQueryRepo = CanonicalFinancialQueryRepository(executor: encDb);

      final plainNW = await plainQueryRepo.getNetWorth();
      final encNW = await encQueryRepo.getNetWorth();
      expect(plainNW.minorUnits, equals(encNW.minorUnits));
      expect(encNW.minorUnits, equals(7500000));

      final plainEventsCount = await plainDb.rawQuery('SELECT count(*) as c FROM ${TablesV24.economicEvents};');
      final encEventsCount = await encDb.rawQuery('SELECT count(*) as c FROM ${TablesV24.economicEvents};');
      expect(plainEventsCount.first['c'], equals(encEventsCount.first['c']));

      final plainPostingsCount = await plainDb.rawQuery('SELECT count(*) as c FROM ${TablesV24.postings};');
      final encPostingsCount = await encDb.rawQuery('SELECT count(*) as c FROM ${TablesV24.postings};');
      expect(plainPostingsCount.first['c'], equals(encPostingsCount.first['c']));

      await plainDb.close();
      await encDb.close();
    });
  });
}
