import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../data/core/tables_v24.dart';

/// Base exception for all backup and restore operations.
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => 'BackupException: $message';
}

/// Thrown when a backup package or staged database fails validation.
class BackupValidationException extends BackupException {
  const BackupValidationException(super.message);

  @override
  String toString() => 'BackupValidationException: $message';
}

/// Thrown when an incompatible or legacy backup version is encountered.
class UnsupportedBackupVersionException extends BackupException {
  const UnsupportedBackupVersionException(super.message);

  @override
  String toString() => 'UnsupportedBackupVersionException: $message';
}

/// Thrown when atomic replacement or rollback fails.
class RestoreException extends BackupException {
  const RestoreException(super.message);

  @override
  String toString() => 'RestoreException: $message';
}

/// Thrown when an encrypted backup requires a password that was not provided.
class BackupPasswordRequiredException extends BackupException {
  const BackupPasswordRequiredException(super.message);

  @override
  String toString() => 'BackupPasswordRequiredException: $message';
}

/// Thrown when an encrypted backup fails authentication due to wrong password or corrupted ciphertext.
class InvalidBackupPasswordException extends BackupException {
  const InvalidBackupPasswordException(super.message);

  @override
  String toString() => 'InvalidBackupPasswordException: $message';
}

/// Manifest structure packaged inside every `.spendx` backup archive.
class BackupManifest {
  static const int currentFormatVersion = 2;
  static const int currentSchemaVersion = 24;

  final int formatVersion;
  final int schemaVersion;
  final String appVersion;
  final String appName;
  final DateTime createdAt;
  final String databaseSha256;
  final int databaseSize;
  final Map<String, int> recordCounts;
  final int canonicalEventCount;
  final int postingCount;
  final int evidenceCount;
  final int reviewCandidateCount;
  final int debitTotal;
  final int creditTotal;
  final String? deviceId;
  final Map<String, dynamic> settings;
  final bool isEncrypted;
  final String? encryptionAlgorithm;
  final String? kdfAlgorithm;
  final int? kdfIterations;
  final int? kdfMemory;
  final int? kdfParallelism;
  final int? kdfVersion;
  final String? kdfSalt;
  final String? nonce;
  final String? mac;
  final String? aad;

  const BackupManifest({
    required this.formatVersion,
    required this.schemaVersion,
    required this.appVersion,
    required this.appName,
    required this.createdAt,
    required this.databaseSha256,
    required this.databaseSize,
    required this.recordCounts,
    required this.canonicalEventCount,
    required this.postingCount,
    required this.evidenceCount,
    required this.reviewCandidateCount,
    required this.debitTotal,
    required this.creditTotal,
    this.deviceId,
    this.settings = const {},
    this.isEncrypted = false,
    this.encryptionAlgorithm,
    this.kdfAlgorithm,
    this.kdfIterations,
    this.kdfMemory,
    this.kdfParallelism,
    this.kdfVersion,
    this.kdfSalt,
    this.nonce,
    this.mac,
    this.aad,
  });

  Map<String, dynamic> toMap() => {
        'format_version': formatVersion,
        'schema_version': schemaVersion,
        'app_version': appVersion,
        'app_name': appName,
        'created_at': createdAt.toUtc().toIso8601String(),
        'database_sha256': databaseSha256,
        'database_size': databaseSize,
        'record_counts': recordCounts,
        'canonical_event_count': canonicalEventCount,
        'posting_count': postingCount,
        'evidence_count': evidenceCount,
        'review_candidate_count': reviewCandidateCount,
        'debit_total': debitTotal,
        'credit_total': creditTotal,
        'device_id': deviceId,
        'settings': settings,
        'is_encrypted': isEncrypted,
        if (encryptionAlgorithm != null)
          'encryption_algorithm': encryptionAlgorithm,
        if (kdfAlgorithm != null) 'kdf_algorithm': kdfAlgorithm,
        if (kdfIterations != null) 'kdf_iterations': kdfIterations,
        if (kdfMemory != null) 'kdf_memory': kdfMemory,
        if (kdfParallelism != null) 'kdf_parallelism': kdfParallelism,
        if (kdfVersion != null) 'kdf_version': kdfVersion,
        if (kdfSalt != null) 'kdf_salt': kdfSalt,
        if (nonce != null) 'nonce': nonce,
        if (mac != null) 'mac': mac,
        if (aad != null) 'aad': aad,
      };

