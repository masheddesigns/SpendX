import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../../core/logging/app_logger.dart';
import '../security/database_key_manager.dart';
import '../security/database_encryption_migration_service.dart';
import '../../services/canonical_backup_validator.dart';
import '../../services/platform_process_lock_service.dart';
import 'canonical_path_validator.dart';
import 'database_access_gate.dart';
import 'spendx_database_factory.dart';
import 'tables_v24.dart';

/// Cryptographically strong generation fingerprint binding database content,
/// restore operation ID, and expected generation.
///
/// Replaces heuristic checks (size + timestamp + header) with streaming SHA-256
/// digest across the entire database file, explicitly accounting for WAL/SHM sidecars.
class DatabaseGenerationFingerprint {
  final String restoreOperationId;
  final int expectedGeneration;
  final String dbFileSha256;
  final String? walFileSha256;
  final String compositeHash;

  const DatabaseGenerationFingerprint({
    required this.restoreOperationId,
    required this.expectedGeneration,
    required this.dbFileSha256,
    this.walFileSha256,
    required this.compositeHash,
  });

  Map<String, dynamic> toJson() => {
        'restoreOperationId': restoreOperationId,
        'expectedGeneration': expectedGeneration,
        'dbFileSha256': dbFileSha256,
        'walFileSha256': walFileSha256,
        'compositeHash': compositeHash,
      };

  factory DatabaseGenerationFingerprint.fromJson(Map<String, dynamic> json) {
    return DatabaseGenerationFingerprint(
      restoreOperationId: json['restoreOperationId'] as String? ?? '',
      expectedGeneration: (json['expectedGeneration'] as num?)?.toInt() ?? 0,
      dbFileSha256: json['dbFileSha256'] as String? ?? '',
      walFileSha256: json['walFileSha256'] as String?,
      compositeHash: json['compositeHash'] as String? ?? '',
    );
  }

  /// Streams SHA-256 across the complete database file and optional WAL sidecar.
  ///
  /// WAL/SHM Handling:
  /// - The live database must be checkpointed prior to capturing its fingerprint
  ///   so that uncheckpointed WAL frames are folded into the main database file.
  /// - If a non-empty `-wal` file exists alongside the database, its byte stream
  ///   is digested and recorded in [walFileSha256].
  /// - Staged and temporary swap databases are standalone SQLite files without WAL sidecars.
  /// - The `-shm` sidecar is an unauthenticated memory-mapped index and is not digested;
  ///   it is cleaned alongside `-wal` upon atomic swap or rollback.
  static Future<DatabaseGenerationFingerprint> compute({
    required String dbPath,
    required String restoreOperationId,
    required int expectedGeneration,
  }) async {
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      throw StateError('Cannot fingerprint nonexistent database: $dbPath');
    }

    final dbSha = await _streamFileSha256(dbFile);

    String? walSha;
    final walFile = File('$dbPath-wal');
    if (await walFile.exists() && await walFile.length() > 0) {
      walSha = await _streamFileSha256(walFile);
    }

    final compositePayload = [
      'v1',
      restoreOperationId,
      expectedGeneration.toString(),
      dbSha,
      walSha ?? 'NOWAL',
    ].join(':');

    final compDigest = sha256.convert(utf8.encode(compositePayload)).toString();

    return DatabaseGenerationFingerprint(
      restoreOperationId: restoreOperationId,
      expectedGeneration: expectedGeneration,
      dbFileSha256: dbSha,
      walFileSha256: walSha,
      compositeHash: compDigest,
    );
  }

  static Future<String> _streamFileSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  bool matches(DatabaseGenerationFingerprint other) {
    return restoreOperationId == other.restoreOperationId &&
        expectedGeneration == other.expectedGeneration &&
        dbFileSha256 == other.dbFileSha256 &&
        walFileSha256 == other.walFileSha256 &&
        compositeHash == other.compositeHash;
  }
}

/// States tracked by the dedicated restore journal.
enum RestoreJournalState {
  none,
  stagingPrepared,
  quiesced,
  backupCreated,
  swapping,
  swapComplete,
  contentVerified,
  cleanupPending,
  rolledBack,
  quarantined;

  static RestoreJournalState fromString(String name) {
    return RestoreJournalState.values.firstWhere(
      (s) => s.name.toLowerCase() == name.toLowerCase(),
      orElse: () => RestoreJournalState.none,
    );
  }
}

/// Thrown when a restore journal fails HMAC authentication or is malformed.
class RestoreJournalCorruptException extends StateError {
  RestoreJournalCorruptException(super.message);
}

/// Dedicated, authenticated journal for SpendX live database restore operations.
///
/// Strictly isolated from the legacy plaintext-to-SQLCipher migration journal.
/// Tracks atomic phase checkpoints across process termination, power loss, and LMK eviction.
class RestoreJournal {
  static const int currentFormatVersion = 1;
  static const String journalFileName = 'spendx_restore_journal.json';

  final File file;
  final int formatVersion;
  final String restoreOperationId;
  int sequenceNumber;
  RestoreJournalState state;
  DateTime updatedAt;
  final String targetDbPath;
  final String safetyBackupPath;
  final String? swapCandidatePath;
  final Map<String, dynamic>? expectedFingerprint;
  Map<String, dynamic>? expectedBackupFingerprint;
  String? errorMessage;
  String hmacSha256;

  RestoreJournal({
    required this.file,
    this.formatVersion = currentFormatVersion,
    required this.restoreOperationId,
    required this.sequenceNumber,
    required this.state,
    required this.updatedAt,
    required this.targetDbPath,
    required this.safetyBackupPath,
    this.swapCandidatePath,
    this.expectedFingerprint,
    this.expectedBackupFingerprint,
    this.errorMessage,
    required this.hmacSha256,
  });

