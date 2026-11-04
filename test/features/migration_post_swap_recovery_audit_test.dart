import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/data/security/database_encryption_migration_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late InMemorySecureStorageAdapter mockStorage;
  late SpendXDatabaseKeyManager keyManager;
  late Uint8List masterKeyBytes;
  late String blobKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_post_swap_audit_');
    mockStorage = InMemorySecureStorageAdapter();
    keyManager = SpendXDatabaseKeyManager(storageAdapter: mockStorage);
    SpendXDatabaseKeyManager.setTestInstance(keyManager);
    await SpendXDatabaseFactory.instance.initialize();

    masterKeyBytes = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 11 + 37) % 256),
    );
    blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(masterKeyBytes);
    mockStorage.write(
      SpendXDatabaseKeyManager.defaultKeyStorageName,
      base64Encode(masterKeyBytes),
    );
  });

  tearDown(() async {
    SpendXDatabaseKeyManager.setTestInstance(null);
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  /// Helper to create a valid v24 plaintext SQLite database seeded with double-entry accounts.
  Future<String> createValidPlaintextDb({
    required String fileName,
    int initialBalanceMinorUnits = 7500000, // 75,000 INR
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

    // Seed checking account
    await db.insert('accounts', {
      'id': 'acc_audit_01',
      'account_type': 'asset',
      'subtype': 'checking',
      'name': 'Primary Checking',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final eventId = 'ev_audit_seed_01';
    final now = DateTime.now().toIso8601String();
    await db.insert('economic_events', {
      'id': eventId,
      'event_type': 'income',
      'lifecycle_status': 'draft',
      'timestamp': now,
      'currency': 'INR',
      'description': 'Opening Balance',
      'created_at': now,
      'updated_at': now,
    });

    await db.insert('postings', {
      'id': 'post_audit_01',
      'economic_event_id': eventId,
      'account_id': 'acc_audit_01',
      'sequence_number': 1,
      'direction': 'debit',
      'amount_minor_units': initialBalanceMinorUnits,
      'currency': 'INR',
      'created_at': now,
    });

    await db.insert('postings', {
      'id': 'post_audit_02',
      'economic_event_id': eventId,
      'account_id': TablesV24.sysIncMisc,
      'sequence_number': 2,
      'direction': 'credit',
      'amount_minor_units': initialBalanceMinorUnits,
      'currency': 'INR',
      'created_at': now,
    });

    await db.update(
      'economic_events',
      {'lifecycle_status': 'posted'},
      where: 'id = ?',
      whereArgs: [eventId],
    );

    await db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    await db.close();
    return dbPath;
  }

  group('Milestone 4.5B.1: Post-Swap Crash Recovery Audit', () {
    test('Scenario 1 — Crash after encrypted activation, before verified journal persistence', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario1_crash_post_swap.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final archivePath = join(dbDir, '$dbName.pre_encrypted_archive');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      // 1. Simulate complete migration up to atomic swap Step B + Checkpoint 8
      // Live database becomes valid SQLCipher, backup remains available
      final migrationService = DatabaseEncryptionMigrationService(
        keyManager: keyManager,
        factory: SpendXDatabaseFactory.instance,
      );
      final result = await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true, // backup preserved
      );
      expect(result.success, isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(bkpPath).existsSync(), isTrue);

      // 2. Synthesize process termination state:
      // Live database is SQLCipher, backup is present, archive is present, but journal is still 'swapping'
      await File(bkpPath).copy(archivePath);
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.swapping,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.swapping);
      expect(journal.state, equals(MigrationState.swapping));

      // 3. Instantiate a FRESH migration recovery service (simulating fresh process startup)
      final freshStorage = InMemorySecureStorageAdapter();
      freshStorage.write(
        SpendXDatabaseKeyManager.defaultKeyStorageName,
        base64Encode(masterKeyBytes),
      );
      final freshKeyManager = SpendXDatabaseKeyManager(storageAdapter: freshStorage);
      final freshRecoveryService = DatabaseEncryptionMigrationService(
        keyManager: freshKeyManager,
        factory: SpendXDatabaseFactory.instance,
      );

      // 4. Execute recovery on the fresh instance
      await freshRecoveryService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // VERIFICATIONS:
      // 1. Does recovery recognize the active encrypted database? -> YES, did not fail
      // 2. Does it preserve the encrypted database? -> YES, file is still encrypted SQLCipher
      expect(
        DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath),
        isFalse,
        reason: 'Active encrypted SQLCipher database was preserved',
      );

      // Verify that database is readable and financial data is intact
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );
      final rows = await db.rawQuery('SELECT count(*) as cnt FROM accounts;');
      expect((rows.first['cnt'] as int), equals(10)); // 9 system accounts + 1 user account
      final postRows = await db.rawQuery("SELECT sum(amount_minor_units) as s FROM postings WHERE direction = 'debit';");
      expect((postRows.first['s'] as int), equals(7500000));
      await db.close();

      // 3. Does it avoid restoring plaintext? -> YES, live DB is not plaintext
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);

      // 4. Does it retain the backup until validation is complete? -> Stale artifacts swept only after validation
      expect(File(archivePath).existsSync(), isFalse);
      expect(File(bkpPath).existsSync(), isFalse);

      // 5. Does it transition the journal into a safe recoverable state? -> YES, cleared
      expect(File(journalPath).existsSync(), isFalse);
    });

    test('Scenario 2 — Failure persisting verified state', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario2_journal_write_failure.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      // Migrate to encrypted, keeping backup
      final initialService = DatabaseEncryptionMigrationService(
        keyManager: keyManager,
        factory: SpendXDatabaseFactory.instance,
      );
      await initialService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(bkpPath).existsSync(), isTrue);

      // Simulate a failure persisting 'verified' state:
      // The state in the journal remained 'swapping' or became 'cleanupPending' with error
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.swapping,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.swapping, err: 'I/O failure persisting verified state');

      // Start fresh recovery service
      final freshStorage = InMemorySecureStorageAdapter();
      freshStorage.write(
        SpendXDatabaseKeyManager.defaultKeyStorageName,
        base64Encode(masterKeyBytes),
      );
      final freshKeyManager = SpendXDatabaseKeyManager(storageAdapter: freshStorage);
      final freshRecoveryService = DatabaseEncryptionMigrationService(
        keyManager: freshKeyManager,
        factory: SpendXDatabaseFactory.instance,
      );

      // Run recovery
      await freshRecoveryService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // VERIFICATIONS:
      // The live encrypted database must NOT be replaced by plaintext
      expect(
        DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath),
        isFalse,
        reason: 'Live encrypted database must not be replaced by plaintext',
      );
      expect(File(journalPath).existsSync(), isFalse);
      expect(File(bkpPath).existsSync(), isFalse);
    });

    test('Scenario 3 — Failure persisting cleanupPending', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario3_cleanup_pending_failure.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      // Migrate to SQLCipher
      final initialService = DatabaseEncryptionMigrationService(
        keyManager: keyManager,
        factory: SpendXDatabaseFactory.instance,
      );
      await initialService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true, // backup retained on disk
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(bkpPath).existsSync(), isTrue);

      // Simulate failure to persist cleanupPending:
      // The journal still contains state = verified (because writing cleanupPending failed)
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.verified,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.verified, err: 'I/O error updating cleanupPending');

      // VERIFICATIONS BEFORE RECOVERY:
      // - The encrypted database remains active
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      // - The plaintext backup is not prematurely deleted
      expect(File(bkpPath).existsSync(), isTrue);

      // A subsequent startup initiates fresh recovery:
      final freshStorage = InMemorySecureStorageAdapter();
      freshStorage.write(
        SpendXDatabaseKeyManager.defaultKeyStorageName,
        base64Encode(masterKeyBytes),
      );
      final freshKeyManager = SpendXDatabaseKeyManager(storageAdapter: freshStorage);
      final freshRecoveryService = DatabaseEncryptionMigrationService(
        keyManager: freshKeyManager,
        factory: SpendXDatabaseFactory.instance,
      );

      // Execute startup recovery
      await freshRecoveryService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // VERIFICATIONS AFTER RECOVERY:
      // - No rollback to plaintext occurs
      expect(
        DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath),
        isFalse,
        reason: 'No rollback to plaintext occurs during recovery from failed cleanupPending',
      );
      // - Stale backup is cleanly swept
      expect(File(bkpPath).existsSync(), isFalse);
      // - Journal is cleared
      expect(File(journalPath).existsSync(), isFalse);
    });

    test('Scenario 4 — Corrupt active database with backup present fails explicitly and never deletes backup', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario4_corrupt_active_db.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      // Migrate to SQLCipher
      final initialService = DatabaseEncryptionMigrationService(
        keyManager: keyManager,
        factory: SpendXDatabaseFactory.instance,
      );
      await initialService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true, // keep backup
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(bkpPath).existsSync(), isTrue);

      // Corrupt the active database file (e.g. storage media block corruption)
      final corruptData = Uint8List(8192)..fillRange(0, 8192, 0xEF);
      await File(dbPath).writeAsBytes(corruptData);

      // Journal records verified / cleanupPending
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.cleanupPending,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.cleanupPending);

      // Instantiate fresh recovery instance
      final freshStorage = InMemorySecureStorageAdapter();
      freshStorage.write(
        SpendXDatabaseKeyManager.defaultKeyStorageName,
        base64Encode(masterKeyBytes),
      );
      final freshKeyManager = SpendXDatabaseKeyManager(storageAdapter: freshStorage);
      final freshRecoveryService = DatabaseEncryptionMigrationService(
        keyManager: freshKeyManager,
        factory: SpendXDatabaseFactory.instance,
      );

      // VERIFICATIONS:
      // 1. Recovery fails explicitly and safely by throwing MigrationCrashRecoveryException
      await expectLater(
        freshRecoveryService.recoverInterruptedMigration(
          dbPath: dbPath,
          keyOverride: masterKeyBytes,
        ),
        throwsA(isA<MigrationCrashRecoveryException>()),
      );

      // 2. Recovery does NOT silently restore plaintext
      expect(
        DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath),
        isFalse,
        reason: 'Corrupted database was NOT replaced by unencrypted plaintext',
      );

      // 3. Recovery preserves available recovery artifacts and does NOT delete the only recoverable copy
      expect(
        File(bkpPath).existsSync(),
        isTrue,
        reason: 'Plaintext backup is preserved for forensic / manual data recovery',
      );
      expect(
        DatabaseEncryptionMigrationService.isPlaintextSqliteFile(bkpPath),
        isTrue,
      );
    });
  });
}
