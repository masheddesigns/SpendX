import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' hide Hmac;
import 'package:cryptography/cryptography.dart';

import '../core/logging/app_logger.dart';
import 'canonical_backup_validator.dart';

/// BackupFileService — packages and unpackages canonical SpendX `.spendx` backup archives.
///
/// Archive Structure (.spendx - Encrypted):
/// ├── manifest.json     (Metadata, format version, salt, nonce, MAC tag, SHA-256)
/// └── spendx.db.enc     (AES-256-GCM authenticated ciphertext of SQLite snapshot)
///
/// Archive Structure (.spendx - Legacy Unencrypted):
/// ├── manifest.json     (Metadata, schema version, record counts, parity check, SHA-256)
/// └── spendx.db         (Plaintext SQLite snapshot)
class BackupFileService {
  BackupFileService._();
  static final BackupFileService instance = BackupFileService._();

  static const String backupFileName = 'spendx_backup.spendx';
  static const String legacyFileName = 'spendx_backup.json';
  static const String dbEntryName = 'spendx.db';
  static const String dbEncEntryName = 'spendx.db.enc';
  static const String manifestEntryName = 'manifest.json';

  static const String defaultKdfAlgorithm = 'ARGON2ID';
  static const int defaultArgon2Iterations = 2;
  static const int defaultArgon2Memory = 19456; // 19 MiB in KiB (OWASP recommendation)
  static const int defaultArgon2Parallelism = 1;
  static const int currentKdfVersion = 2;

  /// Builds a deterministic canonical string containing security-critical manifest fields
  /// to authenticate via AES-GCM Additional Authenticated Data (AAD).
  static String buildAadString(BackupManifest manifest, {String? saltBase64}) {
    final salt = saltBase64 ?? manifest.kdfSalt ?? '';
    final kdf = manifest.kdfAlgorithm ?? defaultKdfAlgorithm;
    return 'fmt=${manifest.formatVersion};schema=${manifest.schemaVersion};sha256=${manifest.databaseSha256};events=${manifest.canonicalEventCount};postings=${manifest.postingCount};debits=${manifest.debitTotal};credits=${manifest.creditTotal};kdf=$kdf;salt=$salt';
  }

  /// Creates a canonical `.spendx` package containing the database snapshot and manifest.
  /// If [password] is provided and non-empty, encrypts the database using AES-256-GCM.
  Future<(File, BackupManifest)> createPackage({
    required File dbFile,
    required BackupManifest manifest,
    required File outputFile,
    String? password,
  }) async {
    _log('Packaging .spendx container (encrypted: ${password != null && password.isNotEmpty})...');
    if (!await dbFile.exists()) {
      throw BackupValidationException(
        'Database snapshot file does not exist: ${dbFile.path}',
      );
    }

    final archive = Archive();
    final dbBytes = await dbFile.readAsBytes();

    BackupManifest finalManifest = manifest;
    if (password != null && password.isNotEmpty) {
      // ── Authenticated AES-256-GCM Encryption with Argon2id KDF ──
      final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      final saltBase64 = base64Encode(salt);

      final argon2id = Argon2id(
        parallelism: defaultArgon2Parallelism,
        memory: defaultArgon2Memory,
        iterations: defaultArgon2Iterations,
        hashLength: 32,
      );

      final secretKey = await argon2id.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );

      final aadStr = buildAadString(manifest, saltBase64: saltBase64);
      final aadBytes = utf8.encode(aadStr);

      final gcm = AesGcm.with256bits();
      final nonce = gcm.newNonce();
      final secretBox = await gcm.encrypt(
        dbBytes,
        secretKey: secretKey,
        nonce: nonce,
        aad: aadBytes,
      );

      final encManifest = BackupManifest(
        formatVersion: manifest.formatVersion,
        schemaVersion: manifest.schemaVersion,
        appVersion: manifest.appVersion,
        appName: manifest.appName,
        createdAt: manifest.createdAt,
        databaseSha256: manifest.databaseSha256,
        databaseSize: manifest.databaseSize,
        recordCounts: manifest.recordCounts,
        canonicalEventCount: manifest.canonicalEventCount,
        postingCount: manifest.postingCount,
        evidenceCount: manifest.evidenceCount,
        reviewCandidateCount: manifest.reviewCandidateCount,
        debitTotal: manifest.debitTotal,
        creditTotal: manifest.creditTotal,
        deviceId: manifest.deviceId,
        settings: manifest.settings,
        isEncrypted: true,
        encryptionAlgorithm: 'AES-256-GCM',
        kdfAlgorithm: defaultKdfAlgorithm,
        kdfIterations: defaultArgon2Iterations,
        kdfMemory: defaultArgon2Memory,
        kdfParallelism: defaultArgon2Parallelism,
        kdfVersion: currentKdfVersion,
        kdfSalt: saltBase64,
        nonce: base64Encode(secretBox.nonce),
        mac: base64Encode(secretBox.mac.bytes),
        aad: aadStr,
      );
      finalManifest = encManifest;

      // 1. Add manifest
      final manifestBytes = utf8.encode(encManifest.toJson());
      archive.addFile(
        ArchiveFile(manifestEntryName, manifestBytes.length, manifestBytes),
      );

      // 2. Add encrypted ciphertext
      archive.addFile(
        ArchiveFile(dbEncEntryName, secretBox.cipherText.length, secretBox.cipherText),
      );
    } else {
      // ── Unencrypted Package (Legacy / User-Opted) ──
      final manifestBytes = utf8.encode(manifest.toJson());
      archive.addFile(
        ArchiveFile(manifestEntryName, manifestBytes.length, manifestBytes),
      );
      archive.addFile(
        ArchiveFile(dbEntryName, dbBytes.length, dbBytes),
      );
    }

