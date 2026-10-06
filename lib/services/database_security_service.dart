import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../core/logging/app_logger.dart';

/// Exceptions for database security and encryption operations.
class DatabaseSecurityException implements Exception {
  final String message;
  const DatabaseSecurityException(this.message);

  @override
  String toString() => 'DatabaseSecurityException: $message';
}

class InvalidDatabaseKeyException extends DatabaseSecurityException {
  const InvalidDatabaseKeyException([super.message = 'Invalid or incorrect database master key.']);
}

class DatabaseDecryptionException extends DatabaseSecurityException {
  const DatabaseDecryptionException([super.message = 'Failed to decrypt database: corrupted ciphertext or authentication failure.']);
}

class DatabaseMigrationRollbackException extends DatabaseSecurityException {
  const DatabaseMigrationRollbackException(super.message);
}

/// Manages the 256-bit master encryption key for database container sealing and migration.
class DatabaseKeyManager {
  DatabaseKeyManager._();
  static final DatabaseKeyManager instance = DatabaseKeyManager._();

  static const String keyStorageName = 'spendx_database_master_key';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      migrateOnAlgorithmChange: false,
    ),
  );
  String? _inMemoryTestKey;

  /// Test hook to inject or override the master key.
  static void setTestKey(String? key) {
    instance._inMemoryTestKey = key;
  }

  /// Clears any in-memory test key.
  static void clearTestKey() {
    instance._inMemoryTestKey = null;
  }

  /// Returns the master key, generating and securely persisting one if none exists.
  Future<String> getOrCreateMasterKey() async {
    if (_inMemoryTestKey != null) {
      return _inMemoryTestKey!;
    }

    try {
      final existingKey = await _storage.read(key: keyStorageName);
      if (existingKey != null && existingKey.isNotEmpty) {
        return existingKey;
      }

      // Generate a cryptographically secure 256-bit (32-byte) key
      final random = Random.secure();
      final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
      final generatedHex = keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      await _storage.write(key: keyStorageName, value: generatedHex);
      return generatedHex;
    } catch (e) {
      AppLogger.w('[DB_SECURITY] Secure storage unavailable, using ephemeral key: $e');
      _inMemoryTestKey ??= _generateSecureHexKey();
      return _inMemoryTestKey!;
    }
  }

  /// Explicitly deletes the master key from secure storage.
  Future<void> deleteMasterKey() async {
    _inMemoryTestKey = null;
    try {
      await _storage.delete(key: keyStorageName);
    } catch (_) {}
  }

  String _generateSecureHexKey() {
    final random = Random.secure();
    final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
    return keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Audit report generated during fail-safe plaintext -> encrypted migration.
class DatabaseMigrationReport {
  final bool success;
  final int schemaVersion;
  final int activeTriggersCount;
  final Map<String, int> preMigrationCounts;
  final Map<String, int> postMigrationCounts;
  final int debitTotal;
  final int creditTotal;
  final bool parityVerified;
  final String durationMs;

  const DatabaseMigrationReport({
    required this.success,
    required this.schemaVersion,
    required this.activeTriggersCount,
    required this.preMigrationCounts,
    required this.postMigrationCounts,
    required this.debitTotal,
    required this.creditTotal,
    required this.parityVerified,
    required this.durationMs,
  });

  Map<String, dynamic> toMap() => {
        'success': success,
        'schema_version': schemaVersion,
        'active_triggers_count': activeTriggersCount,
        'pre_migration_counts': preMigrationCounts,
        'post_migration_counts': postMigrationCounts,
        'debit_total': debitTotal,
        'credit_total': creditTotal,
        'parity_verified': parityVerified,
        'duration_ms': durationMs,
      };
}

/// DatabaseSecurityService — Provides authenticated AES-256-GCM container-level
/// database encryption, header inspection, and transactional fail-safe migration routines
/// for database sealing and export.
///
/// NOTE: This implements file-level container encryption (archive/sealing), NOT transparent
/// SQLite pager-level runtime encryption (such as SQLCipher). The active runtime database
/// resides on disk as an OS sandbox-isolated SQLite file during normal application execution.
@Deprecated(
  'Superseded by SQLCipher page-level runtime encryption in C11. '
  'Retained solely for C10 regression test compatibility.',
)
class DatabaseSecurityService {
  DatabaseSecurityService._();
  static final DatabaseSecurityService instance = DatabaseSecurityService._();

  /// Standard SQLite 3 unencrypted header: 'SQLite format 3\000' (16 bytes)
  static const List<int> sqliteHeaderBytes = [
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
  ];

  /// SpendX Encrypted Database Header: 'SPNDXENC\x01' (9 bytes)
  static const List<int> magicEncHeader = [
    0x53, 0x50, 0x4e, 0x44, 0x58, 0x45, 0x4e, 0x43, 0x01,
  ];

  /// Checks if [file] exists and begins with the unencrypted SQLite format 3 header.
  Future<bool> isPlaintextDatabase(File file) async {
    if (!await file.exists() || await file.length() < 16) {
      return false;
    }
    final raf = await file.open(mode: FileMode.read);
    try {
      final header = await raf.read(16);
      if (header.length < 16) return false;
      for (int i = 0; i < 16; i++) {
        if (header[i] != sqliteHeaderBytes[i]) return false;
      }
      return true;
    } finally {
      await raf.close();
    }
  }

  /// Checks if [file] is an encrypted database (non-empty and not plaintext SQLite).
  Future<bool> isEncryptedDatabase(File file) async {
    if (!await file.exists() || await file.length() == 0) {
      return false;
    }
    return !await isPlaintextDatabase(file);
  }

  /// Encrypts a plaintext SQLite database file using authenticated AES-256-GCM.
  ///
  /// Output format:
  /// [magicEncHeader (9 bytes)]
  /// [salt (16 bytes)]
  /// [nonce (12 bytes)]
  /// [mac tag (16 bytes)]
  /// [ciphertext (N bytes)]
  Future<void> encryptDatabaseFile({
    required File sourceFile,
    required File destinationFile,
    required String masterKey,
  }) async {
    if (!await sourceFile.exists()) {
      throw DatabaseSecurityException('Source database does not exist: ${sourceFile.path}');
    }

    final isPlain = await isPlaintextDatabase(sourceFile);
    if (!isPlain) {
      throw const DatabaseSecurityException(
        'Source database is not a valid plaintext SQLite database.',
      );
    }

    final plainBytes = await sourceFile.readAsBytes();

    // 1. Derive 256-bit key using PBKDF2-HMAC-SHA256
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac(Sha256()),
      iterations: 10000,
      bits: 256,
    );

    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(masterKey)),
      nonce: salt,
    );

    // 2. Encrypt with AES-256-GCM
    final gcm = AesGcm.with256bits();
    final nonce = gcm.newNonce();
    final secretBox = await gcm.encrypt(
      plainBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    // 3. Write binary container
    final builder = BytesBuilder(copy: false)
      ..add(magicEncHeader)
      ..add(salt)
      ..add(nonce)
      ..add(secretBox.mac.bytes)
      ..add(secretBox.cipherText);

    if (await destinationFile.exists()) {
      await destinationFile.delete();
    }
    await destinationFile.writeAsBytes(builder.takeBytes(), flush: true);
    AppLogger.d('[DB_SECURITY] Database encrypted successfully (${destinationFile.lengthSync()} bytes)');
  }

  /// Decrypts an encrypted database file into plaintext SQLite format.
  ///
  /// Throws [InvalidDatabaseKeyException] or [DatabaseDecryptionException] on failure.
  Future<void> decryptDatabaseFile({
    required File sourceFile,
    required File destinationFile,
    required String masterKey,
  }) async {
    if (!await sourceFile.exists() || await sourceFile.length() < 53) {
      throw const DatabaseDecryptionException(
        'Encrypted database file is missing or truncated.',
      );
    }

    final encBytes = await sourceFile.readAsBytes();

    // Verify magic header
    for (int i = 0; i < magicEncHeader.length; i++) {
      if (encBytes[i] != magicEncHeader[i]) {
        throw const DatabaseDecryptionException(
          'Corrupted database: invalid encrypted container header.',
        );
      }
    }

    int offset = magicEncHeader.length;
    final salt = encBytes.sublist(offset, offset + 16);
    offset += 16;
    final nonce = encBytes.sublist(offset, offset + 12);
    offset += 12;
    final macBytes = encBytes.sublist(offset, offset + 16);
    offset += 16;
    final cipherBytes = encBytes.sublist(offset);

    try {
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac(Sha256()),
        iterations: 10000,
        bits: 256,
      );

      final secretKey = await pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(masterKey)),
        nonce: salt,
      );

      final secretBox = SecretBox(
        cipherBytes,
        nonce: nonce,
        mac: Mac(macBytes),
      );

      final gcm = AesGcm.with256bits();
      final decryptedBytes = await gcm.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      // Verify that decrypted bytes start with SQLite format 3
      if (decryptedBytes.length < 16) {
        throw const DatabaseDecryptionException('Decrypted payload is too short for SQLite.');
      }
      for (int i = 0; i < 16; i++) {
        if (decryptedBytes[i] != sqliteHeaderBytes[i]) {
          throw const InvalidDatabaseKeyException('Decrypted payload does not form valid SQLite format 3.');
        }
      }

      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }
      await destinationFile.writeAsBytes(decryptedBytes, flush: true);
      AppLogger.d('[DB_SECURITY] Database decrypted successfully (${destinationFile.lengthSync()} bytes)');
    } catch (e) {
      if (e is DatabaseSecurityException) rethrow;
      throw const InvalidDatabaseKeyException(
        'Decryption authentication failed. Master key is incorrect or database file has been corrupted.',
      );
    }
  }

  /// Executes fail-safe transactional migration from a plaintext v24 database
  /// to an encrypted database file with complete validation and automatic rollback.
  Future<DatabaseMigrationReport> migratePlaintextToEncrypted({
    required File sourcePlainDb,
    required File destEncryptedDb,
    required String masterKey,
    Database? activeConnection,
  }) async {
    final stopwatch = Stopwatch()..start();
    AppLogger.d('[DB_SECURITY] Starting fail-safe plaintext -> encrypted database migration...');

    // 1. Pre-flight check
    if (!await sourcePlainDb.exists()) {
      throw DatabaseMigrationRollbackException(
        'Source plaintext database does not exist: ${sourcePlainDb.path}',
      );
    }
    if (!await isPlaintextDatabase(sourcePlainDb)) {
      throw const DatabaseMigrationRollbackException(
        'Source file is not a valid plaintext SQLite database.',
      );
    }

    final tempDir = await Directory.systemTemp.createTemp('spendx_migration_stage_');
    final stagedEncFile = File('${tempDir.path}/staged_encrypted.db');
    final stagedVerificationPlainDb = File('${tempDir.path}/staged_verified.db');

    // 2. Pre-migration metrics and integrity audit on source plaintext database
    Map<String, int> preCounts = {};
    int preDebitTotal = 0;
    int preCreditTotal = 0;
    int triggerCount = 0;

    final Database plainDb = await openDatabase(
      sourcePlainDb.path,
      readOnly: true,
    );

    try {
      // PRAGMA integrity_check
      final integrity = await plainDb.rawQuery('PRAGMA integrity_check;');
      final integrityResult = integrity.first.values.first?.toString().toLowerCase();
      if (integrityResult != 'ok') {
        throw DatabaseMigrationRollbackException(
          'Source plaintext database failed integrity check: $integrityResult',
        );
      }

      // PRAGMA foreign_key_check
      final fkViolations = await plainDb.rawQuery('PRAGMA foreign_key_check;');
      if (fkViolations.isNotEmpty) {
        throw DatabaseMigrationRollbackException(
          'Source plaintext database has ${fkViolations.length} foreign key violations.',
        );
      }

      // Verify Schema v24
      final verRows = await plainDb.rawQuery('PRAGMA user_version;');
      final version = verRows.first.values.first as int? ?? 0;
      if (version != 24) {
        throw DatabaseMigrationRollbackException(
          'Source database schema version is $version, expected 24.',
        );
      }

      // Verify Triggers (all 7 required)
      final triggerRows = await plainDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_%';",
      );
      triggerCount = triggerRows.length;
      if (triggerCount < 7) {
        throw DatabaseMigrationRollbackException(
          'Source database triggers missing. Expected >= 7, found $triggerCount.',
        );
      }

      // Parity and row counts
      preCounts = await _collectRowCounts(plainDb);
      final (debit, credit) = await _computeDoubleEntryParity(plainDb);
      preDebitTotal = debit;
      preCreditTotal = credit;

      if (debit != credit) {
        throw DatabaseMigrationRollbackException(
          'Source database double-entry parity violation: DEBIT ($debit) != CREDIT ($credit).',
        );
      }
    } finally {
      await plainDb.close();
    }

    try {
      // 3. Encrypt into staging file
      await encryptDatabaseFile(
        sourceFile: sourcePlainDb,
        destinationFile: stagedEncFile,
        masterKey: masterKey,
      );

      // 4. Decrypt staged file into verification database
      await decryptDatabaseFile(
        sourceFile: stagedEncFile,
        destinationFile: stagedVerificationPlainDb,
        masterKey: masterKey,
      );

      // 5. Post-migration validation on the decrypted staged copy
      final Database verifyDb = await openDatabase(
        stagedVerificationPlainDb.path,
        readOnly: true,
      );

      try {
        final verifyIntegrity = await verifyDb.rawQuery('PRAGMA integrity_check;');
        if (verifyIntegrity.first.values.first?.toString().toLowerCase() != 'ok') {
          throw const DatabaseMigrationRollbackException(
            'Staged encrypted database verification failed integrity check.',
          );
        }

        final verifyFk = await verifyDb.rawQuery('PRAGMA foreign_key_check;');
        if (verifyFk.isNotEmpty) {
          throw DatabaseMigrationRollbackException(
            'Staged database has ${verifyFk.length} foreign key violations.',
          );
        }

        final postCounts = await _collectRowCounts(verifyDb);
        for (final entry in preCounts.entries) {
          final postCount = postCounts[entry.key] ?? 0;
          if (postCount != entry.value) {
            throw DatabaseMigrationRollbackException(
              'Row count mismatch for table ${entry.key}: pre=${entry.value}, post=$postCount',
            );
          }
        }

        final (postDebit, postCredit) = await _computeDoubleEntryParity(verifyDb);
        if (postDebit != preDebitTotal || postCredit != preCreditTotal) {
          throw DatabaseMigrationRollbackException(
            'Financial parity mismatch after encryption: pre=($preDebitTotal/$preCreditTotal), post=($postDebit/$postCredit)',
          );
        }
      } finally {
        await verifyDb.close();
      }

      // 6. Adversarial verification: opening stagedEncFile with incorrect key must fail
      final fakeKeyVerificationFile = File('${tempDir.path}/fake_key_test.db');
      bool wrongKeyRejected = false;
      try {
        await decryptDatabaseFile(
          sourceFile: stagedEncFile,
          destinationFile: fakeKeyVerificationFile,
          masterKey: 'wrong_password_attack_vector',
        );
      } catch (e) {
        if (e is DatabaseSecurityException) {
          wrongKeyRejected = true;
        }
      }
      if (!wrongKeyRejected) {
        throw const DatabaseMigrationRollbackException(
          'Security check failed: encrypted database accepted an invalid master key!',
        );
      }

      // 7. Atomic promotion
      if (activeConnection != null && activeConnection.isOpen) {
        try {
          await activeConnection.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
        } catch (_) {}
      }

      if (await destEncryptedDb.exists()) {
        await destEncryptedDb.delete();
      }
      await stagedEncFile.copy(destEncryptedDb.path);

      stopwatch.stop();
      AppLogger.d('[DB_SECURITY] Migration completed successfully in ${stopwatch.elapsedMilliseconds}ms');

      return DatabaseMigrationReport(
        success: true,
        schemaVersion: 24,
        activeTriggersCount: triggerCount,
        preMigrationCounts: preCounts,
        postMigrationCounts: preCounts,
        debitTotal: preDebitTotal,
        creditTotal: preCreditTotal,
        parityVerified: true,
        durationMs: '${stopwatch.elapsedMilliseconds}ms',
      );
    } catch (e) {
      AppLogger.e('[DB_SECURITY] Migration encountered error, ensuring original DB remains untouched: $e');
      // If destination encrypted db was partially written, delete it
      if (await destEncryptedDb.exists() && destEncryptedDb.path != sourcePlainDb.path) {
        await destEncryptedDb.delete();
      }
      rethrow;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<Map<String, int>> _collectRowCounts(Database db) async {
    final Map<String, int> counts = {};
    final tables = [
      'accounts',
      'transactions',
      'economic_events',
      'postings',
      'evidence',
      'review_candidates',
      'reconciliation_records',
      'recurring_rules',
      'expected_events',
      'system_accounts',
    ];

    for (final table in tables) {
      try {
        final res = await db.rawQuery('SELECT COUNT(*) as cnt FROM $table;');
        counts[table] = (res.first['cnt'] as int?) ?? 0;
      } catch (_) {
        counts[table] = 0;
      }
    }
    return counts;
  }

  Future<(int, int)> _computeDoubleEntryParity(Database db) async {
    final res = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN LOWER(direction) = 'debit' THEN amount_minor_units ELSE 0 END), 0) as debits,
        COALESCE(SUM(CASE WHEN LOWER(direction) = 'credit' THEN amount_minor_units ELSE 0 END), 0) as credits
      FROM postings;
    ''');
    final debits = (res.first['debits'] as int?) ?? 0;
    final credits = (res.first['credits'] as int?) ?? 0;
    return (debits, credits);
  }
}