  factory BackupManifest.fromMap(Map<String, dynamic> map) {
    return BackupManifest(
      formatVersion: map['format_version'] as int? ?? 1,
      schemaVersion: map['schema_version'] as int? ?? 0,
      appVersion: map['app_version'] as String? ?? 'unknown',
      appName: map['app_name'] as String? ?? 'SpendX',
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      databaseSha256: map['database_sha256'] as String? ?? '',
      databaseSize: map['database_size'] as int? ?? 0,
      recordCounts: Map<String, int>.from(map['record_counts'] as Map? ?? {}),
      canonicalEventCount: map['canonical_event_count'] as int? ?? 0,
      postingCount: map['posting_count'] as int? ?? 0,
      evidenceCount: map['evidence_count'] as int? ?? 0,
      reviewCandidateCount: map['review_candidate_count'] as int? ?? 0,
      debitTotal: map['debit_total'] as int? ?? 0,
      creditTotal: map['credit_total'] as int? ?? 0,
      deviceId: map['device_id'] as String?,
      settings: Map<String, dynamic>.from(map['settings'] as Map? ?? {}),
      isEncrypted: map['is_encrypted'] as bool? ?? false,
      encryptionAlgorithm: map['encryption_algorithm'] as String?,
      kdfAlgorithm: map['kdf_algorithm'] as String?,
      kdfIterations: map['kdf_iterations'] as int?,
      kdfMemory: map['kdf_memory'] as int?,
      kdfParallelism: map['kdf_parallelism'] as int?,
      kdfVersion: map['kdf_version'] as int?,
      kdfSalt: map['kdf_salt'] as String?,
      nonce: map['nonce'] as String?,
      mac: map['mac'] as String?,
      aad: map['aad'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory BackupManifest.fromJson(String json) =>
      BackupManifest.fromMap(jsonDecode(json) as Map<String, dynamic>);
}

/// Representation of an extracted, staged backup awaiting validation.
class StagedBackup {
  final Directory stagingDir;
  final File stagedDbFile;
  final BackupManifest manifest;
  final bool isEncrypted;

  const StagedBackup({
    required this.stagingDir,
    required this.stagedDbFile,
    required this.manifest,
    this.isEncrypted = false,
  });

  Future<void> cleanup() async {
    try {
      if (await stagingDir.exists()) {
        await stagingDir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

/// Comprehensive validator for canonical SpendX backup packages and staged databases.
class CanonicalBackupValidator {
  const CanonicalBackupValidator._();

  /// Validates the high-level manifest metadata.
  static void validateManifest(BackupManifest manifest) {
    if (manifest.formatVersion != BackupManifest.currentFormatVersion) {
      throw UnsupportedBackupVersionException(
        'Unsupported backup format version: ${manifest.formatVersion}. Expected ${BackupManifest.currentFormatVersion}.',
      );
    }
    if (manifest.schemaVersion != BackupManifest.currentSchemaVersion) {
      throw UnsupportedBackupVersionException(
        'Incompatible schema version: ${manifest.schemaVersion}. Expected ${BackupManifest.currentSchemaVersion}.',
      );
    }
    if (manifest.databaseSha256.isEmpty) {
      throw const BackupValidationException(
        'Manifest missing database SHA-256 checksum.',
      );
    }
    if (manifest.debitTotal != manifest.creditTotal) {
      throw BackupValidationException(
        'Manifest debit total (${manifest.debitTotal}) does not equal credit total (${manifest.creditTotal}).',
      );
    }
  }

  /// Verifies the cryptographic SHA-256 hash of a database file against the manifest.
  static Future<void> verifyDatabaseHash(
    File dbFile,
    String expectedSha256,
  ) async {
    if (!await dbFile.exists()) {
      throw BackupValidationException(
          'Database file does not exist: ${dbFile.path}');
    }
    final bytes = await dbFile.readAsBytes();
    final actualHash = sha256.convert(bytes).toString();
    if (actualHash.toLowerCase() != expectedSha256.toLowerCase()) {
      throw BackupValidationException(
        'Database SHA-256 checksum mismatch. Expected $expectedSha256, got $actualHash.',
      );
    }
  }

  /// Validates all SQLite, relational, double-entry, and domain invariants on a staged database.
  static Future<void> validateStagedDatabase(
    Database db,
    BackupManifest manifest,
  ) async {
    // 1. SQLite low-level integrity check
    final integrityRows = await db.rawQuery('PRAGMA integrity_check;');
    if (integrityRows.isEmpty) {
      throw const BackupValidationException(
          'PRAGMA integrity_check returned empty response.');
    }
    final integrityResult = integrityRows.first.values.first as String? ?? '';
    if (integrityResult.toLowerCase() != 'ok') {
      throw BackupValidationException(
          'SQLite integrity check failed: $integrityResult');
    }

    // 2. Foreign-key constraint validation
    final fkRows = await db.rawQuery('PRAGMA foreign_key_check;');
    if (fkRows.isNotEmpty) {
      throw BackupValidationException(
        'Database has ${fkRows.length} foreign key violations: $fkRows',
      );
    }

    // 3. User schema version check
    final verRows = await db.rawQuery('PRAGMA user_version;');
    final currentVer = verRows.first.values.first as int? ?? 0;
    if (currentVer != BackupManifest.currentSchemaVersion) {
      throw BackupValidationException(
        'Database user_version $currentVer does not match required ${BackupManifest.currentSchemaVersion}',
      );
    }

    // 4. Required Canonical Tables
    const requiredTables = [
      TablesV24.accounts,
      TablesV24.economicEvents,
      TablesV24.postings,
      TablesV24.evidence,
      TablesV24.assetEarmarks,
      TablesV24.recurringRules,
      TablesV24.expectedEvents,
      TablesV24.reviewCandidates,
      TablesV24.openingBalanceReconciliations,
    ];
    final tableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table';",
    );
    final presentTables = tableRows
        .map((r) => r['name'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toSet();

    for (final table in requiredTables) {
      if (!presentTables.contains(table)) {
        throw BackupValidationException('Required table missing: $table');
      }
    }

    // 5. Required Canonical Triggers (7/7 active triggers)
    const requiredTriggers = [
      'trg_economic_events_prevent_direct_posted_insert',
      'trg_economic_events_validate_posted',
      'trg_postings_prevent_insert_on_posted',
      'trg_postings_prevent_update_on_posted',
      'trg_postings_prevent_delete_on_posted',
      'trg_economic_events_prevent_mutation_on_posted',
      'trg_economic_events_prevent_delete_posted',
    ];
    final triggerRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger';",
    );
    final presentTriggers = triggerRows
        .map((r) => r['name'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .toSet();

    for (final trg in requiredTriggers) {
      if (!presentTriggers.contains(trg)) {
        throw BackupValidationException('Required trigger missing: $trg');
      }
    }

    // 6. Double-entry parity on all posted economic events
    final imbalanceRows = await db.rawQuery('''
      SELECT p.economic_event_id,
             SUM(CASE WHEN p.direction = 'debit' THEN p.amount_minor_units ELSE -p.amount_minor_units END) AS diff
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted'
      GROUP BY p.economic_event_id
      HAVING diff != 0;
    ''');
    if (imbalanceRows.isNotEmpty) {
      throw BackupValidationException(
        'Unbalanced posted events detected in staged database: ${imbalanceRows.length} events out of parity.',
      );
    }

    // 7. Non-negative and non-zero posting amounts
    final invalidPostings = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM ${TablesV24.postings}
      WHERE amount_minor_units <= 0;
    ''');
    final invalidCount =
        (invalidPostings.first['count'] as num?)?.toInt() ?? 0;
    if (invalidCount > 0) {
      throw BackupValidationException(
        'Found $invalidCount postings with non-positive minor unit amounts.',
      );
    }

    // 8. Orphaned postings check
    final orphanedPostings = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM ${TablesV24.postings}
      WHERE account_id NOT IN (SELECT id FROM ${TablesV24.accounts});
    ''');
    final orphanCount =
        (orphanedPostings.first['count'] as num?)?.toInt() ?? 0;
    if (orphanCount > 0) {
      throw BackupValidationException(
        'Found $orphanCount postings referencing nonexistent accounts.',
      );
    }

    // 9. System Accounts Presence
    final systemAccounts = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM ${TablesV24.accounts}
      WHERE is_system = 1;
    ''');
    final systemCount = (systemAccounts.first['count'] as num?)?.toInt() ?? 0;
    if (systemCount < 9) {
      throw BackupValidationException(
        'Missing required system accounts in staged database (found $systemCount of 9 required).',
      );
    }

    // 10. Review Candidates Isolation:
    // Pending review candidates must NOT be associated with posted economic events.
    final leakedReviews = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM ${TablesV24.reviewCandidates} rc
      JOIN ${TablesV24.economicEvents} ee ON rc.id = ee.id
      WHERE rc.status = 'pending';
    ''');
    final leakCount = (leakedReviews.first['count'] as num?)?.toInt() ?? 0;
    if (leakCount > 0) {
      throw BackupValidationException(
        'Review candidates in pending status have generated events/postings ($leakCount detected).',
      );
    }

    // 11. Earmarks Validation
    final invalidEarmarks = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM ${TablesV24.assetEarmarks}
      WHERE amount_minor_units <= 0
         OR asset_account_id NOT IN (SELECT id FROM ${TablesV24.accounts});
    ''');
    final earmarkViolations =
        (invalidEarmarks.first['count'] as num?)?.toInt() ?? 0;
    if (earmarkViolations > 0) {
      throw BackupValidationException(
        'Found $earmarkViolations invalid asset earmarks with non-positive amounts or missing accounts.',
      );
    }

    // 12. Privacy Scrubbing: Purge any raw SMS payloads whose retention has expired
    await scrubExpiredEvidence(db);
  }

  /// Purges raw encrypted payloads for evidence whose 30-day retention has expired.
  /// Preserves all structured forensic and deduplication metadata.
  static Future<int> scrubExpiredEvidence(Database db) async {
    return await db.rawUpdate('''
      UPDATE ${TablesV24.evidence}
      SET raw_payload_encrypted = NULL,
          is_payload_purged = 1
      WHERE retention_expires_at IS NOT NULL
        AND retention_expires_at <= datetime('now')
        AND is_payload_purged = 0;
    ''');
  }

  /// Inspects a database and calculates all metrics required for manifest generation.
  static Future<Map<String, dynamic>> computeDatabaseMetrics(
      Database db) async {
    // 1. Table row counts
    final tableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';",
    );
    final counts = <String, int>{};
    for (final r in tableRows) {
      final name = r['name'] as String;
      final countRow =
          await db.rawQuery('SELECT COUNT(*) as count FROM "$name";');
      counts[name] = (countRow.first['count'] as num?)?.toInt() ?? 0;
    }

    // 2. Debit & Credit totals for posted events
    final parityRow = await db.rawQuery('''
      SELECT 
        COALESCE(SUM(CASE WHEN p.direction = 'debit' THEN p.amount_minor_units ELSE 0 END), 0) AS debit_total,
        COALESCE(SUM(CASE WHEN p.direction = 'credit' THEN p.amount_minor_units ELSE 0 END), 0) AS credit_total
      FROM ${TablesV24.postings} p
      JOIN ${TablesV24.economicEvents} e ON p.economic_event_id = e.id
      WHERE e.lifecycle_status = 'posted';
    ''');

    final debitTotal =
        (parityRow.first['debit_total'] as num?)?.toInt() ?? 0;
    final creditTotal =
        (parityRow.first['credit_total'] as num?)?.toInt() ?? 0;

    return {
      'record_counts': counts,
      'canonical_event_count': counts[TablesV24.economicEvents] ?? 0,
      'posting_count': counts[TablesV24.postings] ?? 0,
      'evidence_count': counts[TablesV24.evidence] ?? 0,
      'review_candidate_count': counts[TablesV24.reviewCandidates] ?? 0,
      'debit_total': debitTotal,
      'credit_total': creditTotal,
    };
  }
}
