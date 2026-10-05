import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:spend_x/data/core/app_database.dart';
import 'package:spend_x/data/core/spendx_database_factory.dart';
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/security/database_key_manager.dart';
import 'package:spend_x/data/security/database_encryption_migration_service.dart';
import 'package:spend_x/domain/finance/finance.dart';
import 'package:spend_x/models/review_item.dart';
import 'package:spend_x/services/evidence_pruning_service.dart';
import 'package:spend_x/data/repositories/canonical/canonical_event_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late InMemorySecureStorageAdapter mockStorage;
  late SpendXDatabaseKeyManager keyManager;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('spendx_c12_p1_test_');
    mockStorage = InMemorySecureStorageAdapter();
    keyManager = SpendXDatabaseKeyManager(storageAdapter: mockStorage);
    SpendXDatabaseKeyManager.setTestInstance(keyManager);
    await SpendXDatabaseFactory.instance.initialize();
    AppDatabase.autoMigrateLegacyPlaintext = true;
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.setTestDatabasePath(null);
    SpendXDatabaseKeyManager.setTestInstance(null);
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('C12-P1: Database Startup & Default Encryption Enforcement', () {
    test('P1.1 — Fresh database is encrypted from day one with zero plaintext creation', () async {
      final dbName = 'fresh_encrypted_test.db';
      final dbPath = p.join(tempDir.path, dbName);
      AppDatabase.setTestDatabasePath(dbPath);

      // Startup fresh database through AppDatabase
      final db = await AppDatabase.instance.database;
      expect(db.isOpen, isTrue);

      // 1. Verify schema version is 24
      final verRows = await db.rawQuery('PRAGMA user_version;');
      expect(verRows.first.values.first, equals(24));

      // 2. Verify all 7 triggers installed
      final triggerRows = await db.rawQuery(
        "SELECT count(*) as cnt FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_%';",
      );
      expect(triggerRows.first['cnt'], equals(7));

      // 3. Verify system accounts seeded
      final accounts = await db.query(TablesV24.accounts);
      expect(accounts.length, greaterThanOrEqualTo(9));

      // Close to check on-disk structure
      await AppDatabase.instance.close();

      final dbFile = File(dbPath);
      expect(await dbFile.exists(), isTrue);
      expect(await dbFile.length(), greaterThan(0));

      // 4. Invariant: PLAINTEXT_FRESH_DATABASE_CREATION = 0
      final isPlaintext = DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath);
      expect(isPlaintext, isFalse, reason: 'Fresh database must NOT be plaintext SQLite');

      // 5. Raw SQLite fails to read file
      final rawDb = await databaseFactoryFfi.openDatabase(dbPath, options: OpenDatabaseOptions(singleInstance: false));
      expect(
        () async => await rawDb.rawQuery('SELECT count(*) FROM sqlite_master;'),
        throwsA(anything),
        reason: 'Raw SQLite opening without SQLCipher key must fail with file is not a database',
      );
      await rawDb.close();

      // 6. SQLCipher with correct key successfully opens it
      final key = await keyManager.getKey();
      expect(key, isNotNull);
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key!);
      final encDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        dbPath,
        password: blobKey,
        singleInstance: false,
      );
      final checkRows = await encDb.rawQuery('SELECT count(*) FROM sqlite_master;');
      expect(checkRows.first.values.first, greaterThan(0));
      await encDb.close();
    });

    test('P1.2 — Existing plaintext database automatically migrates to SQLCipher during startup', () async {
      final dbName = 'legacy_migration_startup_test.db';
      final dbPath = p.join(tempDir.path, dbName);

      // Seed a valid plaintext v24 database
      final plainDb = await databaseFactoryFfi.openDatabase(
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

      // Capture pre-migration fingerprint
      final preFingerprint = await AccountingFingerprint.fromDatabase(plainDb);
      expect(preFingerprint.schemaVersion, equals(24));
      expect(preFingerprint.activeTriggersCount, equals(7));
      await plainDb.close();

      // Assert it is currently plaintext
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isTrue);

      // Startup via AppDatabase — should trigger automatic migration
      AppDatabase.setTestDatabasePath(dbPath);
      final appDb = await AppDatabase.instance.database;
      expect(appDb.isOpen, isTrue);

      // Capture post-migration fingerprint
      final postFingerprint = await AccountingFingerprint.fromDatabase(appDb);
      expect(postFingerprint.matches(preFingerprint), isTrue,
          reason: 'Auto-migrated database must preserve exact accounting fingerprint');

      await AppDatabase.instance.close();

      // Verify file is now encrypted SQLCipher
      expect(DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath), isFalse);

      // Reopening normally via AppDatabase works seamlessly
      final reopenedDb = await AppDatabase.instance.database;
      expect(reopenedDb.isOpen, isTrue);
      final countRows = await reopenedDb.rawQuery('SELECT count(*) FROM accounts;');
      expect(countRows.first.values.first, equals(preFingerprint.accountCount));
      await AppDatabase.instance.close();
    });

    test('P1.3 — Concurrency Mutex: Parallel calls to AppDatabase.database serialize safely', () async {
      final dbName = 'concurrency_startup_test.db';
      final dbPath = p.join(tempDir.path, dbName);
      AppDatabase.setTestDatabasePath(dbPath);

      // Launch 10 simultaneous calls to AppDatabase.instance.database
      final futures = List.generate(10, (_) => AppDatabase.instance.database);
      final databases = await Future.wait(futures);

      expect(databases.length, equals(10));
      final primary = databases.first;
      expect(primary.isOpen, isTrue);

      // All 10 concurrent requests must resolve to the identical Database instance
      for (int i = 1; i < databases.length; i++) {
        expect(identical(databases[i], primary), isTrue,
            reason: 'Caller $i must receive the exact same singleton instance');
      }

      await AppDatabase.instance.close();
    });

    test('P1.4 — Missing Key Fatal Protection: Prohibits silent key regeneration or wipe', () async {
      final dbName = 'missing_key_fatal_test.db';
      final dbPath = p.join(tempDir.path, dbName);
      AppDatabase.setTestDatabasePath(dbPath);

      // 1. Create encrypted database
      final db = await AppDatabase.instance.database;
      expect(db.isOpen, isTrue);
      await AppDatabase.instance.close();

      final originalSize = await File(dbPath).length();
      expect(originalSize, greaterThan(0));

      // 2. Erase master key from storage to simulate catastrophic key loss
      await mockStorage.delete(SpendXDatabaseKeyManager.defaultKeyStorageName);
      expect(await mockStorage.containsKey(SpendXDatabaseKeyManager.defaultKeyStorageName), isFalse);

      // 3. Attempting startup must FATALLY THROW KeyLossFatalException
      AppDatabase.setTestDatabasePath(dbPath);
      expect(
        AppDatabase.instance.database,
        throwsA(isA<KeyLossFatalException>()),
        reason: 'AppDatabase startup must prohibit silent key regeneration if encrypted DB exists',
      );

      // 4. Assert on-disk database was NEVER wiped or replaced
      final currentSize = await File(dbPath).length();
      expect(currentSize, equals(originalSize), reason: 'User database file must remain untouched');
    });

    test('P1.5 — Canonical UTC Timestamp Standardization & Retention Pruning Consistency', () async {
      final dbName = 'utc_timestamp_test.db';
      final dbPath = p.join(tempDir.path, dbName);
      AppDatabase.setTestDatabasePath(dbPath);

      final db = await AppDatabase.instance.database;
      final eventRepo = CanonicalEventRepository(executor: db);

      // Create Evidence with UTC timestamps
      final nowUtc = DateTime.now().toUtc();
      final expiredUtc = nowUtc.subtract(const Duration(days: 35));

      final evExpired = Evidence(
        id: 'ev_utc_expired',
        sourceType: 'sms',
        sourceIdentifier: 'BANK-ALERT',
        sourceTimestamp: expiredUtc,
        bodyFingerprint: 'sha256_expired_utc',
        extractedAmount: Money.fromRupees(1500),
        rawPayloadEncrypted: 'RAW_EXPIRED_PAYLOAD_TEXT',
        retentionExpiresAt: expiredUtc.add(const Duration(days: 30)), // Expired 5 days ago
        isPayloadPurged: false,
        createdAt: expiredUtc,
      );

      final evActive = Evidence(
        id: 'ev_utc_active',
        sourceType: 'sms',
        sourceIdentifier: 'BANK-ALERT',
        sourceTimestamp: nowUtc,
        bodyFingerprint: 'sha256_active_utc',
        extractedAmount: Money.fromRupees(2500),
        rawPayloadEncrypted: 'RAW_ACTIVE_PAYLOAD_TEXT',
        retentionExpiresAt: nowUtc.add(const Duration(days: 30)), // Active for 30 days
        isPayloadPurged: false,
        createdAt: nowUtc,
      );

      await eventRepo.insertEvidence(evExpired);
      await eventRepo.insertEvidence(evActive);

      // Verify persisted timestamps end in 'Z'
      final rows = await db.query(TablesV24.evidence);
      for (final row in rows) {
        final retention = row['retention_expires_at'] as String;
        expect(retention.endsWith('Z'), isTrue, reason: 'Retention timestamp must end in Z for UTC: $retention');
      }

      // Execute pruning service
      final purgedCount = await EvidencePruningService.instance.pruneExpiredEvidence(executor: db);
      expect(purgedCount, equals(1));

      final expiredRow = (await db.query(TablesV24.evidence, where: "id = 'ev_utc_expired'")).first;
      expect(expiredRow['raw_payload_encrypted'], isNull);
      expect(expiredRow['is_payload_purged'], equals(1));

      final activeRow = (await db.query(TablesV24.evidence, where: "id = 'ev_utc_active'")).first;
      expect(activeRow['raw_payload_encrypted'], equals('RAW_ACTIVE_PAYLOAD_TEXT'));
      expect(activeRow['is_payload_purged'], equals(0));

      // Test ReviewItem UTC serialization
      final review = ReviewItem(
        rawSource: 'test_sms',
        parsed: ParsedTransaction(
          amount: 500,
          isCredit: false,
          rawText: 'test_sms',
          date: nowUtc,
          confidence: 0.9,
        ),
        confidence: 0.9,
      );
      final reviewMap = review.toMap();
      expect((reviewMap['created_at'] as String).endsWith('Z'), isTrue);
    });

    test('P1.6 — Financial Log Scrubbing: Sensitive amounts and card numbers are not printed to stdout', () async {
      // Static invariant check: ensure no raw print statements leaking financial details
      final smsImportFile = File('lib/services/sms_import_service.dart');
      final liveSmsFile = File('lib/services/live_sms_service.dart');

      final smsImportContent = await smsImportFile.readAsString();
      final liveSmsContent = await liveSmsFile.readAsString();

      // Assert no print calls leaking last4 or amount
      expect(smsImportContent.contains("print('[SmsScan] balance hit:"), isFalse,
          reason: 'Balance hits with last4/amount must not be printed to stdout');
      expect(liveSmsContent.contains("print('[LiveSms] _autoRegisterCards:"), isFalse,
          reason: 'Card details must not be printed to stdout');
      expect(liveSmsContent.contains("print('[LiveSms] _autoRegisterLoans:"), isFalse,
          reason: 'Loan details must not be printed to stdout');
    });
  });
}
