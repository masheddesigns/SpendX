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
  late DatabaseEncryptionMigrationService migrationService;
  late Uint8List masterKeyBytes;
  late String blobKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_retention_test_');
    mockStorage = InMemorySecureStorageAdapter();
    keyManager = SpendXDatabaseKeyManager(storageAdapter: mockStorage);
    SpendXDatabaseKeyManager.setTestInstance(keyManager);
    migrationService = DatabaseEncryptionMigrationService(
      keyManager: keyManager,
      factory: SpendXDatabaseFactory.instance,
    );
    await SpendXDatabaseFactory.instance.initialize();

    masterKeyBytes = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 17 + 53) % 256),
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
    int initialBalanceMinorUnits = 6000000,
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

    await db.insert('accounts', {
      'id': 'acc_retention_01',
      'account_type': 'asset',
      'subtype': 'checking',
      'name': 'Checking Retention',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final eventId = 'ev_retention_seed';
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
      'id': 'post_retention_01',
      'economic_event_id': eventId,
      'account_id': 'acc_retention_01',
      'sequence_number': 1,
      'direction': 'debit',
      'amount_minor_units': initialBalanceMinorUnits,
      'currency': 'INR',
      'created_at': now,
    });

    await db.insert('postings', {
      'id': 'post_retention_02',
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

  group('Milestone 4.5B.5: Recovery Backup Retention Tests', () {
    test('Scenario 1: keepBackupOnSuccess: true survives crash followed by verified recovery', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scen1_verified.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      // Migrate to SQLCipher with keepBackupOnSuccess: true
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(bkpPath).existsSync(), isTrue);

      // Synthesize crash right after verified state recorded
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.verified,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
        keepBackupOnSuccess: true,
      );
      await journal.record(MigrationState.verified);

      // Perform recovery
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // Verification: live encrypted DB active, journal cleared, safety backup PRESERVED!
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
      expect(File(journalPath).existsSync(), isFalse);
      expect(File(bkpPath).existsSync(), isTrue, reason: 'Backup must be preserved when keepBackupOnSuccess: true');
    });

    test('Scenario 2: keepBackupOnSuccess: true survives cleanupPending recovery', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scen2_cleanup_pending.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      // Synthesize journal with cleanupPending and keepBackupOnSuccess: true
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.cleanupPending,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
        keepBackupOnSuccess: true,
      );
      await journal.record(MigrationState.cleanupPending, err: 'File lock during cleanup');

      // Run recovery
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // Verification: safety backup retained
      expect(File(bkpPath).existsSync(), isTrue, reason: 'Safety backup retained during cleanupPending recovery');
      expect(File(journalPath).existsSync(), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
    });

    test('Scenario 3: keepBackupOnSuccess: true survives recoveryRequired recovery when active encrypted DB validates', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scen3_recovery_required.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      // Synthesize recoveryRequired state
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.recoveryRequired,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
        keepBackupOnSuccess: true,
      );
      await journal.record(MigrationState.recoveryRequired, err: 'Interrupted swap');

      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // Verification: live encrypted DB validates, journal cleared, safety backup PRESERVED!
      expect(File(bkpPath).existsSync(), isTrue);
      expect(File(journalPath).existsSync(), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
    });

    test('Scenario 4: keepBackupOnSuccess: false permits backup deletion only after successful validation', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scen4_keep_false.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      // Migrate with keepBackupOnSuccess: true just to have backup on disk
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      // Now synthesize verified recovery with keepBackupOnSuccess: false
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.verified,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
        keepBackupOnSuccess: false,
      );
      await journal.record(MigrationState.verified);

      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // Verification: because keepBackupOnSuccess was false, backup is swept after successful validation
      expect(File(bkpPath).existsSync(), isFalse);
      expect(File(journalPath).existsSync(), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);
    });

    test('Scenario 5: Invalid/corrupt active DB preserves backup regardless of retention setting', () async {
      // Test 5A: keepBackupOnSuccess = false, but DB is corrupt
      final dbPath = await createValidPlaintextDb(fileName: 'scen5_corrupt.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      // Corrupt live database file
      final corruptBytes = Uint8List(4096)..fillRange(0, 4096, 0xEE);
      await File(dbPath).writeAsBytes(corruptBytes);

      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.cleanupPending,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: join(dbDir, '$dbName.migration_staging'),
        rollbackBackupPath: bkpPath,
        keepBackupOnSuccess: false, // configured to delete, BUT active DB is corrupt!
      );
      await journal.record(MigrationState.cleanupPending);

      // Recovery MUST fail and MUST PRESERVE the backup!
      await expectLater(
        migrationService.recoverInterruptedMigration(
          dbPath: dbPath,
          keyOverride: masterKeyBytes,
        ),
        throwsA(isA<MigrationCrashRecoveryException>()),
      );

      // Verification: backup MUST still exist!
      expect(File(bkpPath).existsSync(), isTrue, reason: 'Backup must never be deleted when active DB is corrupt');
      // Journal must NOT be cleared
      expect(File(journalPath).existsSync(), isTrue);
    });

    test('Scenario 6: Legacy journal without a retention field preserves the safety backup', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scen6_legacy.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      // Write a raw legacy journal JSON WITHOUT 'keepBackupOnSuccess' key
      final legacyJson = {
        'state': 'verified',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'sourceDbPath': dbPath,
        'stagedDbPath': join(dbDir, '$dbName.migration_staging'),
        'rollbackBackupPath': bkpPath,
        'fingerprint': null,
        'error': null,
      };
      await File(journalPath).writeAsString(jsonEncode(legacyJson));

      // Load journal and verify backward-compatible default
      final loadedJournal = await MigrationJournal.load(journalPath);
      expect(loadedJournal, isNotNull);
      expect(loadedJournal!.keepBackupOnSuccess, isTrue, reason: 'Legacy journal must default to keepBackupOnSuccess: true');

      // Execute recovery
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // Verification: safety backup is preserved because legacy journal defaults to true
      expect(File(bkpPath).existsSync(), isTrue, reason: 'Legacy journal preserves safety backup');
      expect(File(journalPath).existsSync(), isFalse);
    });

    test('Scenario 7: Repeated recovery remains idempotent with keepBackupOnSuccess: true', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scen7_idempotent.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final stagingPath = join(dbDir, '$dbName.migration_staging');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      await File(stagingPath).writeAsString('stale-staging');
      final journal = MigrationJournal(
        file: File(journalPath),
        state: MigrationState.cleanupPending,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: dbPath,
        stagedDbPath: stagingPath,
        rollbackBackupPath: bkpPath,
        keepBackupOnSuccess: true,
      );
      await journal.record(MigrationState.cleanupPending);

      // Recovery Run 1
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(File(bkpPath).existsSync(), isTrue);
      expect(File(stagingPath).existsSync(), isFalse);
      expect(File(journalPath).existsSync(), isFalse);

      // Recovery Run 2 (no-op since journal is cleared)
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      // Recovery Run 3
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(File(bkpPath).existsSync(), isTrue);
    });

    test('Scenario 8: User-created .spendx files remain untouched during recovery and stale artifact cleanup', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'scen8_spendx_untouched.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final stagingPath = join(dbDir, '$dbName.migration_staging');

      // Create dummy user backup packages (.spendx files) in db directory
      final userPackage1 = File(join(dbDir, 'spendx_backup_20261104.spendx'));
      final userPackage2 = File(join(dbDir, 'manual_export.spendx'));
      await userPackage1.writeAsString('encrypted-user-backup-package-payload-1');
      await userPackage2.writeAsString('encrypted-user-backup-package-payload-2');

      // Perform migration
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: false, // configured to delete migration backup
      );

      // Create stale migration staging file
      await File(stagingPath).writeAsString('staged-data');

      // Run stale artifact cleanup with preserveSafetyBackup: false
      final cleaned = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        preserveSafetyBackup: false,
      );
      expect(cleaned, greaterThanOrEqualTo(1)); // swept staging
      expect(File(stagingPath).existsSync(), isFalse);

      // User .spendx packages MUST NEVER be deleted!
      expect(userPackage1.existsSync(), isTrue, reason: 'User backup package 1 was untouched');
      expect(userPackage2.existsSync(), isTrue, reason: 'User backup package 2 was untouched');
      expect(await userPackage1.readAsString(), equals('encrypted-user-backup-package-payload-1'));
      expect(await userPackage2.readAsString(), equals('encrypted-user-backup-package-payload-2'));

      // Also verify recoverInterruptedMigration does not touch .spendx files
      await migrationService.recoverInterruptedMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(userPackage1.existsSync(), isTrue);
      expect(userPackage2.existsSync(), isTrue);
    });
  });
}