    // Encode to ZIP
    final encoder = ZipEncoder();
    final zipBytes = encoder.encode(archive);

    if (await outputFile.exists()) {
      await outputFile.delete();
    } else if (!await outputFile.parent.exists()) {
      await outputFile.parent.create(recursive: true);
    }

    await outputFile.writeAsBytes(zipBytes, flush: true);
    _log('Packaging complete: ${outputFile.path} (${zipBytes.length} bytes)');
    return (outputFile, finalManifest);
  }

  /// Extracts and validates package integrity to an isolated staging directory.
  Future<StagedBackup> extractPackage({
    required File packageFile,
    required Directory stagingDir,
    String? password,
  }) async {
    _log('Extracting package from ${packageFile.path}...');
    if (!await packageFile.exists()) {
      throw BackupValidationException(
        'Backup package does not exist: ${packageFile.path}',
      );
    }

    final bytes = await packageFile.readAsBytes();
    if (bytes.isEmpty) {
      throw const BackupValidationException('Backup package is empty (0 bytes)');
    }

    // Check if user passed a legacy JSON file
    if (bytes.isNotEmpty && (bytes[0] == 0x7B || bytes[0] == 0x5B)) {
      try {
        final text = utf8.decode(bytes);
        final decoded = jsonDecode(text);
        if (decoded is Map && (decoded['version'] == 1 || decoded.containsKey('transactions'))) {
          throw const UnsupportedBackupVersionException(
            'Legacy Version 1 backup detected. Cannot restore directly into canonical schema v24.',
          );
        }
      } catch (inner) {
        if (inner is UnsupportedBackupVersionException) rethrow;
      }
    }

    // Try decoding archive
    Archive archive;
    try {
      final decoder = ZipDecoder();
      archive = decoder.decodeBytes(bytes);
    } catch (e) {
      throw BackupValidationException('Corrupted or invalid .spendx package: $e');
    }

    ArchiveFile? manifestEntry;
    ArchiveFile? dbEntry;
    ArchiveFile? dbEncEntry;

    for (final file in archive.files) {
      if (file.name == manifestEntryName) {
        manifestEntry = file;
      } else if (file.name == dbEntryName) {
        dbEntry = file;
      } else if (file.name == dbEncEntryName) {
        dbEncEntry = file;
      }
    }

    if (manifestEntry == null) {
      throw const BackupValidationException(
        'Invalid .spendx package: missing manifest.json',
      );
    }

    // 1. Parse manifest
    final manifestBytes = manifestEntry.content as List<int>;
    final manifestJson = utf8.decode(manifestBytes);

    final BackupManifest manifest;
    try {
      manifest = BackupManifest.fromJson(manifestJson);
    } catch (e) {
      throw BackupValidationException('Failed to parse manifest.json: $e');
    }

    // High-level manifest checks
    CanonicalBackupValidator.validateManifest(manifest);

    // 2. Stage database in isolated directory
    if (!await stagingDir.exists()) {
      await stagingDir.create(recursive: true);
    }

    final stagedDbFile = File('${stagingDir.path}/$dbEntryName');
    if (await stagedDbFile.exists()) {
      await stagedDbFile.delete();
    }

    List<int> decryptedDbBytes;

    if (manifest.isEncrypted) {
      // ── Encrypted Package Decryption ──
      if (password == null || password.isEmpty) {
        throw const BackupPasswordRequiredException(
          'Backup archive is encrypted. A password is required to restore.',
        );
      }
      if (dbEncEntry == null) {
        throw const BackupValidationException(
          'Invalid encrypted .spendx package: missing spendx.db.enc ciphertext entry.',
        );
      }

      if (manifest.kdfSalt == null || manifest.nonce == null || manifest.mac == null) {
        throw const BackupValidationException(
          'Invalid encrypted manifest: missing KDF salt, nonce, or authentication tag.',
        );
      }

      // Check AAD manifest integrity if present
      List<int> aadBytes = const <int>[];
      if (manifest.aad != null) {
        final expectedAad = buildAadString(manifest);
        if (manifest.aad != expectedAad) {
          throw const BackupValidationException(
            'Backup manifest integrity check failed: metadata fields have been tampered with.',
          );
        }
        aadBytes = utf8.encode(manifest.aad!);
      }

      try {
        final salt = base64Decode(manifest.kdfSalt!);
        final nonce = base64Decode(manifest.nonce!);
        final macBytes = base64Decode(manifest.mac!);

        final SecretKey secretKey;
        final kdfAlgo = manifest.kdfAlgorithm?.toUpperCase() ?? 'PBKDF2-HMAC-SHA256';

        if (kdfAlgo == 'ARGON2ID') {
          final argon2id = Argon2id(
            parallelism: manifest.kdfParallelism ?? defaultArgon2Parallelism,
            memory: manifest.kdfMemory ?? defaultArgon2Memory,
            iterations: manifest.kdfIterations ?? defaultArgon2Iterations,
            hashLength: 32,
          );
          secretKey = await argon2id.deriveKey(
            secretKey: SecretKey(utf8.encode(password)),
            nonce: salt,
          );
        } else {
          // Backward-compatible fallback for PBKDF2-HMAC-SHA256
          final pbkdf2 = Pbkdf2(
            macAlgorithm: Hmac(Sha256()),
            iterations: manifest.kdfIterations ?? 10000,
            bits: 256,
          );
          secretKey = await pbkdf2.deriveKey(
            secretKey: SecretKey(utf8.encode(password)),
            nonce: salt,
          );
        }

        final cipherBytes = dbEncEntry.content as List<int>;
        final secretBox = SecretBox(
          cipherBytes,
          nonce: nonce,
          mac: Mac(macBytes),
        );

        final gcm = AesGcm.with256bits();
        decryptedDbBytes = await gcm.decrypt(
          secretBox,
          secretKey: secretKey,
          aad: aadBytes,
        );
      } catch (e) {
        if (e is BackupException) rethrow;
        throw const InvalidBackupPasswordException(
          'Failed to decrypt backup: incorrect password or corrupted ciphertext.',
        );
      }
    } else {
      // ── Legacy Unencrypted Package ──
      if (dbEntry == null) {
        throw const BackupValidationException(
          'Invalid unencrypted .spendx package: missing spendx.db',
        );
      }
      decryptedDbBytes = dbEntry.content as List<int>;
    }

    await stagedDbFile.writeAsBytes(decryptedDbBytes, flush: true);

    // 3. Cryptographic checksum verification
    final actualHash =
        sha256.convert(await stagedDbFile.readAsBytes()).toString();
    if (actualHash.toLowerCase() != manifest.databaseSha256.toLowerCase()) {
      await stagedDbFile.delete();
      throw BackupValidationException(
        'Cryptographic checksum mismatch! Expected SHA-256 ${manifest.databaseSha256}, got $actualHash.',
      );
    }

    _log('Package extracted and verified successfully (encrypted: ${manifest.isEncrypted})');
    return StagedBackup(
      stagingDir: stagingDir,
      stagedDbFile: stagedDbFile,
      manifest: manifest,
      isEncrypted: manifest.isEncrypted,
    );
  }

  /// Safely sweeps orphaned staging directories inside [Directory.systemTemp]
  /// created during interrupted backup, restore, or migration operations.
  ///
  /// Only deletes directories strictly matching known SpendX staging prefixes.
  /// Never deletes non-matching directories or touches the active database.
  static Future<int> cleanOrphanedStagingDirectories({
    Duration olderThan = const Duration(minutes: 5),
  }) async {
    int removedCount = 0;
    try {
      final tempDir = Directory.systemTemp;
      if (!await tempDir.exists()) return 0;

      final now = DateTime.now();
      final entities = tempDir.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is Directory) {
          final segments = entity.uri.pathSegments.where((s) => s.isNotEmpty).toList();
          final name = segments.isNotEmpty ? segments.last : '';
          if (_isSpendXStagingDir(name)) {
            try {
              final stat = entity.statSync();
              if (olderThan == Duration.zero || now.difference(stat.modified) >= olderThan) {
                entity.deleteSync(recursive: true);
                removedCount++;
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return removedCount;
  }

  static bool _isSpendXStagingDir(String name) {
    return name.startsWith('spendx_backup_stage_') ||
        name.startsWith('spendx_restore_stage_') ||
        name.startsWith('spendx_drive_restore_') ||
        name.startsWith('spendx_migration_stage_');
  }

  void _log(String msg) => AppLogger.d('[BACKUP_FILE] $msg');
}