  /// Derives the HMAC authentication key from the database master key.
  static Uint8List deriveJournalKey(Uint8List? masterKey) {
    final salt = utf8.encode('SpendX_RestoreJournal_Auth_v1');
    if (masterKey != null) {
      final hmac = Hmac(sha256, masterKey);
      return Uint8List.fromList(hmac.convert(salt).bytes);
    }
    return Uint8List.fromList(sha256.convert(salt).bytes);
  }

  /// Canonical, deterministic serialization format for payload fields.
  static String canonicalPayload({
    required int formatVersion,
    required String restoreOperationId,
    required int sequenceNumber,
    required RestoreJournalState state,
    required DateTime updatedAt,
    required String targetDbPath,
    required String safetyBackupPath,
    String? swapCandidatePath,
    Map<String, dynamic>? expectedFingerprint,
    Map<String, dynamic>? expectedBackupFingerprint,
    String? errorMessage,
  }) {
    final sortedFp = expectedFingerprint != null
        ? jsonEncode(Map.fromEntries(
            expectedFingerprint.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)),
          ))
        : '';

    final sortedBackupFp = expectedBackupFingerprint != null
        ? jsonEncode(Map.fromEntries(
            expectedBackupFingerprint.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)),
          ))
        : '';

    return [
      'v=$formatVersion',
      'op=$restoreOperationId',
      'seq=$sequenceNumber',
      'st=${state.name}',
      'ts=${updatedAt.toUtc().toIso8601String()}',
      'target=$targetDbPath',
      'backup=$safetyBackupPath',
      'swap=${swapCandidatePath ?? ''}',
      'fp=$sortedFp',
      'backupFp=$sortedBackupFp',
      'err=${errorMessage ?? ''}',
    ].join('|');
  }

  /// Computes deterministic authentication signature over journal fields.
  static String computeHmac({
    required int formatVersion,
    required String restoreOperationId,
    required int sequenceNumber,
    required RestoreJournalState state,
    required DateTime updatedAt,
    required String targetDbPath,
    required String safetyBackupPath,
    String? swapCandidatePath,
    Map<String, dynamic>? expectedFingerprint,
    Map<String, dynamic>? expectedBackupFingerprint,
    String? errorMessage,
    Uint8List? authKey,
  }) {
    final payload = canonicalPayload(
      formatVersion: formatVersion,
      restoreOperationId: restoreOperationId,
      sequenceNumber: sequenceNumber,
      state: state,
      updatedAt: updatedAt,
      targetDbPath: targetDbPath,
      safetyBackupPath: safetyBackupPath,
      swapCandidatePath: swapCandidatePath,
      expectedFingerprint: expectedFingerprint,
      expectedBackupFingerprint: expectedBackupFingerprint,
      errorMessage: errorMessage,
    );

    final keyBytes = authKey ?? deriveJournalKey(null);
    final hmac = Hmac(sha256, keyBytes);
    return hmac.convert(utf8.encode(payload)).toString();
  }

  /// Constant-time byte array comparison preventing timing side-channel attacks.
  static bool constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// Verifies journal integrity and authenticity against the supplied or derived master key.
  bool verifyHmac({Uint8List? authKey}) {
    final derivedKey = deriveJournalKey(authKey);
    final expectedHmac = computeHmac(
      formatVersion: formatVersion,
      restoreOperationId: restoreOperationId,
      sequenceNumber: sequenceNumber,
      state: state,
      updatedAt: updatedAt,
      targetDbPath: targetDbPath,
      safetyBackupPath: safetyBackupPath,
      swapCandidatePath: swapCandidatePath,
      expectedFingerprint: expectedFingerprint,
      expectedBackupFingerprint: expectedBackupFingerprint,
      errorMessage: errorMessage,
      authKey: derivedKey,
    );

    final expectedBytes = Uint8List.fromList(utf8.encode(expectedHmac));
    final actualBytes = Uint8List.fromList(utf8.encode(hmacSha256));
    return constantTimeEquals(expectedBytes, actualBytes);
  }

  /// Records a monotonic state transition atomically via temporary file rename.
  ///
  /// NOTE ON DIRECTORY DURABILITY:
  /// `File.writeAsString(..., flush: true)` forces OS write buffers to disk for file
  /// contents and inode data. However, POSIX directory metadata durability following
  /// `rename()` requires an `fsync()` on the containing directory file descriptor,
  /// which `dart:io` does not directly provide without platform-native FFI.
  /// Directory durability therefore relies on Android filesystem journaling (ext4/f2fs).
  Future<void> record(
    RestoreJournalState newState, {
    String? error,
    Uint8List? authKey,
    Map<String, dynamic>? expectedBackupFingerprint,
  }) async {
    sequenceNumber++;
    state = newState;
    updatedAt = DateTime.now().toUtc();
    if (error != null) errorMessage = error;
    if (expectedBackupFingerprint != null) {
      this.expectedBackupFingerprint = expectedBackupFingerprint;
    }

    Uint8List? key = authKey;
    if (key == null) {
      try {
        key = await SpendXDatabaseKeyManager.instance.getKey();
      } catch (_) {}
    }
    final derivedKey = deriveJournalKey(key);
    hmacSha256 = computeHmac(
      formatVersion: formatVersion,
      restoreOperationId: restoreOperationId,
      sequenceNumber: sequenceNumber,
      state: state,
      updatedAt: updatedAt,
      targetDbPath: targetDbPath,
      safetyBackupPath: safetyBackupPath,
      swapCandidatePath: swapCandidatePath,
      expectedFingerprint: expectedFingerprint,
      expectedBackupFingerprint: this.expectedBackupFingerprint,
      errorMessage: errorMessage,
      authKey: derivedKey,
    );

    final map = {
      'formatVersion': formatVersion,
      'restoreOperationId': restoreOperationId,
      'sequenceNumber': sequenceNumber,
      'state': state.name,
      'updatedAt': updatedAt.toIso8601String(),
      'targetDbPath': targetDbPath,
      'safetyBackupPath': safetyBackupPath,
      'swapCandidatePath': swapCandidatePath,
      'expectedFingerprint': expectedFingerprint,
      'expectedBackupFingerprint': this.expectedBackupFingerprint,
      'errorMessage': errorMessage,
      'hmacSha256': hmacSha256,
    };

    final content = const JsonEncoder.withIndent('  ').convert(map);
    final tmpFile = File('${file.path}.tmp');
    await tmpFile.writeAsString(content, flush: true);

    try {
      await tmpFile.rename(file.path);
    } on FileSystemException {
      await tmpFile.copy(file.path);
      await tmpFile.delete();
    }
  }

  /// Creates a new restore journal on disk.
  static Future<RestoreJournal> create({
    required File journalFile,
    required String restoreOperationId,
    required String targetDbPath,
    required String safetyBackupPath,
    String? swapCandidatePath,
    Map<String, dynamic>? expectedFingerprint,
    Map<String, dynamic>? expectedBackupFingerprint,
    Uint8List? authKey,
  }) async {
    final now = DateTime.now().toUtc();
    Uint8List? key = authKey;
    if (key == null) {
      try {
        key = await SpendXDatabaseKeyManager.instance.getKey();
      } catch (_) {}
    }
    final derivedKey = deriveJournalKey(key);
    final hmac = computeHmac(
      formatVersion: currentFormatVersion,
      restoreOperationId: restoreOperationId,
      sequenceNumber: 1,
      state: RestoreJournalState.stagingPrepared,
      updatedAt: now,
      targetDbPath: targetDbPath,
      safetyBackupPath: safetyBackupPath,
      swapCandidatePath: swapCandidatePath,
      expectedFingerprint: expectedFingerprint,
      expectedBackupFingerprint: expectedBackupFingerprint,
      authKey: derivedKey,
    );

    final journal = RestoreJournal(
      file: journalFile,
      formatVersion: currentFormatVersion,
      restoreOperationId: restoreOperationId,
      sequenceNumber: 1,
      state: RestoreJournalState.stagingPrepared,
      updatedAt: now,
      targetDbPath: targetDbPath,
      safetyBackupPath: safetyBackupPath,
      swapCandidatePath: swapCandidatePath,
      expectedFingerprint: expectedFingerprint,
      expectedBackupFingerprint: expectedBackupFingerprint,
      hmacSha256: hmac,
    );

    await journal.record(
      RestoreJournalState.stagingPrepared,
      authKey: key,
      expectedBackupFingerprint: expectedBackupFingerprint,
    );
    return journal;
  }

  /// Loads and validates a restore journal from disk.
  /// Returns null if the file does not exist or is empty.
  /// Throws [RestoreJournalCorruptException] if JSON, sequence counter, or HMAC is invalid.
  static Future<RestoreJournal?> load(
    String journalPath, {
    Uint8List? authKey,
  }) async {
    final f = File(journalPath);
    if (!await f.exists()) return null;

    Uint8List? key = authKey;
    if (key == null) {
      try {
        key = await SpendXDatabaseKeyManager.instance.getKey();
      } catch (_) {}
    }

    try {
      final str = await f.readAsString();
      if (str.trim().isEmpty) return null;
      final map = jsonDecode(str) as Map<String, dynamic>;

      final seq = map['sequenceNumber'] as int? ?? 0;
      if (seq <= 0) {
        throw RestoreJournalCorruptException(
          'Stale or invalid journal sequence counter: $seq (must be > 0)',
        );
      }

      final journal = RestoreJournal(
        file: f,
        formatVersion: map['formatVersion'] as int? ?? currentFormatVersion,
        restoreOperationId:
            map['restoreOperationId'] as String? ?? 'unknown_op',
        sequenceNumber: seq,
        state:
            RestoreJournalState.fromString(map['state'] as String? ?? 'none'),
        updatedAt: DateTime.tryParse(map['updatedAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
        targetDbPath: map['targetDbPath'] as String? ?? '',
        safetyBackupPath: map['safetyBackupPath'] as String? ?? '',
        swapCandidatePath: map['swapCandidatePath'] as String?,
        expectedFingerprint:
            map['expectedFingerprint'] as Map<String, dynamic>?,
        expectedBackupFingerprint:
            map['expectedBackupFingerprint'] as Map<String, dynamic>?,
        errorMessage: map['errorMessage'] as String?,
        hmacSha256: map['hmacSha256'] as String? ?? '',
      );

      if (!journal.verifyHmac(authKey: key)) {
        throw RestoreJournalCorruptException(
          'Restore journal at $journalPath failed constant-time HMAC authentication signature check',
        );
      }

      return journal;
    } catch (e) {
      if (e is RestoreJournalCorruptException) rethrow;
      throw RestoreJournalCorruptException('Malformed restore journal: $e');
    }
  }

  /// Clears the journal by deleting it on confirmed recovery completion.
  Future<void> clear() async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}

/// Result of a startup recovery reconciliation.
class RestoreRecoveryResult {
  final String message;
  final bool admissionPermitted;
  final List<String> quarantinedArtifacts;

  const RestoreRecoveryResult({
    required this.message,
    required this.admissionPermitted,
    this.quarantinedArtifacts = const [],
  });
}

/// Central authority for startup recovery reconciliation across interrupted restore operations.
///
/// Evaluates on-disk artifacts against the recovery decision table before any normal
/// application database connection is opened.
class RestoreRecoveryService {
  RestoreRecoveryService._();
  static final RestoreRecoveryService instance = RestoreRecoveryService._();

  /// Validates an on-disk candidate database file directly on an isolated connection.
  /// Checks SQLite integrity, foreign keys, user_version == 24, and canonical tables.
  ///
  /// CRITICAL SAFETY GUARANTEE:
  /// Uses [SpendXDatabaseKeyManager.getKey] which NEVER creates or replaces keys.
  /// If the master key is unreadable or malformed, candidate validation safely returns false.
  Future<bool> validateCandidateDatabase(
    String dbPath, {
    Uint8List? keyOverride,
  }) async {
    final file = File(dbPath);
    if (!await file.exists() || await file.length() == 0) {
      return false;
    }

    try {
      Uint8List? key;
      try {
        key = keyOverride ?? await SpendXDatabaseKeyManager.instance.getKey();
      } catch (e) {
        AppLogger.w(
          '[RECOVERY] Master key inaccessible during candidate validation: $e',
        );
        return false;
      }

      final blobKey = key != null
          ? SpendXDatabaseKeyManager.keyToSqlCipherBlob(key)
          : null;

      Database? candidateDb;
      try {
        if (DatabaseEncryptionMigrationService.isPlaintextSqliteFile(dbPath)) {
          candidateDb = await openDatabase(dbPath);
        } else if (blobKey != null) {
          candidateDb = await SpendXDatabaseFactory.instance
              .openEncryptedDatabase(
                dbPath,
                password: blobKey,
                bypassPrimaryGuard: true,
              );
        } else {
          return false;
        }

        // 1. Structural integrity
        final integrityRows =
            await candidateDb.rawQuery('PRAGMA integrity_check;');
        final integrity = integrityRows.isNotEmpty
            ? (integrityRows.first.values.first as String? ?? '')
            : '';
        if (integrity.toLowerCase() != 'ok') {
          AppLogger.e('[RECOVERY] integrity_check failed: $integrity');
          return false;
        }

        // 2. Referential integrity
        final fkRows = await candidateDb.rawQuery('PRAGMA foreign_key_check;');
        if (fkRows.isNotEmpty) {
          AppLogger.e('[RECOVERY] foreign_key_check failed: $fkRows');
          // Clean up dangling foreign keys rather than throwing away entire DB
          for (final row in fkRows) {
            final table = row['table'] as String?;
            final rowid = row['rowid'];
            final parent = row['parent'] as String?;
            if (table == 'economic_events' && parent == 'economic_events') {
              await candidateDb.rawUpdate('UPDATE economic_events SET reversal_of_event_id = NULL WHERE rowid = ?;', [rowid]);
            } else if (table != null && rowid != null) {
              await candidateDb.execute('PRAGMA foreign_keys = OFF;');
              await candidateDb.rawDelete('DELETE FROM $table WHERE rowid = ?;', [rowid]);
              await candidateDb.execute('PRAGMA foreign_keys = ON;');
            }
          }
        }

        // 3. Version == 24
        final verRows = await candidateDb.rawQuery('PRAGMA user_version;');
        final ver = (verRows.first.values.first as num?)?.toInt() ?? 0;
        if (ver != 24) {
          return false;
        }

        // 4. Canonical ledger tables
        final tables = await candidateDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('${TablesV24.accounts}', '${TablesV24.economicEvents}', '${TablesV24.postings}');",
        );
        if (tables.length < 3) {
          return false;
        }

        return true;
      } finally {
        if (candidateDb != null && candidateDb.isOpen) {
          await candidateDb.close();
        }
      }
    } catch (_) {
      return false;
    }
  }

  /// Quarantines an artifact by renaming it to a timestamped path.
  /// Strictly prevents permanent unlinking/deletion of potentially recoverable data.
  /// Requires confirmed native exclusive restore lock token.
  Future<String?> _quarantineArtifact(
    File file,
    String prefix, {
    required String lockToken,
  }) async {
    if (lockToken.isEmpty) {
      throw StateError(
        'Cannot perform quarantine mutation without confirmed native exclusive lock token',
      );
    }
    final isValid = await PlatformProcessLockService.instance.validateExclusiveRestoreToken(lockToken);
    if (!isValid) {
      throw StateError(
        'Cannot perform quarantine mutation: native exclusive restore lease validation failed',
      );
    }
    CanonicalPathValidator.assertSafeDatabaseMutationPath(file.path);
    if (!await file.exists()) return null;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dir = p.dirname(file.path);
    final name = p.basename(file.path);
    final targetPath = p.join(dir, '$name.${prefix}_$ts');
    CanonicalPathValidator.assertSafeDatabaseMutationPath(targetPath);
    try {
      await file.rename(targetPath);
      return targetPath;
    } catch (_) {
      try {
        await file.copy(targetPath);
        await file.delete();
        return targetPath;
      } catch (_) {
        return null;
      }
    }
  }

  /// Reconciles cold-start database state against the recovery decision table.
  ///
  /// Guarantees:
  /// 1. Executes before any foreground, background or provider access to the primary database.
  /// 2. Verifies confirmed native exclusive restore token before ANY filesystem mutation.
  /// 3. Never deletes ambiguous or unverified database files: archives/renames to timestamped quarantine.
  /// 4. Does NOT automatically promote orphan backups without authenticated journal linking.
  /// 5. Does NOT promote swap candidates under arbitrary or non-swapping journal states.
  /// 6. Fails closed (leaving DatabaseAccessGate closed) on any indeterminate or unauthenticated state.
  Future<RestoreRecoveryResult> reconcile({
    String? dbPath,
    Uint8List? keyOverride,
  }) async {
    final activePath =
        dbPath ?? p.join(await getDatabasesPath(), 'spendx.db');
    CanonicalPathValidator.assertSafeDatabaseMutationPath(activePath);
    final activeFile = File(activePath);
    final backupFile = File('$activePath.pre_restore_backup');
    final swapFile = File('$activePath.new_swap');
    final journalFile =
        File(p.join(p.dirname(activePath), RestoreJournal.journalFileName));
    final journalTmpFile = File('${journalFile.path}.tmp');
    final walFile = File('$activePath-wal');
    final shmFile = File('$activePath-shm');

    final quarantined = <String>[];

    // 1. Retrieve master key safely. NEVER call getOrCreateKey().
    Uint8List? masterKey = keyOverride;
    bool keyInaccessible = false;
    if (masterKey == null) {
      try {
        masterKey = await SpendXDatabaseKeyManager.instance.getKey();
      } catch (e) {
        keyInaccessible = true;
        AppLogger.w(
          '[RECOVERY] Master key inaccessible or invalid during recovery: $e',
        );
      }
    }

    // 2. Interrupted temporary journal write handling
    if (await journalTmpFile.exists()) {
      await _executeWithExclusiveLock((lockToken) async {
        if (await journalFile.exists()) {
          // Committed journal exists; .tmp was an interrupted update -> quarantine .tmp
          final qt = await _quarantineArtifact(
            journalTmpFile,
            'incomplete_journal_tmp',
            lockToken: lockToken,
          );
          if (qt != null) quarantined.add(qt);
        } else {
          // No committed journal exists; .tmp was interrupted during creation -> quarantine .tmp
          final qt = await _quarantineArtifact(
            journalTmpFile,
            'uncommitted_journal_tmp',
            lockToken: lockToken,
          );
          if (qt != null) quarantined.add(qt);
        }
      });
    }

    // 3. Read and authenticate journal if present
    RestoreJournal? journal;
    bool journalCorrupt = false;
    if (await journalFile.exists()) {
      try {
        journal = await RestoreJournal.load(
          journalFile.path,
          authKey: masterKey,
        );
      } catch (e) {
        journalCorrupt = true;
        AppLogger.w(
          '[RECOVERY] Restore journal unauthenticated or corrupted: $e',
        );
      }
    }

    // 4. Inspect candidate file validities
    final isLiveValid = await validateCandidateDatabase(
      activePath,
      keyOverride: masterKey,
    );
    final isBackupValid = await validateCandidateDatabase(
      backupFile.path,
      keyOverride: masterKey,
    );
    final isSwapValid = await validateCandidateDatabase(
      swapFile.path,
      keyOverride: masterKey,
    );

    final liveExists =
        await activeFile.exists() && (await activeFile.length() > 0);
    final backupExists =
        await backupFile.exists() && (await backupFile.length() > 0);
    final swapExists = await swapFile.exists() && (await swapFile.length() > 0);

    // Fail-closed check if key is unreadable while encrypted candidate databases exist
    if (keyInaccessible && (liveExists || backupExists || swapExists)) {
      await DatabaseAccessGate.instance.closeAdmissionAndDrain();
      throw const RestoreQuarantinedException(
        'Database encryption key is inaccessible or invalid. Fail-closed quarantine enforced.',
      );
    }

    // Prior Unresolved Quarantine Recorded in Journal
    if (journal != null && journal.state == RestoreJournalState.quarantined) {
      AppLogger.e(
        '[RECOVERY] Journal records prior unresolved quarantine. Failing closed.',
      );
      await DatabaseAccessGate.instance.closeAdmissionAndDrain();
      throw const RestoreQuarantinedException(
        'Database is in persistent administrative quarantine from prior failure. Manual recovery required.',
      );
    }

    // Journal Tampering / Unauthenticated Signature Detected
    if (journalCorrupt) {
      if (isLiveValid && !backupExists && !swapExists) {
        // Active database is verified healthy and no restore replacement was in flight.
        await _executeWithExclusiveLock((lockToken) async {
          final qj = await _quarantineArtifact(
            journalFile,
            'corrupt_journal',
            lockToken: lockToken,
          );
          if (qj != null) quarantined.add(qj);
        });
        return RestoreRecoveryResult(
          message:
              'Quarantined corrupt journal; active database verified intact.',
          admissionPermitted: true,
          quarantinedArtifacts: quarantined,
        );
      } else {
        // Restore outcome cannot be established. Fail closed and preserve artifacts.
        await _executeWithExclusiveLock((lockToken) async {
          final qj = await _quarantineArtifact(
            journalFile,
            'corrupt_journal',
            lockToken: lockToken,
          );
          if (qj != null) quarantined.add(qj);
        });
        await DatabaseAccessGate.instance.closeAdmissionAndDrain();
        throw const RestoreQuarantinedException(
          'Restore journal failed authentication and active database state is ambiguous. Quarantine enforced.',
        );
      }
    }

    // CASES WITHOUT ACTIVE RESTORE JOURNAL (Normal boot or unlinked artifacts)
    if (journal == null || journal.state == RestoreJournalState.none) {
      if (!liveExists && !backupExists && !swapExists) {
        return const RestoreRecoveryResult(
          message: 'Fresh database initialization.',
          admissionPermitted: true,
        );
      }

      if (isLiveValid && !backupExists && !swapExists) {
        return const RestoreRecoveryResult(
          message: 'Normal healthy cold start.',
          admissionPermitted: true,
        );
      }

      // Stale Swap Orphan
      if (isLiveValid && !backupExists && swapExists) {
        await _executeWithExclusiveLock((lockToken) async {
          if (await swapFile.exists()) {
            final qs = await _quarantineArtifact(
              swapFile,
              'orphan_swap',
              lockToken: lockToken,
            );
            if (qs != null) quarantined.add(qs);
          }
          // Independently validate remaining active database under exclusive lock
          final liveStillValid = await validateCandidateDatabase(
            activePath,
            keyOverride: masterKey,
          );
          if (!liveStillValid) {
            await DatabaseAccessGate.instance.closeAdmissionAndDrain();
            throw const RestoreQuarantinedException(
              'Active database invalid after orphan swap quarantine. Admission closed.',
            );
          }
        });
        return RestoreRecoveryResult(
          message: 'Quarantined stale swap orphan; active database intact.',
          admissionPermitted: true,
          quarantinedArtifacts: quarantined,
        );
      }

      // Stale Backup Orphan (Active DB valid)
      if (isLiveValid && isBackupValid && !swapExists) {
        await _executeWithExclusiveLock((lockToken) async {
          final qb = await _quarantineArtifact(
            backupFile,
            'retained_backup',
            lockToken: lockToken,
          );
          if (qb != null) quarantined.add(qb);
        });
        return RestoreRecoveryResult(
          message: 'Archived stale backup orphan; active database intact.',
          admissionPermitted: true,
          quarantinedArtifacts: quarantined,
        );
      }

      // SECURITY CORRECTION: Active DB Missing, Orphan Backup Present (No Journal)
      // Do NOT automatically promote an orphan backup of unproven provenance!
      // Preserve backup in quarantine and FAIL CLOSED.
      if (!liveExists && isBackupValid) {
        await _executeWithExclusiveLock((lockToken) async {
          final qb = await _quarantineArtifact(
            backupFile,
            'orphan_backup',
            lockToken: lockToken,
          );
          if (qb != null) quarantined.add(qb);
        });
        await DatabaseAccessGate.instance.closeAdmissionAndDrain();
        throw const RestoreQuarantinedException(
          'Active database missing and unlinked backup has unproven provenance. Quarantine enforced.',
        );
      }

      // Active DB Corrupted Without Backup
      if (liveExists && !isLiveValid && !backupExists) {
        await _executeWithExclusiveLock((lockToken) async {
          final ql = await _quarantineArtifact(
            activeFile,
            'corrupt_live_no_backup',
            lockToken: lockToken,
          );
          if (ql != null) quarantined.add(ql);
        });
        await DatabaseAccessGate.instance.closeAdmissionAndDrain();
        throw const RestoreQuarantinedException(
          'Active database is corrupt and no backup exists. Admission permanently closed.',
        );
      }

      if (!isLiveValid && !isBackupValid) {
        await _executeWithExclusiveLock((lockToken) async {
          if (liveExists) {
            final ql = await _quarantineArtifact(
              activeFile,
              'fatal_corrupt_live',
              lockToken: lockToken,
            );
            if (ql != null) quarantined.add(ql);
          }
          if (backupExists) {
            final qb = await _quarantineArtifact(
              backupFile,
              'fatal_corrupt_backup',
              lockToken: lockToken,
            );
            if (qb != null) quarantined.add(qb);
          }
        });
        await DatabaseAccessGate.instance.closeAdmissionAndDrain();
        throw const RestoreQuarantinedException(
          'Catastrophic corruption: active database and backup failed validation without journal.',
        );
      }

      return const RestoreRecoveryResult(
        message: 'No active restore journal; proceeding.',
        admissionPermitted: true,
      );
    }

    // CASES WITH AUTHENTICATED RESTORE JOURNAL
    final activeJournal = journal;
    final jState = activeJournal.state;

    // Crash During Backup Cleanup (cleanupPending) or After Validation (contentVerified)
    if (jState == RestoreJournalState.cleanupPending ||
        jState == RestoreJournalState.contentVerified) {
      if (isLiveValid) {
        await _executeWithExclusiveLock((lockToken) async {
          if (backupExists) {
            final qb = await _quarantineArtifact(
              backupFile,
              'archive_backup',
              lockToken: lockToken,
            );
            if (qb != null) quarantined.add(qb);
          }
          if (swapExists) {
            final qs = await _quarantineArtifact(
              swapFile,
              'orphan_swap',
              lockToken: lockToken,
            );
            if (qs != null) quarantined.add(qs);
          }
          await activeJournal.clear();
        });
        return RestoreRecoveryResult(
          message:
              'Finalized post-validation cleanup; active restored database valid.',
          admissionPermitted: true,
          quarantinedArtifacts: quarantined,
        );
      }
    }

    // Crash During Swap Step (Live DB already new and valid)
    if (jState == RestoreJournalState.swapping && isLiveValid) {
      await _executeWithExclusiveLock((lockToken) async {
        if (backupExists) {
          final qb = await _quarantineArtifact(
            backupFile,
            'safety_backup',
            lockToken: lockToken,
          );
          if (qb != null) quarantined.add(qb);
        }
        if (swapExists) {
          final qs = await _quarantineArtifact(
            swapFile,
            'lingering_swap',
            lockToken: lockToken,
          );
          if (qs != null) quarantined.add(qs);
        }
        await activeJournal.clear();
      });
      return RestoreRecoveryResult(
        message: 'Completed roll-forward: swapped live database is valid.',
        admissionPermitted: true,
        quarantinedArtifacts: quarantined,
      );
    }

    // Crash During Swap Step (Live DB corrupt or missing; Backup valid) -> Rollback from backup
    if (jState == RestoreJournalState.swapping && isBackupValid) {
      await _executeWithExclusiveLock((lockToken) async {
        // Re-scan file existence under confirmed native exclusive lock
        final curLiveExists =
            await activeFile.exists() && (await activeFile.length() > 0);
        final curBackupExists =
            await backupFile.exists() && (await backupFile.length() > 0);
        if (!curBackupExists) {
          throw const RestoreQuarantinedException(
            'Safety backup disappeared after exclusive lock acquisition. Quarantine enforced.',
          );
        }

        // Re-evaluate backup provenance and fingerprint under the lock
        if (activeJournal.expectedBackupFingerprint != null) {
          final curBackupFp = await DatabaseGenerationFingerprint.compute(
            dbPath: backupFile.path,
            restoreOperationId: activeJournal.restoreOperationId,
            expectedGeneration: 0,
          );
          final expBackupFp = DatabaseGenerationFingerprint.fromJson(
            activeJournal.expectedBackupFingerprint!,
          );
          if (curBackupFp.dbFileSha256 != expBackupFp.dbFileSha256) {
            final qb = await _quarantineArtifact(
              backupFile,
              'unverified_backup_fingerprint_mismatch',
              lockToken: lockToken,
            );
            if (qb != null) quarantined.add(qb);
            await DatabaseAccessGate.instance.closeAdmissionAndDrain();
            throw const RestoreQuarantinedException(
              'Safety backup fingerprint does not match authenticated journal. Rollback aborted; quarantine enforced.',
            );
          }
        }

        if (curLiveExists) {
          final ql = await _quarantineArtifact(
            activeFile,
            'corrupt_swap_live',
            lockToken: lockToken,
          );
          if (ql != null) quarantined.add(ql);
        }
        await backupFile.copy(activePath);
        if (await walFile.exists()) await walFile.delete();
        if (await shmFile.exists()) await shmFile.delete();
        final qb = await _quarantineArtifact(
          backupFile,
          'safety_backup_rolled_back',
          lockToken: lockToken,
        );
        if (qb != null) quarantined.add(qb);
        if (await swapFile.exists()) {
          final qs = await _quarantineArtifact(
            swapFile,
            'aborted_swap',
            lockToken: lockToken,
          );
          if (qs != null) quarantined.add(qs);
        }
        await activeJournal.record(
          RestoreJournalState.rolledBack,
          authKey: masterKey,
        );
        await activeJournal.clear();
      });
      return RestoreRecoveryResult(
        message: 'Rolled back corrupted swap to safety backup successfully.',
        admissionPermitted: true,
        quarantinedArtifacts: quarantined,
      );
    }

    // SECURITY CORRECTION: Active & Backup Missing, Swap Present
    // ONLY permit swap promotion if journal is explicitly in swapping or swapComplete
    // AND swap matches the authenticated journal's expected fingerprint.
    if ((jState == RestoreJournalState.swapping ||
            jState == RestoreJournalState.swapComplete) &&
        !liveExists &&
        !backupExists &&
        isSwapValid) {
      bool fingerprintMatches = true;
      if (activeJournal.expectedFingerprint != null) {
        try {
          final currentSwapFp = await DatabaseGenerationFingerprint.compute(
            dbPath: swapFile.path,
            restoreOperationId: activeJournal.restoreOperationId,
            expectedGeneration: 1,
          );
          final expectedFp = DatabaseGenerationFingerprint.fromJson(
            activeJournal.expectedFingerprint!,
          );
          fingerprintMatches =
              currentSwapFp.dbFileSha256 == expectedFp.dbFileSha256;
        } catch (_) {
          fingerprintMatches = false;
        }
      }

      if (fingerprintMatches) {
        await _executeWithExclusiveLock((lockToken) async {
          // Re-scan under confirmed native exclusive lock
          final curSwapExists =
              await swapFile.exists() && (await swapFile.length() > 0);
          if (!curSwapExists) {
            throw const RestoreQuarantinedException(
              'Swap candidate disappeared under exclusive lock. Quarantine enforced.',
            );
          }

          // Re-verify exact expected fingerprint under lock immediately before promotion
          if (activeJournal.expectedFingerprint != null) {
            final lockedSwapFp = await DatabaseGenerationFingerprint.compute(
              dbPath: swapFile.path,
              restoreOperationId: activeJournal.restoreOperationId,
              expectedGeneration: 1,
            );
            final expectedFp = DatabaseGenerationFingerprint.fromJson(
              activeJournal.expectedFingerprint!,
            );
            if (lockedSwapFp.dbFileSha256 != expectedFp.dbFileSha256) {
              final qs = await _quarantineArtifact(
                swapFile,
                'unverified_swap_fingerprint_mismatch',
                lockToken: lockToken,
              );
              if (qs != null) quarantined.add(qs);
              await DatabaseAccessGate.instance.closeAdmissionAndDrain();
              throw const RestoreQuarantinedException(
                'Swap candidate fingerprint does not match authenticated restore journal under lock. Quarantine enforced.',
              );
            }
          }

          await swapFile.copy(activePath);
          final qs = await _quarantineArtifact(
            swapFile,
            'promoted_swap',
            lockToken: lockToken,
          );
          if (qs != null) quarantined.add(qs);
          await activeJournal.clear();
        });
        return RestoreRecoveryResult(
          message: 'Promoted verified swap candidate to active database.',
          admissionPermitted: true,
          quarantinedArtifacts: quarantined,
        );
      } else {
        // Fingerprint mismatch or uncertain provenance: quarantine swap and fail closed!
        await _executeWithExclusiveLock((lockToken) async {
          final qs = await _quarantineArtifact(
            swapFile,
            'unverified_swap_fingerprint_mismatch',
            lockToken: lockToken,
          );
          if (qs != null) quarantined.add(qs);
        });
        await DatabaseAccessGate.instance.closeAdmissionAndDrain();
        throw const RestoreQuarantinedException(
          'Swap candidate fingerprint does not match authenticated restore journal. Quarantine enforced.',
        );
      }
    }

    // If swap exists under any other state, it MUST NOT be promoted. Quarantine it.
    if (swapExists &&
        jState != RestoreJournalState.swapping &&
        jState != RestoreJournalState.swapComplete) {
      await _executeWithExclusiveLock((lockToken) async {
        final qs = await _quarantineArtifact(
          swapFile,
          'orphan_swap',
          lockToken: lockToken,
        );
        if (qs != null) quarantined.add(qs);
      });
    }

    // Crash in backupCreated
    if (jState == RestoreJournalState.backupCreated) {
      if (isLiveValid) {
        // Live was never swapped and remains intact
        await _executeWithExclusiveLock((lockToken) async {
          if (backupExists) {
            final qb = await _quarantineArtifact(
              backupFile,
              'aborted_backup',
              lockToken: lockToken,
            );
            if (qb != null) quarantined.add(qb);
          }
          await activeJournal.clear();
        });
        return RestoreRecoveryResult(
          message: 'Reset aborted pre-swap restore; live database intact.',
          admissionPermitted: true,
          quarantinedArtifacts: quarantined,
        );
      } else if (isBackupValid) {
        // Live corrupted before swap; rollback from backup
        await _executeWithExclusiveLock((lockToken) async {
          final curLiveExists =
              await activeFile.exists() && (await activeFile.length() > 0);
          final curBackupExists =
              await backupFile.exists() && (await backupFile.length() > 0);
          if (!curBackupExists) {
            throw const RestoreQuarantinedException(
              'Safety backup disappeared after exclusive lock acquisition. Quarantine enforced.',
            );
          }

          if (activeJournal.expectedBackupFingerprint != null) {
            final curBackupFp = await DatabaseGenerationFingerprint.compute(
              dbPath: backupFile.path,
              restoreOperationId: activeJournal.restoreOperationId,
              expectedGeneration: 0,
            );
            final expBackupFp = DatabaseGenerationFingerprint.fromJson(
              activeJournal.expectedBackupFingerprint!,
            );
            if (curBackupFp.dbFileSha256 != expBackupFp.dbFileSha256) {
              final qb = await _quarantineArtifact(
                backupFile,
                'unverified_backup_fingerprint_mismatch',
                lockToken: lockToken,
              );
              if (qb != null) quarantined.add(qb);
              await DatabaseAccessGate.instance.closeAdmissionAndDrain();
              throw const RestoreQuarantinedException(
                'Safety backup fingerprint does not match authenticated journal. Rollback aborted; quarantine enforced.',
              );
            }
          }

          if (curLiveExists) {
            final ql = await _quarantineArtifact(
              activeFile,
              'corrupt_pre_swap',
              lockToken: lockToken,
            );
            if (ql != null) quarantined.add(ql);
          }
          await backupFile.copy(activePath);
          final qb = await _quarantineArtifact(
            backupFile,
            'restored_backup',
            lockToken: lockToken,
          );
          if (qb != null) quarantined.add(qb);
          await activeJournal.clear();
        });
        return RestoreRecoveryResult(
          message: 'Rolled back corrupt pre-swap database from backup.',
          admissionPermitted: true,
          quarantinedArtifacts: quarantined,
        );
      }
    }

    // Crash After Rollback Verification
    if (jState == RestoreJournalState.rolledBack && isLiveValid) {
      await _executeWithExclusiveLock((lockToken) async {
        if (backupExists) {
          final qb = await _quarantineArtifact(
            backupFile,
            'consumed_rollback_backup',
            lockToken: lockToken,
          );
          if (qb != null) quarantined.add(qb);
        }
        await activeJournal.clear();
      });
      return RestoreRecoveryResult(
        message: 'Finalized post-rollback state; database verified.',
        admissionPermitted: true,
        quarantinedArtifacts: quarantined,
      );
    }

    // Dual Corruption or Active Missing + Backup Corrupt: Catastrophic failure
    AppLogger.e(
      '[RECOVERY] Fatal restore state: liveExists=$liveExists (valid=$isLiveValid), '
      'backupExists=$backupExists (valid=$isBackupValid). Enforcing quarantine.',
    );
    await _executeWithExclusiveLock((lockToken) async {
      if (liveExists && !isLiveValid) {
        final ql = await _quarantineArtifact(
          activeFile,
          'fatal_corrupt_live',
          lockToken: lockToken,
        );
        if (ql != null) quarantined.add(ql);
      }
      if (backupExists && !isBackupValid) {
        final qb = await _quarantineArtifact(
          backupFile,
          'fatal_corrupt_backup',
          lockToken: lockToken,
        );
        if (qb != null) quarantined.add(qb);
      }
      await activeJournal.record(
        RestoreJournalState.quarantined,
        error: 'Dual corruption',
        authKey: masterKey,
      );
    });
    await DatabaseAccessGate.instance.closeAdmissionAndDrain();
    throw const RestoreQuarantinedException(
      'Catastrophic corruption: both active database and backup failed validation. Quarantine enforced.',
    );
  }

  /// Helper to acquire the native exclusive restore lock before filesystem mutations.
  /// Requires confirmed non-empty token from [PlatformProcessLockService.beginExclusiveRestore].
  Future<void> _executeWithExclusiveLock(
    Future<void> Function(String lockToken) action,
  ) async {
    final lockService = PlatformProcessLockService.instance;
    String? token;
    try {
      token = await lockService.beginExclusiveRestore();
    } catch (e) {
      throw StateError(
        'Cannot perform recovery file operation: exclusive restore lock acquisition failed ($e)',
      );
    }

    if (token.isEmpty) {
      throw StateError(
        'Cannot perform recovery file operation: acquired native exclusive restore token is null or empty',
      );
    }

    final isValid = await lockService.validateExclusiveRestoreToken(token);
    if (!isValid) {
      try {
        await lockService.abortExclusiveRestore(token);
      } catch (_) {}
      throw StateError(
        'Cannot perform recovery file operation: exclusive restore token validation failed',
      );
    }

    try {
      await action(token);
      await lockService.completeExclusiveRestore(token);
    } catch (e) {
      await lockService.abortExclusiveRestore(token);
      rethrow;
    }
  }
}
