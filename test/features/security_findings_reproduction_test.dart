import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/data/security/database_encryption_migration_service.dart';
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/canonical_backup_validator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final factory = SpendXDatabaseFactory.instance;

  // Key A (Device A) and Key B (Device B)
  final keyABytes = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final keyBBytes = Uint8List.fromList(List.generate(32, (i) => 255 - i));
  final blobKeyA = SpendXDatabaseKeyManager.keyToSqlCipherBlob(keyABytes);
  final blobKeyB = SpendXDatabaseKeyManager.keyToSqlCipherBlob(keyBBytes);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_repro_test_');
    await factory.initialize();
  });

  tearDown(() async {
    SpendXDatabaseKeyManager.setTestInstance(null);
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('SEC-01 Reproduction: Cross-Device Encrypted Backup Restore Deadlock', () {
    test('SEC-01-A: VACUUM INTO on SQLCipher inherits source encryption key and rejects other keys', () async {
      final dbPath = join(tempDir.path, 'source_keyA.db');
      final snapPath = join(tempDir.path, 'vacuum_snap.db');

      final dbA = await factory.openEncryptedDatabase(
        dbPath,
        password: blobKeyA,
        version: 1,
        onCreate: (d, v) async {
          await d.execute('CREATE TABLE secrets (id INT PRIMARY KEY, data TEXT);');
          await d.execute("INSERT INTO secrets VALUES (1, 'SensitiveLedgerData');");
        },
      );

      // Execute VACUUM INTO
      await dbA.execute("VACUUM INTO '$snapPath';");
      await dbA.close();

      final snapFile = File(snapPath);
      expect(snapFile.existsSync(), isTrue);

      // 1. Confirm snapshot is NOT standard plaintext SQLite
      final headerBytes = snapFile.openSync().readSync(16);
      final isPlaintext = String.fromCharCodes(headerBytes).startsWith('SQLite format 3');
      expect(isPlaintext, isFalse, reason: 'Snapshot must not be plaintext SQLite');

      // 2. Confirm snapshot OPENS with Key A
      final openWithKeyA = await factory.openEncryptedDatabase(snapPath, password: blobKeyA);
      final rowsA = await openWithKeyA.rawQuery('SELECT * FROM secrets;');
      expect(rowsA.length, equals(1));
      expect(rowsA.first['data'], equals('SensitiveLedgerData'));
      await openWithKeyA.close();

      // 3. Confirm snapshot FAILS to open with Key B
      expect(
        () => factory.openEncryptedDatabase(snapPath, password: blobKeyB),
        throwsA(isA<SqlCipherException>()),
        reason: 'SQLCipher snapshot must reject Key B with SQLITE_NOTADB or corrupted header',
      );
    });

    test('SEC-01-B: Production BackupService cross-device restore fails when Device B uses Key B', () async {
      // 1. Setup Device A KeyManager
      final storageAdapterA = InMemorySecureStorageAdapter();
      final keyManagerA = SpendXDatabaseKeyManager(storageAdapter: storageAdapterA);
      storageAdapterA.write(
        SpendXDatabaseKeyManager.defaultKeyStorageName,
        base64Encode(keyABytes),
      );
      SpendXDatabaseKeyManager.setTestInstance(keyManagerA);

      // 2. Initialize Database A with Schema v24 and real financial transactions
      final dbAPath = join(tempDir.path, 'deviceA_spendx.db');
      final dbA = await factory.openEncryptedDatabase(
        dbAPath,
        password: blobKeyA,
        version: 24,
        onCreate: (d, v) async {
          await Tables.createAll(d);
          await TablesV24.createAllV24(d);
          await TablesV24.seedSystemAccounts(d);
          await TablesV24.installTriggers(d);
        },
      );

      final accountRepoA = AccountRepo(executor: dbA);
      final categoryRepoA = CategoryRepo(executor: dbA);
      final financialServiceA = FinancialTransactionService(database: dbA);

      const testBankId = 'acc_bank_deviceA';
      const testCatId = 'cat_salary_deviceA';

      await accountRepoA.insertAccount(
        BankAccount(
          id: testBankId,
          name: 'HDFC Checking',
          bank: 'HDFC',
          balance: 0.0,
        ),
      );
      await categoryRepoA.insert(
        Category(
          id: testCatId,
          name: 'Salary',
          icon: 'payments',
          color: '#4CAF50',
          type: 'income',
          userId: 'u1',
        ),
      );

      // Record representative financial transaction: ₹75,000.00
      await financialServiceA.createTransaction(
        spx.Transaction(
          id: 'txn_payroll_01',
          userId: 'u1',
          accountId: testBankId,
          categoryId: testCatId,
          amount: 75000.0,
          type: 'income',
          notes: 'November Monthly Payroll',
          date: DateTime.now().toUtc(),
        ),
      );

      // Verify derived balance on Device A is ₹75,000.00 (7,500,000 paise)
      final accRepoA = CanonicalAccountRepository(executor: dbA);
      final balA = await accRepoA.getDerivedBalance(testBankId);
      expect(balA.minorUnits, equals(7500000));

      // 3. Create Backup Package using production BackupService
      const backupPassword = 'CorrectBackupPassword987!';
      final backupFile = File(join(tempDir.path, 'spendx_deviceA.spendx'));

      final (packagedFile, manifest) = await BackupService.instance.createBackupPackage(
        sourceDb: dbA,
        sourceDbPath: dbAPath,
        outputFile: backupFile,
        password: backupPassword,
      );
      expect(packagedFile.existsSync(), isTrue);
      expect(manifest.isEncrypted, isTrue);
      expect(manifest.canonicalEventCount, greaterThanOrEqualTo(1));
      expect(manifest.postingCount, greaterThanOrEqualTo(2));
      expect(manifest.debitTotal, equals(7500000));
      expect(manifest.creditTotal, equals(7500000));

      await dbA.close();

      // 4. TEST CASE 1: Same-Key Restoration (Device A) SUCCEEDS
      final restoreSameKeyPath = join(tempDir.path, 'deviceA_restored.db');
      final successSame = await BackupService.instance.restoreFromFile(
        backupFile,
        targetDbPath: restoreSameKeyPath,
        password: backupPassword,
      );
      expect(successSame, isTrue);

      final restoredSameDb = await factory.openEncryptedDatabase(
        restoreSameKeyPath,
        password: blobKeyA,
      );
      final repoSame = CanonicalAccountRepository(executor: restoredSameDb);
      final balSame = await repoSame.getDerivedBalance(testBankId);
      expect(balSame.minorUnits, equals(7500000));
      await restoredSameDb.close();

      // 5. TEST CASE 2: Cross-Device Restoration (Device B with Key B) FAILS with SqlCipherException!
      // Switch DatabaseKeyManager to Device B (Key B)
      final storageAdapterB = InMemorySecureStorageAdapter();
      final keyManagerB = SpendXDatabaseKeyManager(storageAdapter: storageAdapterB);
      storageAdapterB.write(
        SpendXDatabaseKeyManager.defaultKeyStorageName,
        base64Encode(keyBBytes),
      );
      SpendXDatabaseKeyManager.setTestInstance(keyManagerB);

      final restoreDeviceBPath = join(tempDir.path, 'deviceB_restored.db');

      // Attempting restore on Device B throws SqlCipherException because inner DB was keyed to Key A!
      await expectLater(
        BackupService.instance.restoreFromFile(
          backupFile,
          targetDbPath: restoreDeviceBPath,
          password: backupPassword,
        ),
        throwsA(isA<SqlCipherException>()),
      );

      // Verify Device B target DB does not exist
      expect(File(restoreDeviceBPath).existsSync(), isFalse);

      // 6. TEST CASE 3: Fresh Install Restoration on Device B FAILS with SqlCipherException!
      // Fresh install generates a fresh random Key C in SecureStorage
      final storageAdapterFresh = InMemorySecureStorageAdapter();
      final keyManagerFresh = SpendXDatabaseKeyManager(storageAdapter: storageAdapterFresh);
      SpendXDatabaseKeyManager.setTestInstance(keyManagerFresh);

      final freshRestorePath = join(tempDir.path, 'fresh_device_restored.db');
      await expectLater(
        BackupService.instance.restoreFromFile(
          backupFile,
          targetDbPath: freshRestorePath,
          password: backupPassword,
        ),
        throwsA(isA<SqlCipherException>()),
      );

      // 7. TEST CASE 4: Wrong backup password fails with InvalidBackupPasswordException
      SpendXDatabaseKeyManager.setTestInstance(keyManagerA);
      await expectLater(
        BackupService.instance.restoreFromFile(
          backupFile,
          targetDbPath: join(tempDir.path, 'wrong_pass.db'),
          password: 'IncorrectPassword!',
        ),
        throwsA(isA<InvalidBackupPasswordException>()),
      );

      // 8. TEST CASE 5: Corrupted outer archive fails
      final tamperedFile = File(join(tempDir.path, 'tampered.spendx'));
      final zipBytes = await backupFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final tamperedArchive = Archive();

      for (final entry in archive) {
        if (entry.name == 'spendx.db.enc') {
          final content = List<int>.from(entry.content as List<int>);
          content[30] = content[30] ^ 0xFF; // Corrupt ciphertext byte
          tamperedArchive.addFile(ArchiveFile(entry.name, content.length, content));
        } else {
          tamperedArchive.addFile(entry);
        }
      }
      await tamperedFile.writeAsBytes(ZipEncoder().encode(tamperedArchive));

      await expectLater(
        BackupService.instance.restoreFromFile(
          tamperedFile,
          targetDbPath: join(tempDir.path, 'tampered_restore.db'),
          password: backupPassword,
        ),
        throwsA(isA<InvalidBackupPasswordException>()),
      );
    });
  });

  group('SEC-03 Remediation: Migration Cleanup Safety and Plaintext Rollback Prevention', () {
    test('SEC-03-A: Cleanup failure after atomic swap preserves SQLCipher and never restores plaintext DB', () async {
      // 1. Create a valid plaintext schema v24 database
      final plainDbPath = join(tempDir.path, 'plain_source.db');
      final dbDir = dirname(plainDbPath);
      final dbName = basename(plainDbPath);
      final rollbackBackupPath = join(dbDir, '$dbName.pre_migration_backup');

      final plainDb = await openDatabase(
        plainDbPath,
        version: 24,
        onCreate: (d, v) async {
          await Tables.createAll(d);
          await TablesV24.createAllV24(d);
          await TablesV24.seedSystemAccounts(d);
          await TablesV24.installTriggers(d);
          await d.execute('PRAGMA user_version = 24;');
        },
      );
      final accRepo = AccountRepo(executor: plainDb);
      await accRepo.insertAccount(
        BankAccount(
          id: 'acc_salary_bank',
          name: 'HDFC Bank',
          bank: 'HDFC',
          balance: 0.0,
        ),
      );
      await plainDb.close();

      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(plainDbPath), isTrue);

      // 2. Setup DatabaseKeyManager with Key A
      final storageAdapter = InMemorySecureStorageAdapter();
      final keyManager = SpendXDatabaseKeyManager(storageAdapter: storageAdapter);
      storageAdapter.write(
        SpendXDatabaseKeyManager.defaultKeyStorageName,
        base64Encode(keyABytes),
      );
      SpendXDatabaseKeyManager.setTestInstance(keyManager);

      // 3. Execute runMigration() with keepBackupOnSuccess: true to retain pre_migration_backup
      final service = DatabaseEncryptionMigrationService();
      final result = await service.runMigration(
        dbPath: plainDbPath,
        keyOverride: keyABytes,
        keepBackupOnSuccess: true, // bkp file is retained on disk
      );
      expect(result.success, isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(plainDbPath), isFalse);

      // Notice: rollbackBackupPath remains on disk in plaintext!
      expect(File(rollbackBackupPath).existsSync(), isTrue);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(rollbackBackupPath), isTrue);

      // 4. Create an independent plaintext database in sub2 to demonstrate _rollbackSwap under failure
      final dir2 = Directory(join(tempDir.path, 'sub2'))..createSync();
      final plainDb2Path = join(dir2.path, 'plain_source_2.db');
      final bkp2Path = join(dir2.path, 'plain_source_2.db.pre_migration_backup');
      final journal2Path = join(dir2.path, 'spendx_migration_state.json');

      // Create initial plaintext database at plainDb2Path
      final p2 = await openDatabase(
        plainDb2Path,
        version: 24,
        onCreate: (d, v) async {
          await Tables.createAll(d);
          await TablesV24.createAllV24(d);
          await TablesV24.seedSystemAccounts(d);
          await TablesV24.installTriggers(d);
          await d.execute('PRAGMA user_version = 24;');
        },
      );
      final accRepo2 = AccountRepo(executor: p2);
      await accRepo2.insertAccount(
        BankAccount(id: 'acc_p2', name: 'Plain Bank 2', bank: 'SBI', balance: 0.0),
      );
      await p2.close();

      // Make a pre-migration backup copy of it
      await File(plainDb2Path).copy(bkp2Path);

      // Migrate plainDb2Path to encrypted
      await service.runMigration(
        dbPath: plainDb2Path,
        keyOverride: keyABytes,
        keepBackupOnSuccess: true,
      );
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(plainDb2Path), isFalse);
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(bkp2Path), isTrue);

      // Now record journal2 as recoveryRequired with simulated cleanup error
      final journal2 = MigrationJournal(
        file: File(journal2Path),
        state: MigrationState.recoveryRequired,
        timestamp: DateTime.now().toUtc(),
        sourceDbPath: plainDb2Path,
        stagedDbPath: join(dir2.path, 'plain_source_2.db.migration_staging'),
        rollbackBackupPath: bkp2Path,
      );
      await journal2.record(MigrationState.recoveryRequired, err: 'I/O failure during deletion');

      // If recoverInterruptedMigration is called with unreadable/wrong key during recovery:
      // Hardened invariant: Refuses to overwrite with plaintext, throws MigrationCrashRecoveryException!
      final wrongKeyBytes = Uint8List(32);
      await expectLater(
        service.recoverInterruptedMigration(dbPath: plainDb2Path, keyOverride: wrongKeyBytes),
        throwsA(isA<MigrationCrashRecoveryException>()),
      );

      // Evidence: Live database remains encrypted SQLCipher, NEVER restored to plaintext!
      expect(File(plainDb2Path).existsSync(), isTrue);
      final isPlainNow = DatabaseEncryptionMigrationService.isPlaintextSqliteFile(plainDb2Path);
      expect(isPlainNow, isFalse, reason: 'Encrypted SQLCipher database was preserved and never overwritten with plaintext');

      // Now recover with the correct key: completes recovery and sweeps the stale backup
      await service.recoverInterruptedMigration(dbPath: plainDb2Path, keyOverride: keyABytes);
      expect(File(bkp2Path).existsSync(), isFalse, reason: 'Stale backup was cleaned up upon successful recovery');
      expect(File(journal2Path).existsSync(), isFalse, reason: 'Journal was cleared upon successful recovery');
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(plainDb2Path), isFalse);
    });
  });
}
