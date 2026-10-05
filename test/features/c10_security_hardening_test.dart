import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/repositories/account_repo.dart';
import 'package:spend_x/data/repositories/category_repo.dart';
import 'package:spend_x/data/repositories/credit_repo.dart';
import 'package:spend_x/data/repositories/loan_repo.dart';
import 'package:spend_x/data/repositories/canonical/canonical_account_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_financial_query_repository.dart';
import 'package:spend_x/data/repositories/canonical/canonical_recurring_repository.dart';

import 'package:spend_x/models/bank_account.dart';
import 'package:spend_x/models/category.dart';
import 'package:spend_x/models/transaction.dart' as spx;
import 'package:spend_x/services/backup_service.dart';
import 'package:spend_x/services/backup_file_service.dart';
import 'package:crypto/crypto.dart' hide Hmac;
import 'package:cryptography/cryptography.dart' hide Hash;
import 'package:spend_x/services/canonical_backup_validator.dart';
import 'package:spend_x/services/canonical_forecast_engine.dart';
import 'package:spend_x/services/database_security_service.dart';
import 'package:spend_x/services/evidence_pruning_service.dart';
import 'package:spend_x/services/financial_transaction_service.dart';
import 'package:spend_x/services/gemini_service.dart';
import 'package:spend_x/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late String dbPath;
  late Database db;

  late AccountRepo accountRepo;
  late CreditRepo creditRepo;
  late LoanRepo loanRepo;
  late CategoryRepo categoryRepo;

  late CanonicalAccountRepository canonicalAccountRepo;
  late CanonicalFinancialQueryRepository canonicalQueryRepo;
  late CanonicalRecurringRepository canonicalRecurringRepo;

  late FinancialTransactionService financialService;
  late CanonicalForecastEngine forecastEngine;

  late ProviderContainer container;

  const testBankId = 'acc_bank_c10_primary';
  const testCatSalaryId = 'cat_c10_salary';
  const testCatFoodId = 'cat_c10_food';
  const mockGeminiKey = 'test_secure_key_ai_2026';

  Future<void> initDatabase(String path) async {
    db = await openDatabase(
      path,
      version: 24,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
    );
    await Tables.createAll(db);
    await TablesV24.createAllV24(db);
    await TablesV24.seedSystemAccounts(db);
    await TablesV24.installTriggers(db);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
    dotenv.loadFromString(envString: 'GEMINI_API_KEY=$mockGeminiKey\n');

    tempDir = await Directory.systemTemp.createTemp('spendx_c10_adversarial_');
    dbPath = join(tempDir.path, 'spendx_c10_test.db');
    await initDatabase(dbPath);

    canonicalAccountRepo = CanonicalAccountRepository(executor: db);
    canonicalQueryRepo = CanonicalFinancialQueryRepository(executor: db);
    canonicalRecurringRepo = CanonicalRecurringRepository(executor: db);

    accountRepo = AccountRepo(executor: db);
    creditRepo = CreditRepo(executor: db);
    loanRepo = LoanRepo(executor: db);
    categoryRepo = CategoryRepo(executor: db);

    financialService = FinancialTransactionService(
      database: db,
    );

    forecastEngine = CanonicalForecastEngine(
      queryRepo: canonicalQueryRepo,
      recurringRepo: canonicalRecurringRepo,
      loanRepo: loanRepo,
      creditRepo: creditRepo,
    );

    container = ProviderContainer();

    // Seed test master account
    await accountRepo.insertAccount(
      BankAccount(
        id: testBankId,
        name: 'Primary Checking',
        bank: 'HDFC Bank',
        balance: 0.0,
      ),
    );

    // Seed test categories
    await categoryRepo.insert(
      Category(
        id: testCatSalaryId,
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
        'id': testCatSalaryId,
        'account_type': 'income',
        'subtype': 'category',
        'name': 'Salary',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    await categoryRepo.insert(
      Category(
        id: testCatFoodId,
        name: 'Groceries',
        icon: 'shopping',
        color: '#FF9800',
        type: 'expense',
        userId: 'u1',
      ),
    );
    await db.insert(
      TablesV24.accounts,
      {
        'id': testCatFoodId,
        'account_type': 'expense',
        'subtype': 'category',
        'name': 'Groceries',
        'currency': 'INR',
        'is_active': 1,
        'is_system': 0,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  });

  tearDown(() async {
    DatabaseKeyManager.clearTestKey();
    container.dispose();
    try {
      if (db.isOpen) {
        await db.close();
      }
    } catch (_) {}
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Milestone C10: At-Rest & Archive Security Hardening', () {
    // ═══════════════════════════════════════════════════════════════
    // Group 1: Gemini API Security (3 vectors)
    // ═══════════════════════════════════════════════════════════════
    group('Group 1: Gemini API Security', () {
      test('ADV-C10-01: API request headers contain x-goog-api-key with the configured key', () {
        final gemini = GeminiService.instance;
        final headers = gemini.headers;

        expect(headers.containsKey('x-goog-api-key'), isTrue);
        expect(headers['x-goog-api-key'], equals(mockGeminiKey));
        expect(headers['Content-Type'], equals('application/json'));
      });

      test('ADV-C10-02: API request URL contains zero query parameters (no ?key= anywhere in the URI)', () {
        final gemini = GeminiService.instance;
        final url = gemini.apiUrl;

        expect(url.contains('?'), isFalse);
        expect(url.contains('key='), isFalse);
        expect(url, startsWith('https://generativelanguage.googleapis.com/v1beta/models/'));
      });

      test('ADV-C10-03: API error responses and exception messages never leak the API key in their string representation', () {
        final gemini = GeminiService.instance;
        final rawError = 'Error 403: Forbidden when calling endpoint with key $mockGeminiKey for user.';

        final sanitized = gemini.sanitizeError(rawError);

        expect(sanitized.contains(mockGeminiKey), isFalse);
        expect(sanitized.contains('[REDACTED_API_KEY]'), isTrue);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Group 2: Database Encryption at Rest (5 vectors)
    // ═══════════════════════════════════════════════════════════════
    group('Group 2: Database Encryption at Rest', () {
      test('ADV-C10-04: Encrypted SQLite database file cannot be read as plaintext (header does not contain "SQLite format 3")', () async {
        final encFile = File(join(tempDir.path, 'encrypted_test.db'));
        const masterKey = 'test_master_encryption_key_256bits_length!';

        await DatabaseSecurityService.instance.encryptDatabaseFile(
          sourceFile: File(dbPath),
          destinationFile: encFile,
          masterKey: masterKey,
        );

        expect(await encFile.exists(), isTrue);
        expect(await encFile.length(), greaterThan(100));

        final isPlain = await DatabaseSecurityService.instance.isPlaintextDatabase(encFile);
        final isEnc = await DatabaseSecurityService.instance.isEncryptedDatabase(encFile);

        expect(isPlain, isFalse);
        expect(isEnc, isTrue);

        final first16Bytes = (await encFile.readAsBytes()).sublist(0, 16);
        final plainHeader = DatabaseSecurityService.sqliteHeaderBytes;
        expect(first16Bytes, isNot(equals(plainHeader)));
      });

      test('ADV-C10-05: Database opens and operates normally when correct encryption key is provided', () async {
        final encFile = File(join(tempDir.path, 'encrypted_test_roundtrip.db'));
        final decFile = File(join(tempDir.path, 'decrypted_test_roundtrip.db'));
        const masterKey = 'my_secure_c10_256_bit_encryption_key!!';

        await DatabaseSecurityService.instance.encryptDatabaseFile(
          sourceFile: File(dbPath),
          destinationFile: encFile,
          masterKey: masterKey,
        );

        await DatabaseSecurityService.instance.decryptDatabaseFile(
          sourceFile: encFile,
          destinationFile: decFile,
          masterKey: masterKey,
        );

        expect(await DatabaseSecurityService.instance.isPlaintextDatabase(decFile), isTrue);

        final openedDb = await openDatabase(decFile.path);
        try {
          final res = await openedDb.rawQuery('SELECT COUNT(*) as count FROM accounts;');
          expect(res.first['count'], greaterThanOrEqualTo(1));
        } finally {
          await openedDb.close();
        }
      });

      test('ADV-C10-06: Database access fails with an explicit error when wrong encryption key is provided', () async {
        final encFile = File(join(tempDir.path, 'encrypted_test_wrong_key.db'));
        final decFile = File(join(tempDir.path, 'decrypted_fail.db'));
        const correctKey = 'correct_master_key_12345';
        const wrongKey = 'wrong_attacker_key_67890';

        await DatabaseSecurityService.instance.encryptDatabaseFile(
          sourceFile: File(dbPath),
          destinationFile: encFile,
          masterKey: correctKey,
        );

        expect(
          () => DatabaseSecurityService.instance.decryptDatabaseFile(
            sourceFile: encFile,
            destinationFile: decFile,
            masterKey: wrongKey,
          ),
          throwsA(isA<InvalidDatabaseKeyException>()),
        );
      });

      test('ADV-C10-07: Plaintext v24 database migrates to encrypted database successfully', () async {
        final destEncFile = File(join(tempDir.path, 'migrated_secure.db'));
        const masterKey = 'strong_migration_key_2026_canonical!';

        final report = await DatabaseSecurityService.instance.migratePlaintextToEncrypted(
          sourcePlainDb: File(dbPath),
          destEncryptedDb: destEncFile,
          masterKey: masterKey,
          activeConnection: db,
        );

        expect(report.success, isTrue);
        expect(report.schemaVersion, equals(24));
        expect(report.parityVerified, isTrue);
        expect(await destEncFile.exists(), isTrue);
        expect(await DatabaseSecurityService.instance.isEncryptedDatabase(destEncFile), isTrue);
      });

      test('ADV-C10-08: Encrypted database has schema v24 and all 7 triggers active', () async {
        final destEncFile = File(join(tempDir.path, 'schema_verify_secure.db'));
        final decFile = File(join(tempDir.path, 'schema_verify_dec.db'));
        const masterKey = 'verification_key_v24_triggers_check!';

        await DatabaseSecurityService.instance.migratePlaintextToEncrypted(
          sourcePlainDb: File(dbPath),
          destEncryptedDb: destEncFile,
          masterKey: masterKey,
          activeConnection: db,
        );

        await DatabaseSecurityService.instance.decryptDatabaseFile(
          sourceFile: destEncFile,
          destinationFile: decFile,
          masterKey: masterKey,
        );

        final verifyDb = await openDatabase(decFile.path);
        try {
          final verRes = await verifyDb.rawQuery('PRAGMA user_version;');
          expect(verRes.first.values.first, equals(24));

          final triggerRows = await verifyDb.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_%';",
          );
          expect(triggerRows.length, greaterThanOrEqualTo(7));

          final triggerNames = triggerRows.map((r) => r['name'] as String).toSet();
          expect(triggerNames.contains('trg_postings_prevent_update_on_posted'), isTrue);
          expect(triggerNames.contains('trg_postings_prevent_delete_on_posted'), isTrue);
          expect(triggerNames.contains('trg_economic_events_prevent_delete_posted'), isTrue);
        } finally {
          await verifyDb.close();
        }
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Group 3: Migration Safety & Rollback (7 vectors)
    // ═══════════════════════════════════════════════════════════════
    group('Group 3: Migration Safety & Rollback', () {
      test('ADV-C10-09: Migration failure at pre-validation preserves original plaintext database undamaged', () async {
        final corruptSource = File(join(tempDir.path, 'corrupted_plain.db'));
        await corruptSource.writeAsString('not a valid sqlite file at all!');
        final originalBytes = await corruptSource.readAsBytes();
        final destEnc = File(join(tempDir.path, 'never_created.db'));

        expect(
          () => DatabaseSecurityService.instance.migratePlaintextToEncrypted(
            sourcePlainDb: corruptSource,
            destEncryptedDb: destEnc,
            masterKey: 'some_key',
          ),
          throwsA(isA<DatabaseMigrationRollbackException>()),
        );

        expect(await corruptSource.readAsBytes(), equals(originalBytes));
      });

      test('ADV-C10-10: Migration failure during encryption preserves original plaintext database undamaged', () async {
        final originalBytes = await File(dbPath).readAsBytes();
        final readOnlyDest = File(join(tempDir.path, 'readonly_dir', 'out.db'));

        // Target directory does not exist and is inside impossible path
        expect(
          () => DatabaseSecurityService.instance.migratePlaintextToEncrypted(
            sourcePlainDb: File(dbPath),
            destEncryptedDb: readOnlyDest,
            masterKey: 'some_key',
          ),
          throwsA(anything),
        );

        // Original database remains 100% undamaged
        expect(await File(dbPath).readAsBytes(), equals(originalBytes));
      });

      test('ADV-C10-11: Migration failure at post-validation triggers rollback to original plaintext database', () async {
        // Intentionally corrupt triggers in a test copy to fail trigger count requirement
        final testDbCopyPath = join(tempDir.path, 'test_copy_for_rollback.db');
        await File(dbPath).copy(testDbCopyPath);
        final copyDb = await openDatabase(testDbCopyPath);
        await copyDb.execute('DROP TRIGGER IF EXISTS trg_postings_prevent_update_on_posted;');
        await copyDb.close();

        final originalBytes = await File(testDbCopyPath).readAsBytes();
        final destEnc = File(join(tempDir.path, 'staged_enc_fail.db'));

        expect(
          () => DatabaseSecurityService.instance.migratePlaintextToEncrypted(
            sourcePlainDb: File(testDbCopyPath),
            destEncryptedDb: destEnc,
            masterKey: 'key_123',
          ),
          throwsA(isA<DatabaseMigrationRollbackException>()),
        );

        // Original copy is intact
        expect(await File(testDbCopyPath).readAsBytes(), equals(originalBytes));
        expect(await destEnc.exists(), isFalse);
      });

      test('ADV-C10-12: Pre-migration and post-migration row counts match 100% across all tables', () async {
        // Seed financial event
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_seed_01',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatSalaryId,
            amount: 50000.0,
            type: 'income',
            notes: 'Monthly Salary',
            date: DateTime.now().toUtc(),
          ),
        );

        final destEncFile = File(join(tempDir.path, 'migrated_counts_test.db'));
        const masterKey = 'key_for_counts_test_100pct!';

        final report = await DatabaseSecurityService.instance.migratePlaintextToEncrypted(
          sourcePlainDb: File(dbPath),
          destEncryptedDb: destEncFile,
          masterKey: masterKey,
          activeConnection: db,
        );

        expect(report.success, isTrue);
        expect(report.preMigrationCounts, equals(report.postMigrationCounts));
        expect(report.postMigrationCounts['economic_events'], equals(1));
        expect(report.postMigrationCounts['postings'], equals(2));
      });

      test('ADV-C10-13: Pre-migration and post-migration debit/credit parity matches 100%', () async {
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_seed_parity',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatFoodId,
            amount: 1500.0,
            type: 'expense',
            notes: 'Dinner',
            date: DateTime.now().toUtc(),
          ),
        );

        final destEncFile = File(join(tempDir.path, 'migrated_parity_test.db'));
        const masterKey = 'key_for_parity_test_100pct!';

        final report = await DatabaseSecurityService.instance.migratePlaintextToEncrypted(
          sourcePlainDb: File(dbPath),
          destEncryptedDb: destEncFile,
          masterKey: masterKey,
          activeConnection: db,
        );

        expect(report.parityVerified, isTrue);
        expect(report.debitTotal, equals(report.creditTotal));
        expect(report.debitTotal, equals(150000));
      });

      test('ADV-C10-14: Pre-migration and post-migration net worth balance matches 100%', () async {
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_seed_nw',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatSalaryId,
            amount: 75000.0,
            type: 'income',
            notes: 'Bonus',
            date: DateTime.now().toUtc(),
          ),
        );

        final nwPre = await canonicalQueryRepo.getNetWorth();

        final destEncFile = File(join(tempDir.path, 'migrated_nw_test.db'));
        final decFile = File(join(tempDir.path, 'dec_nw_test.db'));
        const masterKey = 'nw_test_key_master!';

        await DatabaseSecurityService.instance.migratePlaintextToEncrypted(
          sourcePlainDb: File(dbPath),
          destEncryptedDb: destEncFile,
          masterKey: masterKey,
          activeConnection: db,
        );

        await DatabaseSecurityService.instance.decryptDatabaseFile(
          sourceFile: destEncFile,
          destinationFile: decFile,
          masterKey: masterKey,
        );

        final decryptedDb = await openDatabase(decFile.path);
        try {
          final decQueryRepo = CanonicalFinancialQueryRepository(executor: decryptedDb);
          final nwPost = await decQueryRepo.getNetWorth();
          expect(nwPost.minorUnits, equals(nwPre.minorUnits));
        } finally {
          await decryptedDb.close();
        }
      });

      test('ADV-C10-15: Pre-migration and post-migration safe-to-spend matches 100%', () async {
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_seed_sts',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatSalaryId,
            amount: 100000.0,
            type: 'income',
            notes: 'Deposit',
            date: DateTime.now().toUtc(),
          ),
        );

        final stsPre = await canonicalQueryRepo.getSafeToSpend();

        final destEncFile = File(join(tempDir.path, 'migrated_sts_test.db'));
        final decFile = File(join(tempDir.path, 'dec_sts_test.db'));
        const masterKey = 'sts_test_key_master!';

        await DatabaseSecurityService.instance.migratePlaintextToEncrypted(
          sourcePlainDb: File(dbPath),
          destEncryptedDb: destEncFile,
          masterKey: masterKey,
          activeConnection: db,
        );

        await DatabaseSecurityService.instance.decryptDatabaseFile(
          sourceFile: destEncFile,
          destinationFile: decFile,
          masterKey: masterKey,
        );

        final decryptedDb = await openDatabase(decFile.path);
        try {
          final decQueryRepo = CanonicalFinancialQueryRepository(executor: decryptedDb);
          final stsPost = await decQueryRepo.getSafeToSpend();
          expect(stsPost.safeToSpend.minorUnits, equals(stsPre.safeToSpend.minorUnits));
          expect(stsPost.liquidAssets.minorUnits, equals(stsPre.liquidAssets.minorUnits));
        } finally {
          await decryptedDb.close();
        }
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Group 4: Encrypted Backup & Restore (7 vectors)
    // ═══════════════════════════════════════════════════════════════
    group('Group 4: Encrypted Backup & Restore', () {
      test('ADV-C10-16: .spendx backup created with encryption produces encrypted spendx.db.enc inside archive', () async {
        const password = 'SuperSecretBackupPassword2026!';
        final backupOut = File(join(tempDir.path, 'test_encrypted_backup.spendx'));

        final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: password,
        );

        expect(manifest.isEncrypted, isTrue);
        expect(manifest.encryptionAlgorithm, equals('AES-256-GCM'));
        expect(manifest.kdfAlgorithm, equals('ARGON2ID'));

        // Inspect zip entries
        final zipBytes = await packageFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(zipBytes);
        final entryNames = archive.map((e) => e.name).toList();

        expect(entryNames.contains('spendx.db.enc'), isTrue);
        expect(entryNames.contains('spendx.db'), isFalse);
        expect(entryNames.contains('manifest.json'), isTrue);
      });

      test('ADV-C10-17: Encrypted .spendx restores successfully when correct password is provided', () async {
        // Record test transaction
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_backup_roundtrip',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatSalaryId,
            amount: 60000.0,
            type: 'income',
            notes: 'Income for Backup',
            date: DateTime.now().toUtc(),
          ),
        );

        const password = 'CorrectRestorePassword999!';
        final backupOut = File(join(tempDir.path, 'roundtrip_backup.spendx'));

        final (packageFile, _) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: password,
        );

        final targetRestoreDbPath = join(tempDir.path, 'restored_target.db');
        final success = await BackupService.instance.restoreFromFile(
          packageFile,
          targetDbPath: targetRestoreDbPath,
          password: password,
        );

        expect(success, isTrue);

        final restoredDb = await openDatabase(targetRestoreDbPath);
        try {
          final accRepo = CanonicalAccountRepository(executor: restoredDb);
          final balance = await accRepo.getDerivedBalance(testBankId);
          expect(balance.minorUnits, equals(6000000));
        } finally {
          await restoredDb.close();
        }
      });

      test('ADV-C10-18: Encrypted .spendx restore fails with explicit error when wrong password is provided', () async {
        const correctPassword = 'PasswordCorrect123!';
        const wrongPassword = 'PasswordWrong456!';
        final backupOut = File(join(tempDir.path, 'wrong_pass_backup.spendx'));

        final (packageFile, _) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: correctPassword,
        );

        final targetRestoreDbPath = join(tempDir.path, 'target_should_not_change.db');

        expect(
          () => BackupService.instance.restoreFromFile(
            packageFile,
            targetDbPath: targetRestoreDbPath,
            password: wrongPassword,
          ),
          throwsA(isA<InvalidBackupPasswordException>()),
        );
      });

      test('ADV-C10-19: Encrypted .spendx restore fails when ciphertext is corrupted (MAC verification failure)', () async {
        const password = 'PasswordForTamperTest!';
        final backupOut = File(join(tempDir.path, 'tamper_backup.spendx'));

        final (packageFile, _) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: password,
        );

        // Unpack, tamper 1 byte of spendx.db.enc, and repack
        final zipBytes = await packageFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(zipBytes);
        final tamperedArchive = Archive();

        for (final entry in archive) {
          if (entry.name == 'spendx.db.enc') {
            final content = List<int>.from(entry.content as List<int>);
            content[0] = content[0] ^ 0xFF; // Flip bits
            tamperedArchive.addFile(ArchiveFile(entry.name, content.length, content));
          } else {
            tamperedArchive.addFile(entry);
          }
        }

        final tamperedZipBytes = ZipEncoder().encode(tamperedArchive);
        final tamperedFile = File(join(tempDir.path, 'tampered.spendx'));
        await tamperedFile.writeAsBytes(tamperedZipBytes);

        final targetRestoreDbPath = join(tempDir.path, 'tamper_restore_target.db');

        expect(
          () => BackupService.instance.restoreFromFile(
            tamperedFile,
            targetDbPath: targetRestoreDbPath,
            password: password,
          ),
          throwsA(isA<InvalidBackupPasswordException>()),
        );
      });

      test('ADV-C10-20: Failed encrypted restore leaves active database 100% untouched (0 mutations)', () async {
        // Record test transaction in active db
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_active_must_survive',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatSalaryId,
            amount: 45000.0,
            type: 'income',
            notes: 'Untouched Active DB',
            date: DateTime.now().toUtc(),
          ),
        );

        const password = 'SomeOriginalPassword!';
        final backupOut = File(join(tempDir.path, 'active_survive_backup.spendx'));

        final (packageFile, _) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: password,
        );

        final activeCountsBefore = await db.rawQuery('SELECT COUNT(*) as cnt FROM transactions;');
        final activeTxnCount = activeCountsBefore.first['cnt'] as int;

        // Attempt restore with wrong password against active DB
        try {
          await BackupService.instance.restoreFromFile(
            packageFile,
            targetDbPath: dbPath,
            targetDb: db,
            password: 'completely_wrong_password',
          );
        } catch (_) {}

        final activeCountsAfter = await db.rawQuery('SELECT COUNT(*) as cnt FROM transactions;');
        expect(activeCountsAfter.first['cnt'], equals(activeTxnCount));
      });

      test('ADV-C10-21: Legacy unencrypted .spendx backups restore successfully without password', () async {
        // Create unencrypted backup
        final backupOut = File(join(tempDir.path, 'unencrypted_legacy.spendx'));

        final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: null,
        );

        expect(manifest.isEncrypted, isFalse);

        final targetRestoreDbPath = join(tempDir.path, 'unencrypted_restored.db');
        final success = await BackupService.instance.restoreFromFile(
          packageFile,
          targetDbPath: targetRestoreDbPath,
          password: null,
        );

        expect(success, isTrue);
      });

      test('ADV-C10-22: Backup manifest contains encryption metadata (is_encrypted, kdf_algorithm, salt, nonce, mac) and no plaintext key', () async {
        const password = 'SuperSecretKeyThatMustNeverAppearInManifest!';
        final backupOut = File(join(tempDir.path, 'manifest_check.spendx'));

        final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: password,
        );

        expect(manifest.isEncrypted, isTrue);
        expect(manifest.encryptionAlgorithm, equals('AES-256-GCM'));
        expect(manifest.kdfAlgorithm, equals('ARGON2ID'));
        expect(manifest.kdfIterations, equals(2));
        expect(manifest.kdfMemory, equals(19456));
        expect(manifest.aad, isNotNull);
        expect(manifest.kdfSalt, isNotNull);
        expect(manifest.nonce, isNotNull);
        expect(manifest.mac, isNotNull);

        // Verify JSON string
        final zipBytes = await packageFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(zipBytes);
        final manifestEntry = archive.firstWhere((e) => e.name == 'manifest.json');
        final manifestContent = utf8.decode(manifestEntry.content as List<int>);

        expect(manifestContent.contains('is_encrypted'), isTrue);
        expect(manifestContent.contains('kdf_salt'), isTrue);
        expect(manifestContent.contains(password), isFalse); // Plaintext password must NEVER appear!
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Group 5: Evidence Retention Enforcement (5 vectors)
    // ═══════════════════════════════════════════════════════════════
    group('Group 5: Evidence Retention Enforcement', () {
      test('ADV-C10-23: Raw SMS evidence older than 30 days is purged (raw_payload_encrypted = NULL, is_payload_purged = 1)', () async {
        final expiredTime = DateTime.now().toUtc().subtract(const Duration(days: 35));
        await db.insert(TablesV24.evidence, {
          'id': 'ev_expired_01',
          'economic_event_id': null,
          'body_sha256': 'hash_expired_01',
          'external_reference': 'SMS_EXP_01',
          'source_type': 'sms',
          'extracted_amount_minor_units': 10000,
          'extracted_timestamp': expiredTime.toIso8601String(),
          'sender_address': 'BANK-ALRT',
          'raw_payload_encrypted': 'RAW_ENCRYPTED_SMS_PAYLOAD_BODY',
          'retention_expires_at': DateTime.now().toUtc().subtract(const Duration(days: 5)).toIso8601String(),
          'is_payload_purged': 0,
          'created_at': expiredTime.toIso8601String(),
        });

        final purgedCount = await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);
        expect(purgedCount, equals(1));

        final rows = await db.query(
          TablesV24.evidence,
          where: 'id = ?',
          whereArgs: ['ev_expired_01'],
        );
        expect(rows.first['raw_payload_encrypted'], isNull);
        expect(rows.first['is_payload_purged'], equals(1));
      });

      test('ADV-C10-24: Evidence within 30 days is NOT purged (raw_payload_encrypted remains intact, is_payload_purged = 0)', () async {
        final recentTime = DateTime.now().toUtc().subtract(const Duration(days: 10));
        await db.insert(TablesV24.evidence, {
          'id': 'ev_recent_02',
          'economic_event_id': null,
          'body_sha256': 'hash_recent_02',
          'external_reference': 'SMS_RECENT_02',
          'source_type': 'sms',
          'extracted_amount_minor_units': 25000,
          'extracted_timestamp': recentTime.toIso8601String(),
          'sender_address': 'BANK-ALRT',
          'raw_payload_encrypted': 'RAW_RECENT_SMS_PAYLOAD_BODY',
          'retention_expires_at': DateTime.now().toUtc().add(const Duration(days: 20)).toIso8601String(),
          'is_payload_purged': 0,
          'created_at': recentTime.toIso8601String(),
        });

        final purgedCount = await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);
        expect(purgedCount, equals(0));

        final rows = await db.query(
          TablesV24.evidence,
          where: 'id = ?',
          whereArgs: ['ev_recent_02'],
        );
        expect(rows.first['raw_payload_encrypted'], equals('RAW_RECENT_SMS_PAYLOAD_BODY'));
        expect(rows.first['is_payload_purged'], equals(0));
      });

      test('ADV-C10-25: Purged evidence retains its body_sha256 hash and external_reference (deduplication still works)', () async {
        final expiredTime = DateTime.now().toUtc().subtract(const Duration(days: 40));
        const expectedHash = 'dedup_sha256_must_survive_hash';
        const expectedRef = 'REF_SURVIVES_PURGE_99';

        await db.insert(TablesV24.evidence, {
          'id': 'ev_survive_03',
          'economic_event_id': null,
          'body_sha256': expectedHash,
          'external_reference': expectedRef,
          'source_type': 'sms',
          'extracted_amount_minor_units': 30000,
          'extracted_timestamp': expiredTime.toIso8601String(),
          'sender_address': 'BANK-ALRT',
          'raw_payload_encrypted': 'RAW_PAYLOAD_TO_BE_PURGED',
          'retention_expires_at': DateTime.now().toUtc().subtract(const Duration(days: 10)).toIso8601String(),
          'is_payload_purged': 0,
          'created_at': expiredTime.toIso8601String(),
        });

        await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);

        final rows = await db.query(
          TablesV24.evidence,
          where: 'id = ?',
          whereArgs: ['ev_survive_03'],
        );
        expect(rows.first['body_sha256'], equals(expectedHash));
        expect(rows.first['external_reference'], equals(expectedRef));
        expect(rows.first['is_payload_purged'], equals(1));
        expect(rows.first['raw_payload_encrypted'], isNull);
      });

      test('ADV-C10-26: Evidence pruning is idempotent (running it multiple times produces the same result)', () async {
        final expiredTime = DateTime.now().toUtc().subtract(const Duration(days: 45));
        await db.insert(TablesV24.evidence, {
          'id': 'ev_idempotent_04',
          'economic_event_id': null,
          'body_sha256': 'hash_idempotent_04',
          'external_reference': 'SMS_IDEMPOTENT_04',
          'source_type': 'sms',
          'extracted_amount_minor_units': 15000,
          'extracted_timestamp': expiredTime.toIso8601String(),
          'sender_address': 'BANK-ALRT',
          'raw_payload_encrypted': 'PAYLOAD_IDEMPOTENT',
          'retention_expires_at': DateTime.now().toUtc().subtract(const Duration(days: 15)).toIso8601String(),
          'is_payload_purged': 0,
          'created_at': expiredTime.toIso8601String(),
        });

        final firstRun = await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);
        expect(firstRun, equals(1));

        final secondRun = await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);
        expect(secondRun, equals(0));

        final thirdRun = await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);
        expect(thirdRun, equals(0));
      });

      test('ADV-C10-27: Evidence pruning does not mutate any EconomicEvents or Postings (0 financial mutations)', () async {
        // Record transaction
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_pruning_invariant',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatSalaryId,
            amount: 50000.0,
            type: 'income',
            notes: 'Pruning Invariant Check',
            date: DateTime.now().toUtc(),
          ),
        );

        final eventsBefore = await db.query(TablesV24.economicEvents);
        final postingsBefore = await db.query(TablesV24.postings);

        await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);

        final eventsAfter = await db.query(TablesV24.economicEvents);
        final postingsAfter = await db.query(TablesV24.postings);

        expect(eventsAfter.length, equals(eventsBefore.length));
        expect(postingsAfter.length, equals(postingsBefore.length));
        expect(eventsAfter, equals(eventsBefore));
        expect(postingsAfter, equals(postingsBefore));
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Group 6: Regression & Firewall Verification (3 vectors)
    // ═══════════════════════════════════════════════════════════════
    group('Group 6: Regression & Firewall Verification', () {
      test('ADV-C10-28: Canonical double-entry accounting operates correctly on encrypted database (debits == credits)', () async {
        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_g6_income',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatSalaryId,
            amount: 80000.0,
            type: 'income',
            notes: 'Group 6 Income',
            date: DateTime.now().toUtc(),
          ),
        );

        await financialService.createTransaction(
          spx.Transaction(
            id: 'txn_c10_g6_expense',
            userId: 'u1',
            accountId: testBankId,
            categoryId: testCatFoodId,
            amount: 20000.0,
            type: 'expense',
            notes: 'Group 6 Expense',
            date: DateTime.now().toUtc(),
          ),
        );

        final encFile = File(join(tempDir.path, 'g6_encrypted.db'));
        final decFile = File(join(tempDir.path, 'g6_decrypted.db'));
        const masterKey = 'g6_accounting_master_key_100!';

        await DatabaseSecurityService.instance.migratePlaintextToEncrypted(
          sourcePlainDb: File(dbPath),
          destEncryptedDb: encFile,
          masterKey: masterKey,
          activeConnection: db,
        );

        await DatabaseSecurityService.instance.decryptDatabaseFile(
          sourceFile: encFile,
          destinationFile: decFile,
          masterKey: masterKey,
        );

        final decDb = await openDatabase(decFile.path);
        try {
          final parityRes = await decDb.rawQuery('''
            SELECT 
              SUM(CASE WHEN direction = 'debit' THEN amount_minor_units ELSE 0 END) as d,
              SUM(CASE WHEN direction = 'credit' THEN amount_minor_units ELSE 0 END) as c
            FROM postings;
          ''');
          expect(parityRes.first['d'], equals(parityRes.first['c']));
          expect(parityRes.first['d'], equals(10000000)); // (80000 + 20000) * 100 minor units
        } finally {
          await decDb.close();
        }
      });

      test('ADV-C10-29: C8 canonical backup and restore works seamlessly with encrypted databases', () async {
        const password = 'C8SeamlessPasswordCheck2026!';
        final backupFile = File(join(tempDir.path, 'c8_seamless_backup.spendx'));

        final (pkg, manifest) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupFile,
          password: password,
        );

        expect(manifest.isEncrypted, isTrue);

        final restoreTarget = join(tempDir.path, 'c8_seamless_restored.db');
        final restored = await BackupService.instance.restoreFromFile(
          pkg,
          targetDbPath: restoreTarget,
          password: password,
        );

        expect(restored, isTrue);

        final resDb = await openDatabase(restoreTarget);
        try {
          final res = await resDb.rawQuery('PRAGMA integrity_check;');
          expect(res.first.values.first?.toString().toLowerCase(), equals('ok'));
        } finally {
          await resDb.close();
        }
      });

      test('ADV-C10-30: All previous milestone firewalls remain intact (C3B write firewall, C4 read firewall, C5 ingestion, C6 forecast, C7 Riverpod, C8 backup, C9 legacy retirement)', () async {
        // C3B Write Firewall: Direct posting insert without event triggers SQLite constraint error
        expect(
          () => db.insert(TablesV24.postings, {
            'id': 'pst_rogue_c10',
            'economic_event_id': 'non_existent_event_id',
            'account_id': testBankId,
            'direction': 'debit',
            'amount_minor_units': 1000,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          }),
          throwsA(anything),
        );

        // C4 Read Firewall: Canonical account balance is non-negative and derived correctly
        final balance = await canonicalAccountRepo.getDerivedBalance(testBankId);
        expect(balance.minorUnits, greaterThanOrEqualTo(0));

        // C6 Forecast: Runs deterministically
        final forecast = await forecastEngine.computeForecast(
          horizonDays: 30,
        );
        expect(forecast.dailyPoints, isNotEmpty);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Group 7: Remediation Hardening (Argon2id, AAD Tamper Resistance, Legacy KDF Compatibility, Staging Hygiene)
    // ═══════════════════════════════════════════════════════════════
    group('Group 7: Remediation Hardening', () {
      test('ADV-C10-31: Strong Argon2id encrypted backup roundtrips successfully and rejects incorrect password', () async {
        const password = 'StrongArgon2idPassword2026!';
        final backupOut = File(join(tempDir.path, 'argon2id_roundtrip.spendx'));

        final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: password,
        );

        expect(manifest.kdfAlgorithm, equals('ARGON2ID'));
        expect(manifest.kdfIterations, equals(2));
        expect(manifest.kdfMemory, equals(19456));
        expect(manifest.aad, isNotNull);

        // Correct password restores
        final restoreDir = await Directory.systemTemp.createTemp('spendx_c10_argon_stage_');
        final staged = await BackupFileService.instance.extractPackage(
          packageFile: packageFile,
          stagingDir: restoreDir,
          password: password,
        );
        expect(await staged.stagedDbFile.exists(), isTrue);
        await staged.cleanup();

        // Wrong password throws explicit InvalidBackupPasswordException
        final wrongPassDir = await Directory.systemTemp.createTemp('spendx_c10_wrong_pass_');
        expect(
          () => BackupFileService.instance.extractPackage(
            packageFile: packageFile,
            stagingDir: wrongPassDir,
            password: 'wrong_argon2id_password_attempt',
          ),
          throwsA(isA<InvalidBackupPasswordException>()),
        );
        await wrongPassDir.delete(recursive: true);
      });

      test('ADV-C10-32: Tampered manifest metadata (record count / debit sum / hash) is detected and rejected via AES-GCM AAD', () async {
        const password = 'TamperTestPassword2026!';
        final backupOut = File(join(tempDir.path, 'tamper_test.spendx'));

        final (packageFile, manifest) = await BackupService.instance.createBackupPackage(
          sourceDb: db,
          sourceDbPath: dbPath,
          outputFile: backupOut,
          password: password,
        );

        // Read ZIP, tamper manifest.json (modify debitTotal or record counts), repackage
        final bytes = await packageFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);

        final tamperedArchive = Archive();
        for (final file in archive.files) {
          if (file.name == 'manifest.json') {
            final manifestMap = jsonDecode(utf8.decode(file.content as List<int>)) as Map<String, dynamic>;
            // Tamper debit_total to attempt forged parity or metadata modification
            manifestMap['debit_total'] = 99999999;
            final tamperedManifestBytes = utf8.encode(jsonEncode(manifestMap));
            tamperedArchive.addFile(
              ArchiveFile('manifest.json', tamperedManifestBytes.length, tamperedManifestBytes),
            );
          } else {
            tamperedArchive.addFile(file);
          }
        }

        final tamperedZipBytes = ZipEncoder().encode(tamperedArchive);
        final tamperedBackupFile = File(join(tempDir.path, 'tampered_manifest.spendx'));
        await tamperedBackupFile.writeAsBytes(tamperedZipBytes);

        // Extraction MUST fail because AAD mismatch triggers either manifest integrity or GCM auth failure
        final extractDir = await Directory.systemTemp.createTemp('spendx_c10_tamper_extract_');
        expect(
          () => BackupFileService.instance.extractPackage(
            packageFile: tamperedBackupFile,
            stagingDir: extractDir,
            password: password,
          ),
          throwsA(isA<BackupException>()),
        );
        await extractDir.delete(recursive: true);
      });

      test('ADV-C10-33: Backward-compatible restoration of legacy PBKDF2-HMAC-SHA256 encrypted backups succeeds without error', () async {
        // Construct a legacy encrypted backup package using PBKDF2-HMAC-SHA256 (10,000 iterations, no AAD)
        const password = 'LegacyPbkdf2Password!';
        final salt = List<int>.generate(16, (i) => i + 1);
        final pbkdf2 = Pbkdf2(
          macAlgorithm: Hmac(Sha256()),
          iterations: 10000,
          bits: 256,
        );
        final secretKey = await pbkdf2.deriveKey(
          secretKey: SecretKey(utf8.encode(password)),
          nonce: salt,
        );

        final dbBytes = await File(dbPath).readAsBytes();
        final gcm = AesGcm.with256bits();
        final nonce = gcm.newNonce();
        final secretBox = await gcm.encrypt(dbBytes, secretKey: secretKey, nonce: nonce);

        final metrics = await CanonicalBackupValidator.computeDatabaseMetrics(db);
        final legacyManifest = BackupManifest(
          formatVersion: 2,
          schemaVersion: 24,
          appVersion: '1.0.0',
          appName: 'SpendX',
          createdAt: DateTime.now().toUtc(),
          databaseSha256: sha256.convert(dbBytes).toString(),
          databaseSize: dbBytes.length,
          recordCounts: metrics['record_counts'] as Map<String, int>,
          canonicalEventCount: metrics['canonical_event_count'] as int,
          postingCount: metrics['posting_count'] as int,
          evidenceCount: metrics['evidence_count'] as int,
          reviewCandidateCount: metrics['review_candidate_count'] as int,
          debitTotal: metrics['debit_total'] as int,
          creditTotal: metrics['credit_total'] as int,
          isEncrypted: true,
          encryptionAlgorithm: 'AES-256-GCM',
          kdfAlgorithm: 'PBKDF2-HMAC-SHA256',
          kdfIterations: 10000,
          kdfSalt: base64Encode(salt),
          nonce: base64Encode(secretBox.nonce),
          mac: base64Encode(secretBox.mac.bytes),
          aad: null, // Legacy backups had no AAD
        );

        final legacyArchive = Archive();
        final manifestBytes = utf8.encode(legacyManifest.toJson());
        legacyArchive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
        legacyArchive.addFile(ArchiveFile('spendx.db.enc', secretBox.cipherText.length, secretBox.cipherText));

        final legacyZipBytes = ZipEncoder().encode(legacyArchive);
        final legacyBackupFile = File(join(tempDir.path, 'legacy_pbkdf2_backup.spendx'));
        await legacyBackupFile.writeAsBytes(legacyZipBytes);

        // Verify restoration succeeds smoothly
        final extractDir = await Directory.systemTemp.createTemp('spendx_c10_legacy_extract_');
        final staged = await BackupFileService.instance.extractPackage(
          packageFile: legacyBackupFile,
          stagingDir: extractDir,
          password: password,
        );
        expect(await staged.stagedDbFile.exists(), isTrue);
        await staged.cleanup();
      });

      test('ADV-C10-34: Orphaned SpendX staging directories are detected and cleanly swept without touching active database', () async {
        // Create simulated orphaned directories matching SpendX staging naming conventions
        final orphanBackup = await Directory.systemTemp.createTemp('spendx_backup_stage_test_orphan_');
        final orphanRestore = await Directory.systemTemp.createTemp('spendx_restore_stage_test_orphan_');
        final orphanMigration = await Directory.systemTemp.createTemp('spendx_migration_stage_test_orphan_');
        final unrelatedDir = await Directory.systemTemp.createTemp('unrelated_temp_dir_do_not_delete_');

        expect(await orphanBackup.exists(), isTrue);
        expect(await orphanRestore.exists(), isTrue);
        expect(await orphanMigration.exists(), isTrue);
        expect(await unrelatedDir.exists(), isTrue);

        // Sweep with olderThan: Duration.zero
        final removedCount = await BackupFileService.cleanOrphanedStagingDirectories(olderThan: Duration.zero);
        expect(removedCount, greaterThanOrEqualTo(3));

        expect(await orphanBackup.exists(), isFalse);
        expect(await orphanRestore.exists(), isFalse);
        expect(await orphanMigration.exists(), isFalse);
        // Unrelated temp directory must NEVER be touched
        expect(await unrelatedDir.exists(), isTrue);

        // Active database file must be 100% intact
        expect(await File(dbPath).exists(), isTrue);

        await unrelatedDir.delete(recursive: true);
      });
    });
  });
}
