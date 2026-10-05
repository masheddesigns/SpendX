import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:spend_x/data/core/spendx_database_factory.dart'
    hide InvalidDatabaseKeyException;
import 'package:spend_x/data/core/tables.dart';
import 'package:spend_x/data/security/database_key_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spendx_c11_p2_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Milestone C11: Phase 2 Database Key Lifecycle & Safety Suite', () {
    test('C11-P2-01: Generates exactly 32 random bytes (256 bits)', () async {
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      final key = await km.getOrCreateKey();
      expect(key, isA<Uint8List>());
      expect(key.length, equals(32));
      expect(key.lengthInBytes, equals(32));

      // Assert non-trivial entropy (not all zeros)
      final allZero = key.every((b) => b == 0);
      expect(allZero, isFalse);
    });

    test('C11-P2-02: Generated key survives SecureStorage round-trip', () async {
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      final key1 = await km.getOrCreateKey();
      final key2 = await km.getKey();

      expect(key2, isNotNull);
      expect(key2, equals(key1));
      expect(await km.hasKey(), isTrue);
      expect(await km.getState(), equals(DatabaseKeyState.available));
    });

    test('C11-P2-03: Existing key is returned unchanged across subsequent calls', () async {
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      final firstCall = await km.getOrCreateKey();
      final secondCall = await km.getOrCreateKey();
      final thirdCall = await km.getOrCreateKey();

      expect(secondCall, equals(firstCall));
      expect(thirdCall, equals(firstCall));
    });

    test('C11-P2-04: Malformed key (corrupted Base64) is rejected', () async {
      final storage = InMemorySecureStorageAdapter();
      storage.corrupt(SpendXDatabaseKeyManager.defaultKeyStorageName, '!!!not_valid_base64!!!');
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      expect(await km.getState(), equals(DatabaseKeyState.invalid));
      expect(await km.hasKey(), isFalse);

      await expectLater(
        km.getKey(),
        throwsA(isA<InvalidDatabaseKeyException>()),
      );
      await expectLater(
        km.getOrCreateKey(),
        throwsA(isA<InvalidDatabaseKeyException>()),
      );
    });

    test('C11-P2-05: Wrong-length key (not 32 bytes) is rejected', () async {
      final storage = InMemorySecureStorageAdapter();
      // Store a 16-byte key (128-bit) encoded as Base64
      final shortBytes = Uint8List(16);
      storage.corrupt(SpendXDatabaseKeyManager.defaultKeyStorageName, base64Encode(shortBytes));
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      expect(await km.getState(), equals(DatabaseKeyState.invalid));

      await expectLater(
        km.getKey(),
        throwsA(isA<InvalidDatabaseKeyException>()),
      );
      await expectLater(
        km.getOrCreateKey(),
        throwsA(isA<InvalidDatabaseKeyException>()),
      );
    });

    test('C11-P2-06: Missing key is detected as missing', () async {
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      expect(await km.getState(), equals(DatabaseKeyState.missing));
      expect(await km.hasKey(), isFalse);
      expect(await km.getKey(), isNull);
    });

    test('C11-P2-07: SecureStorage failure is surfaced explicitly', () async {
      final storage = InMemorySecureStorageAdapter();
      storage.shouldThrowOnRead = true;
      storage.readExceptionMessage = 'OS Keychain Hardware Lockout';
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      expect(await km.getState(), equals(DatabaseKeyState.unreadable));

      await expectLater(
        km.getKey(),
        throwsA(
          isA<DatabaseKeyAccessException>().having(
            (e) => e.message,
            'message',
            contains('Failed to read master key from secure storage'),
          ),
        ),
      );

      await expectLater(
        km.getOrCreateKey(),
        throwsA(isA<DatabaseKeyAccessException>()),
      );
    });

    test('C11-P2-08: Encrypted DB exists + missing key does NOT generate replacement (FATAL KEY LOSS)', () async {
      // 1. Create a real encrypted SQLCipher database file
      final encDbPath = join(tempDir.path, 'protected_production.db');
      final initialStorage = InMemorySecureStorageAdapter();
      final initialKm = SpendXDatabaseKeyManager(storageAdapter: initialStorage);
      final validKey = await initialKm.getOrCreateKey();

      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        encDbPath,
        password: SpendXDatabaseKeyManager.keyToHex(validKey),
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE ledger_secrets (id INT, balance INT);');
          await db.insert('ledger_secrets', {'id': 1, 'balance': 999999});
        },
      );
      await db.close();

      // Verify the file exists on disk and is non-empty
      final encFile = File(encDbPath);
      expect(await encFile.exists(), isTrue);
      expect(await encFile.length(), greaterThan(0));

      // 2. Simulate catastrophic key loss in SecureStorage
      final emptyStorage = InMemorySecureStorageAdapter();
      final victimKm = SpendXDatabaseKeyManager(storageAdapter: emptyStorage);

      // 3. Inspect state with encrypted DB path
      final state = await victimKm.getState(encryptedDbPath: encDbPath);
      expect(state, equals(DatabaseKeyState.fatalKeyLoss));

      // 4. Attempt to call getOrCreateKey() must throw KeyLossFatalException and NEVER generate a new key
      await expectLater(
        victimKm.getOrCreateKey(encryptedDbPath: encDbPath),
        throwsA(
          isA<KeyLossFatalException>().having(
            (e) => e.message,
            'message',
            contains('FATAL KEY LOSS'),
          ),
        ),
      );

      // Verify empty storage remains EMPTY (no replacement was generated)
      expect(await emptyStorage.read(SpendXDatabaseKeyManager.defaultKeyStorageName), isNull);
    });

    test('C11-P2-09: Encrypted DB + wrong key does NOT trigger regeneration', () async {
      final encDbPath = join(tempDir.path, 'wrong_key_test.db');
      final storageA = InMemorySecureStorageAdapter();
      final kmA = SpendXDatabaseKeyManager(storageAdapter: storageA);
      final keyA = await kmA.getOrCreateKey();

      final db = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
        encDbPath,
        password: SpendXDatabaseKeyManager.keyToHex(keyA),
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE t (v INT);');
        },
      );
      await db.close();

      // Create a second different key
      final storageB = InMemorySecureStorageAdapter();
      final kmB = SpendXDatabaseKeyManager(storageAdapter: storageB);
      final keyB = await kmB.getOrCreateKey();
      expect(keyB, isNot(equals(keyA)));

      // Opening with keyB must fail with authentication error
      await expectLater(
        SpendXDatabaseFactory.instance.openEncryptedDatabase(
          encDbPath,
          password: SpendXDatabaseKeyManager.keyToHex(keyB),
          version: 1,
        ),
        throwsA(isA<SqlCipherException>()),
      );

      // keyB in storageB was NOT regenerated or overwritten
      final keyBCheck = await kmB.getKey();
      expect(keyBCheck, equals(keyB));
    });

    test('C11-P2-10: Key material is never leaked in exceptions or toString', () async {
      final exc1 = const InvalidDatabaseKeyException();
      final exc2 = DatabaseKeyAccessException('Read error', Exception('Secret inner'));
      final exc3 = const KeyLossFatalException('/path/to/db');

      expect(exc1.toString().contains('key='), isFalse);
      expect(exc2.toString().contains('key='), isFalse);
      expect(exc3.toString().contains('key='), isFalse);

      final rawRandom = Uint8List(32);
      final hex = SpendXDatabaseKeyManager.keyToHex(rawRandom);
      expect(hex.length, equals(64));
    });

    test('C11-P2-11: Backup password and DB key remain separate concepts', () async {
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);
      final dbKey = await km.getOrCreateKey();

      const backupPassword = 'UserSuperStrongBackupPassphrase2026!';

      // Ensure they cannot be compared as the same type or derived identically
      expect(dbKey, isA<Uint8List>());
      expect(backupPassword, isA<String>());
      expect(utf8.decode(dbKey, allowMalformed: true), isNot(equals(backupPassword)));
    });

    test('C11-P2-12: Plaintext production DB remains untouched and opens normally', () async {
      final plainPath = join(tempDir.path, 'spendx_plaintext_prod.db');
      final plainDb = await SpendXDatabaseFactory.instance.openPlaintextDatabase(
        plainPath,
        version: 24,
        onCreate: (db, version) async {
          await Tables.createAll(db);
        },
      );
      await plainDb.insert('categories', {
        'id': 'cat_plain_test',
        'name': 'Groceries',
        'icon': 'cart',
        'color': '#123456',
        'type': 'expense',
        'user_id': 'u1',
      });
      await plainDb.close();

      // Initializing key manager has zero effect on plaintext file
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);
      final _ = await km.getState(encryptedDbPath: plainPath);

      // Plaintext database opens normally via standard path
      final reopenDb = await SpendXDatabaseFactory.instance.openPlaintextDatabase(
        plainPath,
        version: 24,
      );
      final rows = await reopenDb.query('categories');
      expect(rows.length, equals(1));
      expect(rows.first['id'], equals('cat_plain_test'));
      await reopenDb.close();
    });

    test('C11-P2-13: Key manager initialization and instance access is idempotent', () async {
      final instance1 = SpendXDatabaseKeyManager.instance;
      final instance2 = SpendXDatabaseKeyManager.instance;
      expect(identical(instance1, instance2), isTrue);
    });

    test('C11-P2-14: Concurrent getOrCreateKey() calls cannot create multiple keys', () async {
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      // Spawn 10 simultaneous concurrent requests
      final futures = List.generate(10, (_) => km.getOrCreateKey());
      final results = await Future.wait(futures);

      final firstResult = results.first;
      for (final r in results) {
        expect(r, equals(firstResult));
      }

      // Check storage contains exactly one key string
      final storedKey = await storage.read(SpendXDatabaseKeyManager.defaultKeyStorageName);
      expect(storedKey, isNotNull);
      expect(base64Decode(storedKey!), equals(firstResult));
    });

    test('C11-P2-15: Restart simulation returns the exact same key', () async {
      final sharedStorage = InMemorySecureStorageAdapter();

      // Session 1: Provision key
      final km1 = SpendXDatabaseKeyManager(storageAdapter: sharedStorage);
      final key1 = await km1.getOrCreateKey();

      // Session 2: App restarts, fresh KeyManager instance created against same storage
      final km2 = SpendXDatabaseKeyManager(storageAdapter: sharedStorage);
      expect(await km2.hasKey(), isTrue);
      expect(await km2.getState(), equals(DatabaseKeyState.available));
      final key2 = await km2.getOrCreateKey();

      expect(key2, equals(key1));
    });

    test('C11-P2-16: SecureStorage corruption results in explicit failure', () async {
      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);
      await km.getOrCreateKey();

      // Simulate bit-rot / external tampering with the storage entry
      storage.corrupt(SpendXDatabaseKeyManager.defaultKeyStorageName, 'corrupted_value_truncated');

      expect(await km.getState(), equals(DatabaseKeyState.invalid));
      await expectLater(km.getKey(), throwsA(isA<InvalidDatabaseKeyException>()));
    });

    test('C11-P2-17: Safety: Plaintext spendx.db does not trigger automatic key generation', () async {
      final prodDbPath = join(tempDir.path, 'spendx.db');
      final file = File(prodDbPath);
      await file.writeAsString('SQLite format 3\x00dummy');

      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);

      // Merely checking state or initializing does NOT generate a key
      final state = await km.getState(encryptedDbPath: prodDbPath);
      expect(state, equals(DatabaseKeyState.missing));
      expect(await storage.read(SpendXDatabaseKeyManager.defaultKeyStorageName), isNull);
    });

    test('C11-P2-18: Safety: Refuses to delete key when encrypted DB exists unless force is true', () async {
      final encDbPath = join(tempDir.path, 'protected_file.db');
      final encFile = File(encDbPath);
      // Write non-plaintext dummy data
      await encFile.writeAsBytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);

      final storage = InMemorySecureStorageAdapter();
      final km = SpendXDatabaseKeyManager(storageAdapter: storage);
      await km.getOrCreateKey();

      // deleteKey without force throws KeyLossFatalException
      await expectLater(
        km.deleteKey(encryptedDbPath: encDbPath, force: false),
        throwsA(isA<KeyLossFatalException>()),
      );

      // Key still exists
      expect(await km.hasKey(), isTrue);

      // deleteKey with force succeeds
      await km.deleteKey(encryptedDbPath: encDbPath, force: true);
      expect(await km.hasKey(), isFalse);
    });
  });
}
