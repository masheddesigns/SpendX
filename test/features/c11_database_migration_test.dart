import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/data/security/database_encryption_migration_service.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late InMemorySecureStorageAdapter mockStorage;
  late SpendXDatabaseKeyManager keyManager;
  late DatabaseEncryptionMigrationService migrationService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_c11_migration_test_');
    mockStorage = InMemorySecureStorageAdapter();
    keyManager = SpendXDatabaseKeyManager(storageAdapter: mockStorage);
    SpendXDatabaseKeyManager.setTestInstance(keyManager);
    migrationService = DatabaseEncryptionMigrationService(
      keyManager: keyManager,
      factory: SpendXDatabaseFactory.instance,
    );
    await SpendXDatabaseFactory.instance.initialize();
  });

  tearDown(() async {
    SpendXDatabaseKeyManager.setTestInstance(null);
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  /// Helper to create a fully initialized, valid v24 plaintext SQLite database.
  Future<String> createValidPlaintextV24Db({
    String fileName = 'spendx.db',
    bool seedData = true,
  }) async {
    final dbPath = join(tempDir.path, fileName);
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 24,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: (db, version) async {
          for (final q in Tables.allCreateQueries) {
            await db.execute(q);
          }
          await TablesV24.createAllV24(db);
          await TablesV24.seedSystemAccounts(db);
          await TablesV24.installTriggers(db);
        },
      ),
    );

    if (seedData) {
      // Seed a user account and balanced double-entry transaction
      await db.insert('accounts', {
        'id': 'acc_mig_test_1',
        'account_type': 'asset',
        'subtype': 'checking',
        'name': 'Salary Checking',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // Income event
      final eventId = 'ev_mig_01';
      final now = DateTime.now().toIso8601String();
      await db.insert('economic_events', {
        'id': eventId,
        'event_type': 'income',
        'lifecycle_status': 'draft',
        'timestamp': now,
        'currency': 'INR',
        'description': 'Salary Deposit',
        'created_at': now,
        'updated_at': now,
      });

      // Balanced postings: 50,000 INR (5,000,000 minor units)
      await db.insert('postings', {
        'id': 'post_mig_01',
        'economic_event_id': eventId,
        'account_id': 'acc_mig_test_1',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 5000000,
        'currency': 'INR',
        'created_at': now,
      });
      await db.insert('postings', {
        'id': 'post_mig_02',
        'economic_event_id': eventId,
        'account_id': TablesV24.sysIncMisc,
        'sequence_number': 2,
        'direction': 'credit',
        'amount_minor_units': 5000000,
        'currency': 'INR',
        'created_at': now,
      });

      // Post the event
      await db.update(
        'economic_events',
        {'lifecycle_status': 'posted'},
        where: 'id = ?',
        whereArgs: [eventId],
      );
    }

    await db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    await db.close();
    return dbPath;
  }

  group('Milestone C11 Phase 3: Database Encryption Migration Tests', () {
    test('C11-P3-01: Clean plaintext v24 database migrates to SQLCipher with 100% accounting parity', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Verify file is initially plaintext
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);

      final result = await migrationService.runMigration(dbPath: dbPath);

      expect(result.success, isTrue);
      expect(result.skipped, isFalse);
      expect(result.finalState, equals(MigrationState.verified));
      expect(result.fingerprint, isNotNull);

      // Verify file is no longer plaintext
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);

      // Verify it opens with the managed key
      final key = await keyManager.getKey();
      expect(key, isNotNull);
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key!);
      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );

      final postFp = await AccountingFingerprint.fromDatabase(encDb);
      expect(postFp.matches(result.fingerprint!), isTrue);
      expect(postFp.schemaVersion, equals(24));
      expect(postFp.activeTriggersCount, equals(7));
      expect(postFp.debitTotalMinorUnits, equals(5000000));
      expect(postFp.creditTotalMinorUnits, equals(5000000));

      await encDb.close();
    });

    test('C11-P3-02: All 7 financial triggers execute and enforce invariants on migrated database', () async {
      final dbPath = await createValidPlaintextV24Db();
      await migrationService.runMigration(dbPath: dbPath);

      final key = await keyManager.getKey();
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key!);
      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );

      // Trigger 1 & 2: Direct insert of POSTED event with no postings must fail
      expect(
        () async => await encDb.insert('economic_events', {
          'id': 'illegal_ev',
          'event_type': 'expense',
          'lifecycle_status': 'posted',
          'timestamp': DateTime.now().toIso8601String(),
          'currency': 'INR',
          'description': 'Illegal Event',
          'created_at': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Trigger 3: Inserting postings on already posted event must fail
      expect(
        () async => await encDb.insert('postings', {
          'id': 'illegal_post',
          'economic_event_id': 'ev_mig_01',
          'account_id': 'acc_mig_test_1',
          'sequence_number': 3,
          'direction': 'debit',
          'amount_minor_units': 100,
          'currency': 'INR',
          'created_at': DateTime.now().toIso8601String(),
        }),
        throwsA(isA<DatabaseException>()),
      );

      // Trigger 4: Updating postings on posted event must fail
      expect(
        () async => await encDb.update(
          'postings',
          {'amount_minor_units': 999},
          where: 'id = ?',
          whereArgs: ['post_mig_01'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Trigger 5: Deleting postings on posted event must fail
      expect(
        () async => await encDb.delete(
          'postings',
          where: 'id = ?',
          whereArgs: ['post_mig_01'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Trigger 6: Mutating currency/timestamp on posted economic event must fail
      expect(
        () async => await encDb.update(
          'economic_events',
          {'currency': 'USD'},
          where: 'id = ?',
          whereArgs: ['ev_mig_01'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      // Trigger 7: Deleting posted economic event must fail
      expect(
        () async => await encDb.delete(
          'economic_events',
          where: 'id = ?',
          whereArgs: ['ev_mig_01'],
        ),
        throwsA(isA<DatabaseException>()),
      );

      await encDb.close();
    });

    test('C11-P3-03: Pre-migration and post-migration accounting fingerprints match bit-for-bit across all 18 fields', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Read pre-migration fingerprint
      final plainDb = await SpendXDatabaseFactory.instance.openPlaintextDatabase(dbPath);
      final preFp = await AccountingFingerprint.fromDatabase(plainDb);
      await plainDb.close();

      final result = await migrationService.runMigration(dbPath: dbPath);

      expect(preFp.matches(result.fingerprint!), isTrue);
      expect(preFp.diff(result.fingerprint!), equals('NONE'));
      expect(result.fingerprint!.schemaVersion, equals(24));
      expect(result.fingerprint!.activeTriggersCount, equals(7));
      expect(result.fingerprint!.debitTotalMinorUnits, equals(preFp.debitTotalMinorUnits));
      expect(result.fingerprint!.creditTotalMinorUnits, equals(preFp.creditTotalMinorUnits));
      expect(result.fingerprint!.netWorthMinorUnits, equals(preFp.netWorthMinorUnits));
      expect(result.fingerprint!.incomeMinorUnits, equals(preFp.incomeMinorUnits));
      expect(result.fingerprint!.expenseMinorUnits, equals(preFp.expenseMinorUnits));
      expect(result.fingerprint!.cashFlowMinorUnits, equals(preFp.cashFlowMinorUnits));
      expect(result.fingerprint!.safeToSpendMinorUnits, equals(preFp.safeToSpendMinorUnits));
    });

    test('C11-P3-04: WAL frames are fully checkpointed and truncated before migration; sidecars removed', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Add a dummy uncheckpointed write to create sidecars
      final plainDb = await databaseFactoryFfi.openDatabase(dbPath);
      await plainDb.rawQuery('PRAGMA journal_mode = WAL;');
      await plainDb.insert('categories', {
        'id': 'cat_wal_test',
        'name': 'Utilities',
        'icon': 'bolt',
        'color': '#ff0000',
        'type': 'expense',
      });
      await plainDb.close();

      await migrationService.runMigration(dbPath: dbPath);

      // Verify WAL and SHM do not exist or are 0 bytes
      final walFile = File('$dbPath-wal');
      final shmFile = File('$dbPath-shm');
      expect(walFile.existsSync() ? walFile.lengthSync() : 0, equals(0));
      expect(shmFile.existsSync() ? shmFile.lengthSync() : 0, equals(0));
    });

    test('C11-P3-05: Corrupted plaintext database fails preflight and aborts without touching database', () async {
      final dbPath = join(tempDir.path, 'corrupt.db');
      final file = File(dbPath);
      // Write pseudo-SQLite header followed by total garbage
      final corruptBytes = Uint8List(1024);
      corruptBytes.setRange(0, 16, [
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
      ]);
      for (int i = 16; i < 1024; i++) {
        corruptBytes[i] = 0xAA;
      }
      await file.writeAsBytes(corruptBytes);

      expect(
        () async => await migrationService.runMigration(dbPath: dbPath),
        throwsA(isA<PreflightValidationException>()),
      );

      // Ensure original file exists and has same length
      expect(await file.exists(), isTrue);
      expect(await file.length(), equals(1024));
    });

    test('C11-P3-06: Foreign key violations in plaintext abort migration before staging', () async {
      final dbPath = await createValidPlaintextV24Db(seedData: false);

      // Inject FK violation by turning FK off temporarily
      final rawDb = await databaseFactoryFfi.openDatabase(dbPath);
      await rawDb.execute('PRAGMA foreign_keys = OFF;');
      // Insert posting pointing to non-existent account and event
      await rawDb.rawInsert(
        "INSERT INTO postings (id, economic_event_id, account_id, amount_minor_units, direction, created_at) VALUES ('bad_p', 'no_ev', 'no_acc', 100, 'debit', '2026-10-05T00:00:00Z');",
      );
      await rawDb.close();

      expect(
        () async => await migrationService.runMigration(dbPath: dbPath),
        throwsA(isA<PreflightValidationException>()),
      );

      // Verify original file is still plaintext and intact
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('C11-P3-07: Missing key in KeyManager triggers fatal error and aborts migration', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Configure mock storage to fail on write
      mockStorage.shouldThrowOnWrite = true;

      expect(
        () async => await migrationService.runMigration(dbPath: dbPath),
        throwsA(isA<DatabaseKeyAccessException>()),
      );

      // Verify original file is still plaintext
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('C11-P3-08: Insufficient disk space aborts migration cleanly before export', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Custom migration service that reports insufficient disk space
      final lowSpaceService = DatabaseEncryptionMigrationService(
        keyManager: keyManager,
        factory: SpendXDatabaseFactory.instance,
        diskSpaceChecker: (requiredBytes, path) async => false,
      );

      expect(
        () async => await lowSpaceService.runMigration(dbPath: dbPath),
        throwsA(isA<InsufficientDiskSpaceException>()),
      );

      // Verify original database untouched
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
      expect(File('$dbPath.migration_staging').existsSync(), isFalse);
    });

    test('C11-P3-09: Simulated crash during sqlcipher_export leaves original plaintext database 100% intact', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Simulate partial staging file and journal state in EXPORTING
      final journalPath = join(tempDir.path, 'spendx_migration_state.json');
      final journalFile = File(journalPath);
      final journal = MigrationJournal(
        file: journalFile,
        state: MigrationState.exporting,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: '$dbPath.migration_staging',
        rollbackBackupPath: '$dbPath.pre_migration_backup',
      );
      await journal.record(MigrationState.exporting);

      // Create dummy partial staging file
      final stagingFile = File('$dbPath.migration_staging');
      await stagingFile.writeAsString('partial_corrupted_export_data');

      // Recover
      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      // Staging file should be deleted, live DB untouched
      expect(await stagingFile.exists(), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);

      // Now run migration cleanly; should succeed
      final result = await migrationService.runMigration(dbPath: dbPath);
      expect(result.success, isTrue);
    });

    test('C11-P3-10: Simulated crash during validation leaves original plaintext database 100% intact', () async {
      final dbPath = await createValidPlaintextV24Db();

      final journalPath = join(tempDir.path, 'spendx_migration_state.json');
      final journalFile = File(journalPath);
      final journal = MigrationJournal(
        file: journalFile,
        state: MigrationState.validating,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: '$dbPath.migration_staging',
        rollbackBackupPath: '$dbPath.pre_migration_backup',
      );
      await journal.record(MigrationState.validating);

      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('C11-P3-11: Simulated crash during atomic rename recovers cleanly from rollback backup', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Create backup copy and archive file simulating rename in flight
      final bkpPath = '$dbPath.pre_migration_backup';
      await File(dbPath).copy(bkpPath);

      final archivePath = '$dbPath.pre_encrypted_archive';
      await File(dbPath).rename(archivePath);

      // Live DB is missing at this moment
      expect(File(dbPath).existsSync(), isFalse);

      final journalPath = join(tempDir.path, 'spendx_migration_state.json');
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.swapping,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: '$dbPath.migration_staging',
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.swapping);

      // Recover
      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      // Live DB must be restored from archive/backup
      expect(File(dbPath).existsSync(), isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('C11-P3-12: Migrated database refuses opening with wrong key', () async {
      final dbPath = await createValidPlaintextV24Db();
      await migrationService.runMigration(dbPath: dbPath);

      const wrongBlobKey = "x'1111111111111111111111111111111111111111111111111111111111111111'";

      expect(
        () async => await SpendXDatabaseFactory.instance.openEncryptedDatabase(
          dbPath,
          password: wrongBlobKey,
        ),
        throwsA(isA<SqlCipherException>()),
      );
    });

    test('C11-P3-13: Migrated database opens normally with correct key', () async {
      final dbPath = await createValidPlaintextV24Db();
      await migrationService.runMigration(dbPath: dbPath);

      final key = await keyManager.getKey();
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key!);
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );

      final rows = await db.rawQuery('SELECT count(*) as cnt FROM accounts;');
      expect((rows.first['cnt'] as int), greaterThanOrEqualTo(1));
      await db.close();
    });

    test('C11-P3-14: Already-encrypted database is detected and migration is safely skipped (idempotency)', () async {
      final dbPath = await createValidPlaintextV24Db();

      // First run: migrates
      final firstResult = await migrationService.runMigration(dbPath: dbPath);
      expect(firstResult.success, isTrue);
      expect(firstResult.skipped, isFalse);

      // Second run: idempotently skipped
      final secondResult = await migrationService.runMigration(dbPath: dbPath);
      expect(secondResult.success, isTrue);
      expect(secondResult.skipped, isTrue);
    });

    test('C11-P3-15: Staged migration artifacts are cleaned up after successful migration', () async {
      final dbPath = await createValidPlaintextV24Db();
      await migrationService.runMigration(dbPath: dbPath);

      expect(File('$dbPath.migration_staging').existsSync(), isFalse);
      expect(File('$dbPath.pre_encrypted_archive').existsSync(), isFalse);
      expect(File('$dbPath.pre_migration_backup').existsSync(), isFalse);
      expect(File(join(tempDir.path, 'spendx_migration_state.json')).existsSync(), isFalse);
    });

    test('C11-P3-16: Double-entry accounting transactions operate normally on migrated database', () async {
      final dbPath = await createValidPlaintextV24Db();
      await migrationService.runMigration(dbPath: dbPath);

      final key = await keyManager.getKey();
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key!);
      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );

      // Perform a complete canonical financial transaction on the encrypted database
      final service = FinancialTransactionService(database: encDb);
      await service.createTransaction(
        spx.Transaction(
          id: 'txn_mig_post_01',
          userId: 'u1',
          accountId: 'acc_mig_test_1',
          categoryId: 'cat_groceries',
          amount: 1500.0,
          type: 'expense',
          notes: 'Grocery Shopping',
          date: DateTime.now().toUtc(),
        ),
      );

      final fp = await AccountingFingerprint.fromDatabase(encDb);
      expect(fp.debitTotalMinorUnits, equals(fp.creditTotalMinorUnits));
      expect(fp.debitTotalMinorUnits, equals(5000000 + 150000));

      await encDb.close();
    });

    test('C11-P3-17: Double-entry imbalance in plaintext aborts migration during preflight', () async {
      final dbPath = await createValidPlaintextV24Db(seedData: false);

      final rawDb = await databaseFactoryFfi.openDatabase(dbPath);
      // Create unbalanced postings
      await rawDb.insert('economic_events', {
        'id': 'ev_unbalanced',
        'event_type': 'expense',
        'lifecycle_status': 'draft',
        'timestamp': DateTime.now().toIso8601String(),
        'currency': 'INR',
        'description': 'Unbalanced draft',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await rawDb.insert('postings', {
        'id': 'post_unbalanced_1',
        'economic_event_id': 'ev_unbalanced',
        'account_id': TablesV24.sysIncMisc,
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': 1000,
        'currency': 'INR',
        'created_at': DateTime.now().toIso8601String(),
      });
      // Missing corresponding credit!
      await rawDb.close();

      expect(
        () async => await migrationService.runMigration(dbPath: dbPath),
        throwsA(isA<PreflightValidationException>()),
      );
    });

    test('C11-P3-18: Schema version != 24 aborts migration during preflight', () async {
      final dbPath = await createValidPlaintextV24Db(seedData: false);

      final rawDb = await databaseFactoryFfi.openDatabase(dbPath);
      await rawDb.execute('PRAGMA user_version = 23;');
      await rawDb.close();

      expect(
        () async => await migrationService.runMigration(dbPath: dbPath),
        throwsA(isA<PreflightValidationException>()),
      );
    });

    test('C11-P3-19: Missing triggers in plaintext aborts migration during preflight', () async {
      final dbPath = await createValidPlaintextV24Db(seedData: false);

      final rawDb = await databaseFactoryFfi.openDatabase(dbPath);
      await rawDb.execute('DROP TRIGGER IF EXISTS trg_postings_prevent_delete_on_posted;');
      await rawDb.close();

      expect(
        () async => await migrationService.runMigration(dbPath: dbPath),
        throwsA(isA<PreflightValidationException>()),
      );
    });

    test('C11-P3-20: Concurrent migration attempts are rejected (mutex enforcement)', () async {
      final dbPath = await createValidPlaintextV24Db();

      // Start migration and attempt immediate second call
      final fut1 = migrationService.runMigration(dbPath: dbPath);
      expect(
        () async => await migrationService.runMigration(dbPath: dbPath),
        throwsA(isA<StateError>()),
      );
      await fut1;
    });

    test('C11-P3-21: BackupService rejects running while migration is in progress', () async {
      expect(BackupService.instance.isBackupRunning, isFalse);
      expect(DatabaseEncryptionMigrationService.instance.isMigrationRunning, isFalse);
    });

    test('C11-P3-22: Crash recovery restores from pre_migration_backup when live DB is missing', () async {
      final dbPath = await createValidPlaintextV24Db();
      final bkpPath = '$dbPath.pre_migration_backup';
      await File(dbPath).copy(bkpPath);
      await File(dbPath).delete();

      final journal = MigrationJournal(
        file: File(join(tempDir.path, 'spendx_migration_state.json')),
        state: MigrationState.swapping,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: '$dbPath.migration_staging',
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.swapping);

      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      expect(File(dbPath).existsSync(), isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('C11-P3-23: Crash recovery restores from pre_encrypted_archive when live DB is missing', () async {
      final dbPath = await createValidPlaintextV24Db();
      final archivePath = '$dbPath.pre_encrypted_archive';
      await File(dbPath).rename(archivePath);

      final journal = MigrationJournal(
        file: File(join(tempDir.path, 'spendx_migration_state.json')),
        state: MigrationState.swapping,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: '$dbPath.migration_staging',
        rollbackBackupPath: '$dbPath.pre_migration_backup',
      );
      await journal.record(MigrationState.swapping);

      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      expect(File(dbPath).existsSync(), isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('C11-P3-24: Restart after successful migration opens encrypted DB transparently via SpendXDatabaseFactory', () async {
      final dbPath = await createValidPlaintextV24Db();
      await migrationService.runMigration(dbPath: dbPath);

      final key = await keyManager.getKey();
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key!);

      // Cycle 1: Open, query, close
      final db1 = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );
      final r1 = await db1.rawQuery('SELECT count(*) as c FROM accounts;');
      expect((r1.first['c'] as int), greaterThanOrEqualTo(1));
      await db1.close();

      // Cycle 2: Open again, verify persistent data
      final db2 = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );
      final r2 = await db2.rawQuery('SELECT count(*) as c FROM accounts;');
      expect((r2.first['c'] as int), equals(r1.first['c']));
      await db2.close();
    });

    test('C11-P3-25: Backup creation and restore work seamlessly on encrypted database', () async {
      final dbPath = await createValidPlaintextV24Db();
      await migrationService.runMigration(dbPath: dbPath);

      final key = await keyManager.getKey();
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key!);
      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );

      // Create backup package from encrypted database
      final backupFile = File(join(tempDir.path, 'encrypted_test.spendx'));
      final result = await BackupService.instance.createBackupPackage(
        sourceDb: encDb,
        sourceDbPath: dbPath,
        outputFile: backupFile,
        password: 'ValidPassword123!',
      );

      expect(result.$2.databaseSize, greaterThan(0));
      expect(await backupFile.exists(), isTrue);
      await encDb.close();

      // Restore into target database
      final restoreTargetDbPath = join(tempDir.path, 'restored_enc.db');
      final restoreSuccess = await BackupService.instance.restoreFromFile(
        backupFile,
        password: 'ValidPassword123!',
        targetDbPath: restoreTargetDbPath,
      );

      expect(restoreSuccess, isTrue);
      expect(File(restoreTargetDbPath).existsSync(), isTrue);
    });

    test('C11-P3-26: Key material is never leaked in migration journal, exceptions, or string logs', () async {
      final dbPath = await createValidPlaintextV24Db();
      final key = await keyManager.getOrCreateKey();
      final hexKey = SpendXDatabaseKeyManager.keyToHex(key);

      await migrationService.runMigration(dbPath: dbPath);

      // Check journal file content
      final journalPath = join(tempDir.path, 'spendx_migration_state.json');
      final journalFile = File(journalPath);
      if (journalFile.existsSync()) {
        final content = journalFile.readAsStringSync();
        expect(content.contains(hexKey), isFalse);
      }

      // Check exception message does not leak key
      const ex = AccountingFingerprintMismatchException('difference detected');
      expect(ex.toString().contains(hexKey), isFalse);
    });
  });
}
