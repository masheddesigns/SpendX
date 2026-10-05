import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables_v24.dart';
import 'package:spend_x/data/security/database_encryption_migration_service.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/services/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const originalProductionDbPath =
      '/Users/sivek/Library/Containers/com.sivek.spendx/Data/Documents/spendx_local.db';
  const expectedOriginalSha256 =
      'e7dfa198b67d1b855d89ddd0b0cf834a375e24ae33c3224d2f64942e37287c39';

  late Directory testEnvDir;
  late String disposableDbPath;
  late SpendXDatabaseKeyManager testKeyManager;
  late InMemorySecureStorageAdapter testStorageAdapter;

  setUpAll(() async {
    await SpendXDatabaseFactory.instance.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    testEnvDir = Directory('test/rdv_validation/run_env').absolute;
    if (await testEnvDir.exists()) {
      await testEnvDir.delete(recursive: true);
    }
    await testEnvDir.create(recursive: true);

    disposableDbPath = p.join(testEnvDir.path, 'spendx.db');

    testStorageAdapter = InMemorySecureStorageAdapter();
    testKeyManager = SpendXDatabaseKeyManager(storageAdapter: testStorageAdapter);
    SpendXDatabaseKeyManager.setTestInstance(testKeyManager);
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.setTestDatabasePath(null);
    SpendXDatabaseKeyManager.setTestInstance(null);
  });

  group('SpendX 2.0 — Milestone C11-RDV Real-Device Validation Suite', () {
    test('Complete C11-RDV Lifecycle on Realistic SpendX Database Copy', () async {
      // -----------------------------------------------------------------------
      // 1. SAFETY VERIFICATION: Check Original Production Source Exists & Matches
      // -----------------------------------------------------------------------
      final originalFile = File(originalProductionDbPath);
      expect(await originalFile.exists(), isTrue,
          reason: 'Original production spendx_local.db must exist.');
      final preShaBytes = await originalFile.readAsBytes();
      final preSha = sha256.convert(preShaBytes).toString();
      expect(preSha, equals(expectedOriginalSha256),
          reason: 'Original source database hash must match baseline exactly.');

      // -----------------------------------------------------------------------
      // 2. DISPOSABLE COPY CREATION & PREPARATION TO PLAINTEXT V24
      // -----------------------------------------------------------------------
      await originalFile.copy(disposableDbPath);
      final disposableFile = File(disposableDbPath);
      expect(await disposableFile.exists(), isTrue);
      expect(await disposableFile.length(), equals(await originalFile.length()));

      // Defensive compatibility: Ensure legacy transactions table has columns added in v7/v9/v17
      // so AppDatabase._applyUpgrades runs cleanly to plaintext v24.
      final rawDb = await openDatabase(disposableDbPath);
      final txCols = await rawDb.rawQuery('PRAGMA table_info(transactions);');
      if (!txCols.any((c) => c['name'] == 'is_deleted')) {
        await rawDb.execute('ALTER TABLE transactions ADD COLUMN is_deleted INTEGER DEFAULT 0;');
      }
      if (!txCols.any((c) => c['name'] == 'account_id')) {
        await rawDb.execute('ALTER TABLE transactions ADD COLUMN account_id TEXT;');
      }
      if (!txCols.any((c) => c['name'] == 'external_ref')) {
        await rawDb.execute('ALTER TABLE transactions ADD COLUMN external_ref TEXT;');
      }
      await rawDb.close();

      // Open with AppDatabase to upgrade to plaintext v24 (bypassing auto-migration for testing)
      AppDatabase.autoMigrateLegacyPlaintext = false;
      AppDatabase.setTestDatabasePath(disposableDbPath);
      final prePlainDb = await AppDatabase.instance.database;

      final preVersionRows = await prePlainDb.rawQuery('PRAGMA user_version;');
      final preSchemaVer = preVersionRows.first.values.first as int;
      expect(preSchemaVer, equals(24), reason: 'Database must be upgraded to schema v24.');

      final preTriggerRows = await prePlainDb.rawQuery(
          "SELECT count(*) as cnt FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_%';");
      final preTriggerCount = (preTriggerRows.first['cnt'] as num).toInt();
      expect(preTriggerCount, equals(7), reason: 'All 7 financial triggers must be active.');

      // -----------------------------------------------------------------------
      // 3. CAPTURE PRE-MIGRATION EVIDENCE & ACCOUNTING FINGERPRINT
      // -----------------------------------------------------------------------
      final preMigrationFingerprint = await AccountingFingerprint.fromDatabase(prePlainDb);
      expect(preMigrationFingerprint.schemaVersion, equals(24));
      expect(preMigrationFingerprint.activeTriggersCount, equals(7));
      expect(preMigrationFingerprint.categoryCount, equals(6));
      expect(preMigrationFingerprint.ledgerTransactionCount, equals(21));
      expect(preMigrationFingerprint.accountCount, greaterThanOrEqualTo(9));

      // Close connection and quiesce WAL prior to C11 migration
      await AppDatabase.instance.close();
      AppDatabase.autoMigrateLegacyPlaintext = true;

      // Verify file is currently plaintext SQLite
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(disposableDbPath), isTrue);

      // -----------------------------------------------------------------------
      // 4. MIGRATION EXECUTION: C11 Plaintext -> SQLCipher Out-of-Place Migration
      // -----------------------------------------------------------------------
      final migrationService = DatabaseEncryptionMigrationService(
        keyManager: testKeyManager,
        factory: SpendXDatabaseFactory.instance,
      );

      final migrationResult = await migrationService.runMigration(
        dbPath: disposableDbPath,
      );

      expect(migrationResult.success, isTrue);
      expect(migrationResult.skipped, isFalse);
      expect(migrationResult.finalState, equals(MigrationState.verified));

      // -----------------------------------------------------------------------
      // 5. ENCRYPTION VERIFICATION
      // -----------------------------------------------------------------------
      // A. File is no longer plaintext SQLite
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(disposableDbPath), isFalse,
          reason: 'Migrated file header must not match plaintext SQLite.');

      // B. Standard plaintext SQLite fails to open file
      expect(
        () async {
          final badDb = await openDatabase(disposableDbPath, singleInstance: false);
          try {
            await badDb.rawQuery('SELECT count(*) FROM sqlite_master;');
          } finally {
            await badDb.close();
          }
        }(),
        throwsA(anything),
        reason: 'Raw SQLite opening without SQLCipher key must fail.',
      );

      // C. Opening with wrong key fails
      const wrongBlobKey = "x'1111111111111111111111111111111111111111111111111111111111111111'";
      expect(
        () async {
          final wrongDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
            disposableDbPath,
            password: wrongBlobKey,
            singleInstance: false,
          );
          await wrongDb.close();
        }(),
        throwsA(isA<SqlCipherException>()),
        reason: 'Opening with wrong key must be rejected by SQLCipher.',
      );

      // D. Opening with correct SpendX key succeeds
      final correctKey = await testKeyManager.getKey();
      expect(correctKey, isNotNull);
      final correctBlobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(correctKey!);
      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        disposableDbPath,
        password: correctBlobKey,
      );

      final cipherVersionRows = await encDb.rawQuery('PRAGMA cipher_version;');
      expect(cipherVersionRows, isNotEmpty);
      expect(cipherVersionRows.first.values.first.toString().toLowerCase(),
          contains('4.18.0 community'));

      final encVersionRows = await encDb.rawQuery('PRAGMA user_version;');
      expect(encVersionRows.first.values.first, equals(24));

      // -----------------------------------------------------------------------
      // 6. ACCOUNTING PARITY VERIFICATION
      // -----------------------------------------------------------------------
      final postMigrationFingerprint = await AccountingFingerprint.fromDatabase(encDb);
      expect(postMigrationFingerprint.matches(preMigrationFingerprint), isTrue,
          reason: 'Every single field in pre and post migration fingerprints must match.');
      expect(postMigrationFingerprint.schemaVersion, equals(preMigrationFingerprint.schemaVersion));
      expect(postMigrationFingerprint.activeTriggersCount,
          equals(preMigrationFingerprint.activeTriggersCount));
      expect(postMigrationFingerprint.accountCount, equals(preMigrationFingerprint.accountCount));
      expect(postMigrationFingerprint.economicEventCount,
          equals(preMigrationFingerprint.economicEventCount));
      expect(postMigrationFingerprint.postingCount, equals(preMigrationFingerprint.postingCount));
      expect(postMigrationFingerprint.debitTotalMinorUnits,
          equals(preMigrationFingerprint.debitTotalMinorUnits));
      expect(postMigrationFingerprint.creditTotalMinorUnits,
          equals(preMigrationFingerprint.creditTotalMinorUnits));
      expect(postMigrationFingerprint.netWorthMinorUnits,
          equals(preMigrationFingerprint.netWorthMinorUnits));
      expect(postMigrationFingerprint.incomeMinorUnits, equals(preMigrationFingerprint.incomeMinorUnits));
      expect(postMigrationFingerprint.expenseMinorUnits,
          equals(preMigrationFingerprint.expenseMinorUnits));
      expect(postMigrationFingerprint.cashFlowMinorUnits,
          equals(preMigrationFingerprint.cashFlowMinorUnits));
      expect(postMigrationFingerprint.safeToSpendMinorUnits,
          equals(preMigrationFingerprint.safeToSpendMinorUnits));
      expect(postMigrationFingerprint.reviewCandidateCount,
          equals(preMigrationFingerprint.reviewCandidateCount));
      expect(postMigrationFingerprint.evidenceCount, equals(preMigrationFingerprint.evidenceCount));
      expect(postMigrationFingerprint.assetEarmarkCount,
          equals(preMigrationFingerprint.assetEarmarkCount));
      expect(postMigrationFingerprint.categoryCount, equals(preMigrationFingerprint.categoryCount));
      expect(postMigrationFingerprint.budgetCount, equals(preMigrationFingerprint.budgetCount));
      expect(postMigrationFingerprint.ledgerTransactionCount,
          equals(preMigrationFingerprint.ledgerTransactionCount));

      // Capture Accounts for writing test below
      final allAccounts = await encDb.query('accounts');
      final firstAssetAccount = allAccounts.firstWhere(
        (a) => (a['account_type'] as String).toLowerCase() == 'asset',
        orElse: () => allAccounts.first,
      );
      final assetAccountId = firstAssetAccount['id'] as String;

      await encDb.close();

      // Sidecars and staging cleanup check
      expect(await File('$disposableDbPath.migration_staging').exists(), isFalse);
      expect(await File('$disposableDbPath.pre_migration_backup').exists(), isFalse);
      expect(await File('$disposableDbPath.pre_encrypted_archive').exists(), isFalse);

      // -----------------------------------------------------------------------
      // 7. NORMAL APPLICATION STARTUP PATH
      // -----------------------------------------------------------------------
      AppDatabase.setTestDatabasePath(disposableDbPath);
      final liveAppDb = await AppDatabase.instance.database;
      expect(liveAppDb.isOpen, isTrue);

      // -----------------------------------------------------------------------
      // 8. REPRESENTATIVE CANONICAL READS
      // -----------------------------------------------------------------------
      final accountsRead = await liveAppDb.query('accounts');
      expect(accountsRead.length, equals(preMigrationFingerprint.accountCount));

      final categoriesRead = await liveAppDb.query('categories');
      expect(categoriesRead.length, equals(6));

      final txnsRead = await liveAppDb.query('ledger_transactions');
      expect(txnsRead.length, equals(21));

      final triggersRead = await liveAppDb.rawQuery(
          "SELECT count(*) as cnt FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_%';");
      expect((triggersRead.first['cnt'] as num).toInt(), equals(7));

      // -----------------------------------------------------------------------
      // 9. REPRESENTATIVE WRITE VALIDATION (Controlled Double-Entry Transaction)
      // -----------------------------------------------------------------------
      final nowStr = DateTime.now().toUtc().toIso8601String();
      const testEventId = 'evt_rdv_test_001';
      const testAmountMinor = 150000; // Rs 1,500.00
      final sysEquity = TablesV24.sysEquityOpening;

      await liveAppDb.transaction((txn) async {
        await txn.insert(TablesV24.economicEvents, {
          'id': testEventId,
          'event_type': 'opening_balance',
          'lifecycle_status': 'draft',
          'timestamp': nowStr,
          'description': 'RDV Representative Write Test',
          'created_at': nowStr,
          'updated_at': nowStr,
        });

        await txn.insert(TablesV24.postings, {
          'id': 'pst_rdv_1',
          'economic_event_id': testEventId,
          'account_id': assetAccountId,
          'sequence_number': 1,
          'direction': 'debit',
          'amount_minor_units': testAmountMinor,
          'currency': 'INR',
          'created_at': nowStr,
        });

        await txn.insert(TablesV24.postings, {
          'id': 'pst_rdv_2',
          'economic_event_id': testEventId,
          'account_id': sysEquity,
          'sequence_number': 2,
          'direction': 'credit',
          'amount_minor_units': testAmountMinor,
          'currency': 'INR',
          'created_at': nowStr,
        });

        await txn.update(
          TablesV24.economicEvents,
          {'lifecycle_status': 'posted', 'updated_at': nowStr},
          where: 'id = ?',
          whereArgs: [testEventId],
        );
      });

      // Verify double-entry balance: debit == credit
      final writtenDebits = await liveAppDb.rawQuery(
        "SELECT SUM(amount_minor_units) as s FROM postings WHERE economic_event_id = ? AND direction = 'debit';",
        [testEventId],
      );
      final writtenCredits = await liveAppDb.rawQuery(
        "SELECT SUM(amount_minor_units) as s FROM postings WHERE economic_event_id = ? AND direction = 'credit';",
        [testEventId],
      );
      expect(writtenDebits.first['s'], equals(writtenCredits.first['s']));
      expect(writtenDebits.first['s'], equals(testAmountMinor));

      // -----------------------------------------------------------------------
      // 10. CLOSE / REOPEN TEST
      // -----------------------------------------------------------------------
      await AppDatabase.instance.close();

      // Reopen through normal AppDatabase path
      final reopenedDb = await AppDatabase.instance.database;
      expect(reopenedDb.isOpen, isTrue);

      final reopenedEvents = await reopenedDb.query(
        TablesV24.economicEvents,
        where: 'id = ?',
        whereArgs: [testEventId],
      );
      expect(reopenedEvents.length, equals(1));
      expect(reopenedEvents.first['lifecycle_status'], equals('posted'));

      // -----------------------------------------------------------------------
      // 11. KEY-LOSS SAFETY CHECK (Fatal Failure, No Silent Regeneration)
      // -----------------------------------------------------------------------
      await AppDatabase.instance.close();

      final isolatedEmptyKeyManager = SpendXDatabaseKeyManager(
        storageAdapter: InMemorySecureStorageAdapter(), // Empty storage
      );

      expect(
        () async => await isolatedEmptyKeyManager.getOrCreateKey(
          encryptedDbPath: disposableDbPath,
        ),
        throwsA(isA<KeyLossFatalException>()),
        reason: 'Missing key for an existing encrypted database must throw fatal key-loss.',
      );

      // Verify disposable DB file was NOT modified or replaced with an empty DB
      final fileAfterKeyLossCheck = File(disposableDbPath);
      expect(await fileAfterKeyLossCheck.exists(), isTrue);
      expect(await fileAfterKeyLossCheck.length(), greaterThan(0));
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(disposableDbPath), isFalse);

      // -----------------------------------------------------------------------
      // 12. BACKUP COMPATIBILITY (C8 Backup & Restore on Encrypted Active Database)
      // -----------------------------------------------------------------------
      final reopenedDbForBackup = await AppDatabase.instance.database;
      final backupOutputFile = File(p.join(testEnvDir.path, 'rdv_backup.spendx'));

      final (backupPackage, manifest) = await BackupService.instance.createBackupPackage(
        sourceDb: reopenedDbForBackup,
        sourceDbPath: disposableDbPath,
        outputFile: backupOutputFile,
      );

      expect(await backupPackage.exists(), isTrue);
      expect(manifest.canonicalEventCount, equals(1)); // The 1 test event posted earlier
      expect(manifest.postingCount, equals(2));
      expect(manifest.debitTotal, equals(testAmountMinor));
      expect(manifest.creditTotal, equals(testAmountMinor));

      // Assert database key is NOT embedded in the backup artifact
      final backupBytes = await backupPackage.readAsBytes();
      final backupRawString = String.fromCharCodes(backupBytes);
      final keyHex = correctKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(backupRawString.contains(keyHex), isFalse,
          reason: 'Raw database key must never be stored in the backup package.');

      // Restore to a fresh disposable target path
      final restoreTargetDbPath = p.join(testEnvDir.path, 'restored_spendx.db');
      final restoreSuccess = await BackupService.instance.restoreFromFile(
        backupPackage,
        targetDbPath: restoreTargetDbPath,
      );
      expect(restoreSuccess, isTrue);

      // Verify restored target database is encrypted and opens with SpendX key
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(restoreTargetDbPath), isFalse);
      final restoredDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        restoreTargetDbPath,
        password: correctBlobKey,
      );
      final restoredFingerprint = await AccountingFingerprint.fromDatabase(restoredDb);
      expect(restoredFingerprint.schemaVersion, equals(24));
      expect(restoredFingerprint.activeTriggersCount, equals(7));
      expect(restoredFingerprint.economicEventCount, equals(1));
      expect(restoredFingerprint.postingCount, equals(2));
      expect(restoredFingerprint.debitTotalMinorUnits, equals(testAmountMinor));
      expect(restoredFingerprint.creditTotalMinorUnits, equals(testAmountMinor));
      await restoredDb.close();

      // -----------------------------------------------------------------------
      // 13. MIGRATION IDEMPOTENCE: Re-running on Encrypted DB is NO-OP
      // -----------------------------------------------------------------------
      final idempotenceResult = await migrationService.runMigration(
        dbPath: disposableDbPath,
        keyOverride: correctKey,
      );
      expect(idempotenceResult.success, isTrue);
      expect(idempotenceResult.skipped, isTrue);
      expect(idempotenceResult.finalState, equals(MigrationState.none));

      // -----------------------------------------------------------------------
      // 14. PRODUCTION DATABASE PROTECTION CHECK: Original Source UNCHANGED
      // -----------------------------------------------------------------------
      final postShaBytes = await originalFile.readAsBytes();
      final postSha = sha256.convert(postShaBytes).toString();
      expect(postSha, equals(preSha),
          reason: 'Original source database must remain untouched with bit-exact hash parity.');
      expect(postSha, equals(expectedOriginalSha256));
    });
  });
}
