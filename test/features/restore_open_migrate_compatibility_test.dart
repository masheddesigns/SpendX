// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/restore_recovery_service.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/core/tables_v25.dart';
import 'package:spend_x/data/core/tables_v26.dart';
import 'package:spend_x/data/migrations/migration_v26_service.dart';
import 'package:spend_x/data/security/database_key_manager.dart';

void main() {
  late Directory tempDir;
  late Uint8List testKey;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('spendx_restore_compatibility_');
    testKey = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 13) % 256));
  });

  tearDown(() {
    MigrationV26Service.setTestFailurePoint(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<String> createEncryptedDatabaseFixture({
    required String fileName,
    required int targetVersion,
    bool corruptIntegrity = false,
  }) async {
    final dbPath = p.join(tempDir.path, fileName);
    final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(testKey);

    final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
      dbPath,
      password: blobKey,
      bypassPrimaryGuard: true,
    );

    try {
      await db.execute('PRAGMA foreign_keys = ON;');
      await TablesV24.createAllV24(db);
      await TablesV24.seedSystemAccounts(db);
      await TablesV24.installTriggers(db);

      if (targetVersion == 25) {
        await TablesV25.createAllV25(db);
        await db.execute('PRAGMA user_version = 25;');
      } else if (targetVersion >= 26) {
        await TablesV25.createAllV25(db);
        await TablesV26.createAllV26(db);
        await db.execute('PRAGMA user_version = $targetVersion;');
      } else {
        await db.execute('PRAGMA user_version = $targetVersion;');
      }

      // Seed a sample account
      await db.insert(TablesV24.accounts, {
        'id': 'acc_test_compat',
        'account_type': 'asset',
        'subtype': 'checking',
        'name': 'Test Checking Account',
        'currency': 'INR',
        'is_active': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      if (corruptIntegrity) {
        // Intentionally corrupt SQLite header/data
        await db.execute('PRAGMA foreign_keys = OFF;');
      }
    } finally {
      await db.close();
    }

    if (corruptIntegrity) {
      final file = File(dbPath);
      final bytes = await file.readAsBytes();
      // Corrupt bytes in the middle of page
      if (bytes.length > 200) {
        for (int i = 50; i < 150; i++) {
          bytes[i] = 0xFF;
        }
        await file.writeAsBytes(bytes);
      }
    }

    return dbPath;
  }

  group('RestoreRecoveryService Candidate Compatibility & Ordering Verification', () {
    test('1. Candidate validation accepts v24 candidate without migrating it in place', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'candidate_v24.db',
        targetVersion: 24,
      );

      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isValid, isTrue, reason: 'v24 candidate database must be recognized as valid');

      // Verify the candidate file on disk is STILL user_version 24 (validation does not mutate schema)
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(testKey);
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        bypassPrimaryGuard: true,
      );
      final ver = (await db.rawQuery('PRAGMA user_version;')).first.values.first as int;
      await db.close();
      expect(ver, 24, reason: 'validateCandidateDatabase must be purely read-only and never migrate schema in place');
    });

    test('2. Candidate validation accepts v25 candidate without mutating schema', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'candidate_v25.db',
        targetVersion: 25,
      );

      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isValid, isTrue, reason: 'v25 candidate database must be recognized as valid');

      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(testKey);
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        bypassPrimaryGuard: true,
      );
      final ver = (await db.rawQuery('PRAGMA user_version;')).first.values.first as int;
      await db.close();
      expect(ver, 25, reason: 'v25 candidate must retain schema version 25 after validation');
    });

    test('3. Candidate validation accepts v26 candidate', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'candidate_v26.db',
        targetVersion: 26,
      );

      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isValid, isTrue, reason: 'v26 candidate database must be recognized as valid');
    });

    test('4. Candidate validation rejects unsupported legacy version (< 24)', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'candidate_v23.db',
        targetVersion: 23,
      );

      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isValid, isFalse, reason: 'Candidate with user_version < 24 must be rejected');
    });

    test('5. Candidate validation rejects unsupported future version (> 26)', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'candidate_v27.db',
        targetVersion: 27,
      );

      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isValid, isFalse, reason: 'Candidate with user_version > 26 must be rejected to prevent downgrade risk');
    });

    test('6. Candidate validation rejects corrupted database file', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'candidate_corrupt.db',
        targetVersion: 26,
        corruptIntegrity: true,
      );

      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isValid, isFalse, reason: 'Corrupt ciphertext or invalid SQLite header must fail candidate validation');
    });

    test('7. Candidate validation rejects candidate when supplied key is incorrect', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'candidate_wrong_key.db',
        targetVersion: 26,
      );

      final wrongKey = Uint8List.fromList(List.filled(32, 0xEE));
      final isValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: wrongKey,
      );
      expect(isValid, isFalse, reason: 'SQLCipher key mismatch must fail candidate validation without crashing');
    });

    test('8. End-to-end: Restored v24 database is migrated to v26 upon application open before repository access', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'restored_v24.db',
        targetVersion: 24,
      );

      // Verify it passes candidate validation
      final isCandidateValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isCandidateValid, isTrue);

      // Open via AppDatabase test path targeting version 26
      AppDatabase.setTestDatabasePath(dbPath);
      AppDatabase.autoMigrateLegacyPlaintext = false;

      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(testKey);
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        bypassPrimaryGuard: true,
        version: 26,
        onUpgrade: (db, oldVersion, newVersion) async {
          await AppDatabase.instance.migrateSchemaOnly(db, oldVersion);
        },
      );

      try {
        // Assert schema version is atomically upgraded to 26
        final verRows = await db.rawQuery('PRAGMA user_version;');
        final newVersion = verRows.first.values.first as int;
        expect(newVersion, 26, reason: 'Database must be upgraded to v26 before repositories can use it');

        // Assert v25 column exists
        final evidenceCols = await db.rawQuery('PRAGMA table_info(${TablesV24.evidence});');
        final evidenceColNames = evidenceCols.map((c) => c['name'] as String).toSet();
        expect(evidenceColNames.contains('source_record_id'), isTrue);

        // Assert v26 table exists
        final v26Tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name = '${TablesV26.evidenceReconciliations}';",
        );
        expect(v26Tables.length, 1);

        // Assert pre-existing data is intact
        final acc = await db.query(
          TablesV24.accounts,
          where: 'id = ?',
          whereArgs: ['acc_test_compat'],
        );
        expect(acc.length, 1);
        expect(acc.first['name'], 'Test Checking Account');
      } finally {
        await db.close();
        AppDatabase.setTestDatabasePath(null);
      }
    });

    test('9. End-to-end: Restored v25 database is migrated to v26 upon application open before repository access', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'restored_v25.db',
        targetVersion: 25,
      );

      final isCandidateValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isCandidateValid, isTrue);

      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(testKey);
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        bypassPrimaryGuard: true,
        version: 26,
        onUpgrade: (db, oldVersion, newVersion) async {
          await AppDatabase.instance.migrateSchemaOnly(db, oldVersion);
        },
      );

      try {
        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 26);

        final v26Tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name = '${TablesV26.evidenceReconciliations}';",
        );
        expect(v26Tables.length, 1);
      } finally {
        await db.close();
      }
    });

    test('10. End-to-end: Restored v26 database requires no redundant migration upon application open', () async {
      final dbPath = await createEncryptedDatabaseFixture(
        fileName: 'restored_v26.db',
        targetVersion: 26,
      );

      final isCandidateValid = await RestoreRecoveryService.instance.validateCandidateDatabase(
        dbPath,
        keyOverride: testKey,
      );
      expect(isCandidateValid, isTrue);

      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(testKey);
      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        bypassPrimaryGuard: true,
      );

      try {
        await AppDatabase.instance.migrateSchemaOnly(db, 26);

        final verRows = await db.rawQuery('PRAGMA user_version;');
        expect(verRows.first.values.first, 26);
      } finally {
        await db.close();
      }
    });
  });
}
