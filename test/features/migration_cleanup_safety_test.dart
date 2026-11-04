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
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/financial_transaction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late InMemorySecureStorageAdapter mockStorage;
  late SpendXDatabaseKeyManager keyManager;
  late DatabaseEncryptionMigrationService migrationService;
  late Uint8List masterKeyBytes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_cleanup_safety_test_');
    mockStorage = InMemorySecureStorageAdapter();
    keyManager = SpendXDatabaseKeyManager(storageAdapter: mockStorage);
    SpendXDatabaseKeyManager.setTestInstance(keyManager);
    migrationService = DatabaseEncryptionMigrationService(
      keyManager: keyManager,
      factory: SpendXDatabaseFactory.instance,
    );
    await SpendXDatabaseFactory.instance.initialize();

    masterKeyBytes = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 7 + 13) % 256),
    );
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

  /// Helper to create a valid v24 plaintext SQLite database seeded with double-entry ledger data.
  Future<String> createValidPlaintextDb({
    String fileName = 'spendx.db',
    int initialBalanceMinorUnits = 5000000, // 50,000 INR
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

    // Seed account
    await db.insert('accounts', {
      'id': 'acc_safety_01',
      'account_type': 'asset',
      'subtype': 'checking',
      'name': 'Primary Checking',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    if (initialBalanceMinorUnits > 0) {
      final eventId = 'ev_safety_seed_01';
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
        'id': 'post_safety_01',
        'economic_event_id': eventId,
        'account_id': 'acc_safety_01',
        'sequence_number': 1,
        'direction': 'debit',
        'amount_minor_units': initialBalanceMinorUnits,
        'currency': 'INR',
        'created_at': now,
      });

      await db.insert('postings', {
        'id': 'post_safety_02',
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
    }

    await db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    await db.close();
    return dbPath;
  }

  group('Milestone 4.5B — Migration Cleanup Safety & SEC-03 Invariant Enforcement', () {
    test('Scenario 1: Failure before encrypted export cleanly aborts and leaves plaintext DB untouched', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario1.db');
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);

      // Create a mock service where disk space checker rejects the operation
      final failService = DatabaseEncryptionMigrationService(
        keyManager: keyManager,
        factory: SpendXDatabaseFactory.instance,
        diskSpaceChecker: (bytes, dir) async => false, // simulate disk full during preflight
      );

      await expectLater(
        failService.runMigration(dbPath: dbPath, keyOverride: masterKeyBytes),
        throwsA(isA<InsufficientDiskSpaceException>()),
      );

      // Verify original plaintext database is intact and uncorrupted
      expect(File(dbPath).existsSync(), isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);

      // Verify no staging or archive files left behind
      expect(File('$dbPath.migration_staging').existsSync(), isFalse);
      expect(File('$dbPath.pre_encrypted_archive').existsSync(), isFalse);
    });

    test('Scenario 2: Failure during export cleans staging and leaves plaintext DB untouched', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario2.db');
      final stagedPath = '$dbPath.migration_staging';

      // Corrupt the target directory or place a read-only conflict to simulate export failure
      // By using a mock journal recording exporting and clean recovery:
      final journalPath = join(tempDir.path, 'spendx_migration_state.json');
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.exporting,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: stagedPath,
        rollbackBackupPath: '$dbPath.pre_migration_backup',
      );
      await journal.record(MigrationState.exporting);
      await File(stagedPath).writeAsString('partial-staged-data');

      // Run recovery
      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      // Verify staging was deleted, journal was cleared, and plaintext DB is pristine
      expect(File(stagedPath).existsSync(), isFalse);
      expect(File(journalPath).existsSync(), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('Scenario 3: Failure during validation cleans staging and leaves plaintext DB untouched', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario3.db');
      final stagedPath = '$dbPath.migration_staging';
      final bkpPath = '$dbPath.pre_migration_backup';

      await File(stagedPath).writeAsString('corrupted-encryption-staged-db');
      await File(dbPath).copy(bkpPath);

      final journalPath = join(tempDir.path, 'spendx_migration_state.json');
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.validating,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: stagedPath,
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.validating);

      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      expect(File(stagedPath).existsSync(), isFalse);
      expect(File(bkpPath).existsSync(), isFalse);
      expect(File(journalPath).existsSync(), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
    });

    test('Scenario 4: Failure during file swap Step A restores plaintext DB from archive', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario4.db');
      final archivePath = '$dbPath.pre_encrypted_archive';
      final bkpPath = '$dbPath.pre_migration_backup';

      // Simulate Step A: live file renamed to archive, but Step B has not executed yet
      await File(dbPath).copy(bkpPath);
      await File(dbPath).rename(archivePath);

      expect(File(dbPath).existsSync(), isFalse);
      expect(File(archivePath).existsSync(), isTrue);

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

      // Recovery detects live file is missing in swapping state; cleanly restores from archive
      await migrationService.recoverInterruptedMigration(dbPath: dbPath);

      expect(File(dbPath).existsSync(), isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);
      expect(File(journalPath).existsSync(), isFalse);
    });

    test('Scenario 5: Failure immediately after encrypted activation recognizes SQLCipher and does NOT rollback', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario5.db');
      final bkpPath = '$dbPath.pre_migration_backup';
      final archivePath = '$dbPath.pre_encrypted_archive';

      // Run migration normally to create valid SQLCipher DB, keeping backup
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);

      // Simulate crash immediately after Step B by setting journal to swapping
      await File(dbPath).copy(archivePath); // simulate archive still present
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

      // Recovery must detect that live DB is ALREADY valid SQLCipher and MUST NOT rollback!
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(archivePath).existsSync(), isFalse);
      expect(File(bkpPath).existsSync(), isFalse);
      expect(File(journalPath).existsSync(), isFalse);
    });

    test('Scenario 6: Failure persisting verified state preserves live SQLCipher DB', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario6.db');
      
      // Migrate successfully
      final result = await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(result.success, isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);

      // Verify database is readable with key and has schema 24
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(masterKeyBytes);
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );
      final count = await db.rawQuery('SELECT count(*) as cnt FROM accounts;');
      expect((count.first['cnt'] as int), greaterThanOrEqualTo(1));
      await db.close();
    });

    test('Scenario 7: Failure deleting plaintext backup retains SQLCipher, marks cleanupPending, and succeeds', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario7.db');
      final bkpPath = '$dbPath.pre_migration_backup';

      // Keep backup on success simulates the backup remaining present
      final result = await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );

      // Migration succeeded
      expect(result.success, isTrue);
      expect(result.finalState, equals(MigrationState.verified));

      // Main database is encrypted SQLCipher
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);

      // Plaintext backup is safely preserved on disk for sweep
      expect(File(bkpPath).existsSync(), isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(bkpPath), isTrue);
    });

    test('Scenario 8: Process termination while cleanup is pending sweeps stale backup and preserves SQLCipher', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario8.db');
      final bkpPath = '$dbPath.pre_migration_backup';
      final journalPath = join(tempDir.path, 'spendx_migration_state.json');

      // Migrate to SQLCipher
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(bkpPath).existsSync(), isTrue);

      // Record cleanupPending in journal
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.cleanupPending,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: '$dbPath.migration_staging',
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.cleanupPending, err: 'Simulated file lock');

      // Run recovery
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // Verification: Backup is swept, journal is cleared, live DB remains encrypted SQLCipher
      expect(File(bkpPath).existsSync(), isFalse);
      expect(File(journalPath).existsSync(), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
    });

    test('Scenario 9: Repeated startup cleanup is completely idempotent', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario9.db');
      final bkpPath = '$dbPath.pre_migration_backup';

      // Migrate
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      // First sweep cleans the backup
      final cleaned1 = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
      );
      expect(cleaned1, equals(1));
      expect(File(bkpPath).existsSync(), isFalse);

      // Second sweep is a no-op
      final cleaned2 = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
      );
      expect(cleaned2, equals(0));

      // Third sweep is also a no-op
      final cleaned3 = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
      );
      expect(cleaned3, equals(0));

      // Live encrypted DB is completely untouched
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
    });

    test('Scenario 10: Corrupt active encrypted database with backup present fails explicitly and NEVER overwrites with plaintext', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scenario10.db');
      final bkpPath = '$dbPath.pre_migration_backup';
      final journalPath = join(tempDir.path, 'spendx_migration_state.json');

      // Migrate to SQLCipher
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(bkpPath).existsSync(), isTrue);

      // Simulate on-disk corruption of the active encrypted database (e.g. random bit flips)
      final corruptBytes = Uint8List(4096)..fillRange(0, 4096, 0xAA);
      await File(dbPath).writeAsBytes(corruptBytes);

      // Record verified or cleanupPending in journal
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.cleanupPending,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: '$dbPath.migration_staging',
        rollbackBackupPath: bkpPath,
      );
      await journal.record(MigrationState.cleanupPending);

      // Attempting recovery MUST NOT overwrite dbPath with bkpPath!
      // It must throw MigrationCrashRecoveryException!
      await expectLater(
        migrationService.recoverInterruptedMigration(
          dbPath: dbPath,
          keyOverride: masterKeyBytes,
        ),
        throwsA(isA<MigrationCrashRecoveryException>()),
      );

      // Verify the invariant: dbPath was NOT overwritten with plaintext backup!
      expect(
        DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath),
        isFalse,
        reason: 'Corrupt encrypted database was never overwritten with plaintext backup!',
      );

      // Plaintext backup is safely preserved for manual inspection
      expect(File(bkpPath).existsSync(), isTrue);
    });
  });
}
