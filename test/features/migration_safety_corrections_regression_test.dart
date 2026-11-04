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
    tempDir = await Directory.systemTemp.createTemp('spendx_45b2_regression_');
    mockStorage = InMemorySecureStorageAdapter();
    keyManager = SpendXDatabaseKeyManager(storageAdapter: mockStorage);
    SpendXDatabaseKeyManager.setTestInstance(keyManager);
    migrationService = DatabaseEncryptionMigrationService(
      keyManager: keyManager,
      factory: SpendXDatabaseFactory.instance,
    );
    await SpendXDatabaseFactory.instance.initialize();

    masterKeyBytes = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 13 + 41) % 256),
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
    int initialBalanceMinorUnits = 5000000,
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
      'id': 'acc_test_45b2',
      'account_type': 'asset',
      'subtype': 'checking',
      'name': 'Checking 45B2',
      'currency': 'INR',
      'is_active': 1,
      'is_system': 0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final eventId = 'ev_seed_45b2';
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
      'id': 'post_seed_45b2_01',
      'economic_event_id': eventId,
      'account_id': 'acc_test_45b2',
      'sequence_number': 1,
      'direction': 'debit',
      'amount_minor_units': initialBalanceMinorUnits,
      'currency': 'INR',
      'created_at': now,
    });

    await db.insert('postings', {
      'id': 'post_seed_45b2_02',
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

  group('Milestone 4.5B.2: Migration Safety Corrections Regression Suite', () {
    test('Regression 1: Valid SQLCipher database permits artifact cleanup', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg1_valid_cleanup.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final archivePath = join(dbDir, '$dbName.pre_encrypted_archive');
      final stagingPath = join(dbDir, '$dbName.migration_staging');
      final journalPath = join(dbDir, 'spendx_migration_state.json');

      // Migrate
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);

      // Create dummy archive and staging files
      await File(archivePath).writeAsString('dummy-archive');
      await File(stagingPath).writeAsString('dummy-staging');

      // Validate live database via shared validator
      final isValid = await migrationService.validateEncryptedDatabase(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(isValid, isTrue);

      // Clean artifacts
      final cleaned = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(cleaned, equals(3));
      expect(File(bkpPath).existsSync(), isFalse);
      expect(File(archivePath).existsSync(), isFalse);
      expect(File(stagingPath).existsSync(), isFalse);
      expect(File(journalPath).existsSync(), isFalse);
    });

    test('Regression 2: Corrupted non-plaintext database preserves all recovery artifacts', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg2_corrupt_db.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final archivePath = join(dbDir, '$dbName.pre_encrypted_archive');

      // Migrate
      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      await File(archivePath).writeAsString('dummy-archive');

      // Corrupt live database with random bytes
      final corruptBytes = Uint8List(8192)..fillRange(0, 8192, 0xCC);
      await File(dbPath).writeAsBytes(corruptBytes);

      // Attempt cleanup
      final cleaned = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );

      // All artifacts must be preserved
      expect(cleaned, equals(0));
      expect(File(bkpPath).existsSync(), isTrue);
      expect(File(archivePath).existsSync(), isTrue);
    });

    test('Regression 3: Wrong encryption key preserves all recovery artifacts', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg3_wrong_key.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final archivePath = join(dbDir, '$dbName.pre_encrypted_archive');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      await File(archivePath).writeAsString('dummy-archive');

      final wrongKeyBytes = Uint8List(32)..fillRange(0, 32, 0x55);

      // Attempt cleanup with wrong key
      final cleaned = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: wrongKeyBytes,
      );

      expect(cleaned, equals(0));
      expect(File(bkpPath).existsSync(), isTrue);
      expect(File(archivePath).existsSync(), isTrue);
    });

    test('Regression 4: Wrong schema version preserves all recovery artifacts', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg4_wrong_version.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );

      // Alter user_version to 23
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );
      await db.execute('PRAGMA user_version = 23;');
      await db.close();

      // Shared validator must reject version 23
      final isValid = await migrationService.validateEncryptedDatabase(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        expectedSchemaVersion: 24,
      );
      expect(isValid, isFalse);

      final cleaned = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(cleaned, equals(0));
      expect(File(bkpPath).existsSync(), isTrue);
    });

    test('Regression 5: Integrity-check failure preserves all recovery artifacts', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg5_integrity_fail.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );

      // Corrupt a middle page of the encrypted database (e.g. at offset 4096)
      final bytes = await File(dbPath).readAsBytes();
      if (bytes.length > 5000) {
        for (int i = 4096; i < 4150; i++) {
          bytes[i] = bytes[i] ^ 0xFF;
        }
        await File(dbPath).writeAsBytes(bytes);
      }

      // Shared validator must fail
      final isValid = await migrationService.validateEncryptedDatabase(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(isValid, isFalse);

      final cleaned = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(cleaned, equals(0));
      expect(File(bkpPath).existsSync(), isTrue);
    });

    test('Regression 6: Foreign-key violations preserve all recovery artifacts', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg6_fk_violations.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );

      // Open database, disable FK checks, and insert an orphan salary_contract referencing a non-existent company
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
      );
      await db.execute('PRAGMA foreign_keys = OFF;');
      await db.insert('salary_contracts', {
        'id': 'contract_orphan_reg6',
        'company_id': 'non_existent_company_id',
        'base_salary': 50000.0,
        'start_date': '2026-01-01',
        'created_at': DateTime.now().toIso8601String(),
      });
      await db.close();

      // Shared validator must reject because foreign_key_check reports violations
      final isValid = await migrationService.validateEncryptedDatabase(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(isValid, isFalse);

      final cleaned = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(cleaned, equals(0));
      expect(File(bkpPath).existsSync(), isTrue);
    });

    test('Regression 7: Repeated cleanup is completely idempotent', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg7_idempotent.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');

      await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(File(bkpPath).existsSync(), isTrue);

      final count1 = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(count1, equals(1));
      expect(File(bkpPath).existsSync(), isFalse);

      final count2 = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(count2, equals(0));

      final count3 = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
      );
      expect(count3, equals(0));
    });

    test('Regression 8: keepBackupOnSuccess and preserveSafetyBackup policies are respected', () async {
      final dbPath = await createValidPlaintextDb(fileName: 'reg8_retention.db');
      final dbDir = dirname(dbPath);
      final dbName = basename(dbPath);
      final bkpPath = join(dbDir, '$dbName.pre_migration_backup');
      final stagingPath = join(dbDir, '$dbName.migration_staging');

      // 1. keepBackupOnSuccess: true preserves the backup on migration success
      final res = await migrationService.runMigration(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        keepBackupOnSuccess: true,
      );
      expect(res.success, isTrue);
      expect(File(bkpPath).existsSync(), isTrue);

      // Create a stale staging file
      await File(stagingPath).writeAsString('stale-staging');

      // 2. Artifact sweeper with preserveSafetyBackup: true preserves pre_migration_backup
      final swept = await DatabaseEncryptionMigrationService.cleanStaleMigrationArtifacts(
        dbPath: dbPath,
        keyOverride: masterKeyBytes,
        preserveSafetyBackup: true,
      );
      expect(swept, equals(1)); // only staging was swept
      expect(File(stagingPath).existsSync(), isFalse);
      expect(File(bkpPath).existsSync(), isTrue); // backup preserved!
    });
  });
}
