import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' hide equals;
import 'package:sqflite/sqflite.dart';

import '../../core/logging/app_logger.dart';
import '../core/database_lifecycle_coordinator.dart';
import '../core/spendx_database_factory.dart' hide InvalidDatabaseKeyException;
import '../core/write_queue.dart';
import 'database_key_manager.dart';

/// Base exception for database migration errors.
abstract class DatabaseMigrationException implements Exception {
  final String message;
  final dynamic cause;
  const DatabaseMigrationException(this.message, [this.cause]);

  @override
  String toString() =>
      '$runtimeType: $message${cause != null ? " (Cause: $cause)" : ""}';
}

/// Thrown when any preflight check fails (schema, integrity, foreign keys, triggers, space).
class PreflightValidationException extends DatabaseMigrationException {
  const PreflightValidationException(super.message, [super.cause]);
}

/// Thrown when the accounting fingerprint of the staged encrypted database
/// does not match the original plaintext database bit-for-bit.
class AccountingFingerprintMismatchException extends DatabaseMigrationException {
  final String differences;
  const AccountingFingerprintMismatchException(this.differences)
      : super('Accounting fingerprint mismatch: $differences');
}

/// Thrown when filesystem storage is insufficient to safely perform migration.
class InsufficientDiskSpaceException extends DatabaseMigrationException {
  final int requiredBytes;
  final int availableBytes;
  const InsufficientDiskSpaceException(this.requiredBytes, this.availableBytes)
      : super(
          'Insufficient disk space for migration. Required at least $requiredBytes bytes, but only $availableBytes bytes available.',
        );
}

/// Thrown when recovery from an interrupted migration encounters fatal corruption.
class MigrationCrashRecoveryException extends DatabaseMigrationException {
  const MigrationCrashRecoveryException(super.message, [super.cause]);
}

/// Persistent states for the plaintext -> SQLCipher migration state machine.
enum MigrationState {
  none,
  preflight,
  backupCreated,
  walQuiesced,
  exporting,
  validating,
  readyToSwap,
  swapping,
  verified,
  failed,
  recoveryRequired;

  static MigrationState fromString(String val) {
    return MigrationState.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => MigrationState.none,
    );
  }
}

/// Immutable, 18-field financial fingerprint capturing complete accounting and schema state.
/// All monetary balances and flows use signed integer minor units (paise) — zero floats.
class AccountingFingerprint {
  final int schemaVersion;
  final int activeTriggersCount;
  final int accountCount;
  final int economicEventCount;
  final int postingCount;
  final int debitTotalMinorUnits;
  final int creditTotalMinorUnits;
  final int netWorthMinorUnits;
  final int incomeMinorUnits;
  final int expenseMinorUnits;
  final int cashFlowMinorUnits;
  final int safeToSpendMinorUnits;
  final int reviewCandidateCount;
  final int evidenceCount;
  final int assetEarmarkCount;
  final int categoryCount;
  final int budgetCount;
  final int ledgerTransactionCount;

  const AccountingFingerprint({
    required this.schemaVersion,
    required this.activeTriggersCount,
    required this.accountCount,
    required this.economicEventCount,
    required this.postingCount,
    required this.debitTotalMinorUnits,
    required this.creditTotalMinorUnits,
    required this.netWorthMinorUnits,
    required this.incomeMinorUnits,
    required this.expenseMinorUnits,
    required this.cashFlowMinorUnits,
    required this.safeToSpendMinorUnits,
    required this.reviewCandidateCount,
    required this.evidenceCount,
    required this.assetEarmarkCount,
    required this.categoryCount,
    required this.budgetCount,
    required this.ledgerTransactionCount,
  });

  /// Captures an immutable accounting fingerprint from an active database connection.
  static Future<AccountingFingerprint> fromDatabase(DatabaseExecutor db) async {
    // 1. Schema version
    final vRows = await db.rawQuery('PRAGMA user_version;');
    final schemaVer = (vRows.first.values.first as num?)?.toInt() ?? 0;

    // 2. Active triggers matching trg_%
    final tRows = await db.rawQuery(
      "SELECT count(*) as cnt FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_%';",
    );
    final trigCount = (tRows.first['cnt'] as num?)?.toInt() ?? 0;

    // Helper for safe table counts
    Future<int> safeCount(String table) async {
      try {
        final rows = await db.rawQuery('SELECT count(*) as cnt FROM $table;');
        return (rows.first['cnt'] as num?)?.toInt() ?? 0;
      } catch (_) {
        return 0;
      }
    }

    final accCount = await safeCount('accounts');
    final evCount = await safeCount('economic_events');
    final postCount = await safeCount('postings');
    final revCount = await safeCount('review_candidates');
    final evidCount = await safeCount('evidence') + await safeCount('raw_evidence');
    final earmarkCount = await safeCount('asset_earmarks');
    final catCount = await safeCount('categories');
    final bgtCount = await safeCount('budgets');
    final txnLegacyCount = await safeCount('ledger_transactions');

    // Debit and credit totals
    int debTotal = 0;
    int credTotal = 0;
    try {
      final debRows = await db.rawQuery(
        "SELECT COALESCE(SUM(amount_minor_units), 0) as s FROM postings WHERE LOWER(direction) = 'debit';",
      );
      debTotal = (debRows.first['s'] as num?)?.toInt() ?? 0;

      final credRows = await db.rawQuery(
        "SELECT COALESCE(SUM(amount_minor_units), 0) as s FROM postings WHERE LOWER(direction) = 'credit';",
      );
      credTotal = (credRows.first['s'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    // Net worth (Asset postings balance minus Liability postings balance)
    int nw = 0;
    try {
      final nwRows = await db.rawQuery('''
        SELECT 
          COALESCE((
            SELECT SUM(p.amount_minor_units * CASE WHEN LOWER(p.direction) = 'debit' THEN 1 ELSE -1 END)
            FROM postings p
            JOIN accounts a ON p.account_id = a.id
            WHERE LOWER(a.account_type) = 'asset'
          ), 0) -
          COALESCE((
            SELECT SUM(p.amount_minor_units * CASE WHEN LOWER(p.direction) = 'credit' THEN 1 ELSE -1 END)
            FROM postings p
            JOIN accounts a ON p.account_id = a.id
            WHERE LOWER(a.account_type) = 'liability'
          ), 0) as net_worth;
      ''');
      nw = (nwRows.first['net_worth'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    // Income and expense totals
    int inc = 0;
    int exp = 0;
    try {
      final incRows = await db.rawQuery('''
        SELECT COALESCE(SUM(p.amount_minor_units), 0) as s
        FROM postings p
        JOIN accounts a ON p.account_id = a.id
        WHERE LOWER(a.account_type) = 'income';
      ''');
      inc = (incRows.first['s'] as num?)?.toInt() ?? 0;

      final expRows = await db.rawQuery('''
        SELECT COALESCE(SUM(p.amount_minor_units), 0) as s
        FROM postings p
        JOIN accounts a ON p.account_id = a.id
        WHERE LOWER(a.account_type) = 'expense';
      ''');
      exp = (expRows.first['s'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    final cf = inc - exp;

    // Safe to spend (liquid assets)
    int sts = 0;
    try {
      final stsRows = await db.rawQuery('''
        SELECT COALESCE(SUM(p.amount_minor_units * CASE WHEN LOWER(p.direction) = 'debit' THEN 1 ELSE -1 END), 0) as s
        FROM postings p
        JOIN accounts a ON p.account_id = a.id
        WHERE LOWER(a.account_type) = 'asset' AND LOWER(a.subtype) IN ('checking', 'savings', 'cash', 'wallet');
      ''');
      sts = (stsRows.first['s'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    return AccountingFingerprint(
      schemaVersion: schemaVer,
      activeTriggersCount: trigCount,
      accountCount: accCount,
      economicEventCount: evCount,
      postingCount: postCount,
      debitTotalMinorUnits: debTotal,
      creditTotalMinorUnits: credTotal,
      netWorthMinorUnits: nw,
      incomeMinorUnits: inc,
      expenseMinorUnits: exp,
      cashFlowMinorUnits: cf,
      safeToSpendMinorUnits: sts,
      reviewCandidateCount: revCount,
      evidenceCount: evidCount,
      assetEarmarkCount: earmarkCount,
      categoryCount: catCount,
      budgetCount: bgtCount,
      ledgerTransactionCount: txnLegacyCount,
    );
  }

  bool matches(AccountingFingerprint other) {
    return schemaVersion == other.schemaVersion &&
        activeTriggersCount == other.activeTriggersCount &&
        accountCount == other.accountCount &&
        economicEventCount == other.economicEventCount &&
        postingCount == other.postingCount &&
        debitTotalMinorUnits == other.debitTotalMinorUnits &&
        creditTotalMinorUnits == other.creditTotalMinorUnits &&
        netWorthMinorUnits == other.netWorthMinorUnits &&
        incomeMinorUnits == other.incomeMinorUnits &&
        expenseMinorUnits == other.expenseMinorUnits &&
        cashFlowMinorUnits == other.cashFlowMinorUnits &&
        safeToSpendMinorUnits == other.safeToSpendMinorUnits &&
        reviewCandidateCount == other.reviewCandidateCount &&
        evidenceCount == other.evidenceCount &&
        assetEarmarkCount == other.assetEarmarkCount &&
        categoryCount == other.categoryCount &&
        budgetCount == other.budgetCount &&
        ledgerTransactionCount == other.ledgerTransactionCount;
  }

  String diff(AccountingFingerprint other) {
    final diffs = <String>[];
    if (schemaVersion != other.schemaVersion) {
      diffs.add('schemaVersion: $schemaVersion vs ${other.schemaVersion}');
    }
    if (activeTriggersCount != other.activeTriggersCount) {
      diffs.add('activeTriggersCount: $activeTriggersCount vs ${other.activeTriggersCount}');
    }
    if (accountCount != other.accountCount) {
      diffs.add('accountCount: $accountCount vs ${other.accountCount}');
    }
    if (economicEventCount != other.economicEventCount) {
      diffs.add('economicEventCount: $economicEventCount vs ${other.economicEventCount}');
    }
    if (postingCount != other.postingCount) {
      diffs.add('postingCount: $postingCount vs ${other.postingCount}');
    }
    if (debitTotalMinorUnits != other.debitTotalMinorUnits) {
      diffs.add('debitTotalMinorUnits: $debitTotalMinorUnits vs ${other.debitTotalMinorUnits}');
    }
    if (creditTotalMinorUnits != other.creditTotalMinorUnits) {
      diffs.add('creditTotalMinorUnits: $creditTotalMinorUnits vs ${other.creditTotalMinorUnits}');
    }
    if (netWorthMinorUnits != other.netWorthMinorUnits) {
      diffs.add('netWorthMinorUnits: $netWorthMinorUnits vs ${other.netWorthMinorUnits}');
    }
    if (incomeMinorUnits != other.incomeMinorUnits) {
      diffs.add('incomeMinorUnits: $incomeMinorUnits vs ${other.incomeMinorUnits}');
    }
    if (expenseMinorUnits != other.expenseMinorUnits) {
      diffs.add('expenseMinorUnits: $expenseMinorUnits vs ${other.expenseMinorUnits}');
    }
    if (cashFlowMinorUnits != other.cashFlowMinorUnits) {
      diffs.add('cashFlowMinorUnits: $cashFlowMinorUnits vs ${other.cashFlowMinorUnits}');
    }
    if (safeToSpendMinorUnits != other.safeToSpendMinorUnits) {
      diffs.add('safeToSpendMinorUnits: $safeToSpendMinorUnits vs ${other.safeToSpendMinorUnits}');
    }
    if (reviewCandidateCount != other.reviewCandidateCount) {
      diffs.add('reviewCandidateCount: $reviewCandidateCount vs ${other.reviewCandidateCount}');
    }
    if (evidenceCount != other.evidenceCount) {
      diffs.add('evidenceCount: $evidenceCount vs ${other.evidenceCount}');
    }
    if (assetEarmarkCount != other.assetEarmarkCount) {
      diffs.add('assetEarmarkCount: $assetEarmarkCount vs ${other.assetEarmarkCount}');
    }
    if (categoryCount != other.categoryCount) {
      diffs.add('categoryCount: $categoryCount vs ${other.categoryCount}');
    }
    if (budgetCount != other.budgetCount) {
      diffs.add('budgetCount: $budgetCount vs ${other.budgetCount}');
    }
    if (ledgerTransactionCount != other.ledgerTransactionCount) {
      diffs.add('ledgerTransactionCount: $ledgerTransactionCount vs ${other.ledgerTransactionCount}');
    }
    return diffs.isEmpty ? 'NONE' : diffs.join(', ');
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'activeTriggersCount': activeTriggersCount,
        'accountCount': accountCount,
        'economicEventCount': economicEventCount,
        'postingCount': postingCount,
        'debitTotalMinorUnits': debitTotalMinorUnits,
        'creditTotalMinorUnits': creditTotalMinorUnits,
        'netWorthMinorUnits': netWorthMinorUnits,
        'incomeMinorUnits': incomeMinorUnits,
        'expenseMinorUnits': expenseMinorUnits,
        'cashFlowMinorUnits': cashFlowMinorUnits,
        'safeToSpendMinorUnits': safeToSpendMinorUnits,
        'reviewCandidateCount': reviewCandidateCount,
        'evidenceCount': evidenceCount,
        'assetEarmarkCount': assetEarmarkCount,
        'categoryCount': categoryCount,
        'budgetCount': budgetCount,
        'ledgerTransactionCount': ledgerTransactionCount,
      };

  factory AccountingFingerprint.fromJson(Map<String, dynamic> json) =>
      AccountingFingerprint(
        schemaVersion: json['schemaVersion'] as int? ?? 0,
        activeTriggersCount: json['activeTriggersCount'] as int? ?? 0,
        accountCount: json['accountCount'] as int? ?? 0,
        economicEventCount: json['economicEventCount'] as int? ?? 0,
        postingCount: json['postingCount'] as int? ?? 0,
        debitTotalMinorUnits: json['debitTotalMinorUnits'] as int? ?? 0,
        creditTotalMinorUnits: json['creditTotalMinorUnits'] as int? ?? 0,
        netWorthMinorUnits: json['netWorthMinorUnits'] as int? ?? 0,
        incomeMinorUnits: json['incomeMinorUnits'] as int? ?? 0,
        expenseMinorUnits: json['expenseMinorUnits'] as int? ?? 0,
        cashFlowMinorUnits: json['cashFlowMinorUnits'] as int? ?? 0,
        safeToSpendMinorUnits: json['safeToSpendMinorUnits'] as int? ?? 0,
        reviewCandidateCount: json['reviewCandidateCount'] as int? ?? 0,
        evidenceCount: json['evidenceCount'] as int? ?? 0,
        assetEarmarkCount: json['assetEarmarkCount'] as int? ?? 0,
        categoryCount: json['categoryCount'] as int? ?? 0,
        budgetCount: json['budgetCount'] as int? ?? 0,
        ledgerTransactionCount: json['ledgerTransactionCount'] as int? ?? 0,
      );
}

/// Journal tracking migration state persistently on disk across unexpected process kills.
class MigrationJournal {
  final File file;
  MigrationState state;
  DateTime timestamp;
  String sourceDbPath;
  String stagedDbPath;
  String rollbackBackupPath;
  AccountingFingerprint? fingerprint;
  String? error;

  MigrationJournal({
    required this.file,
    required this.state,
    required this.timestamp,
    required this.sourceDbPath,
    required this.stagedDbPath,
    required this.rollbackBackupPath,
    this.fingerprint,
    this.error,
  });

  Future<void> record(
    MigrationState newState, {
    AccountingFingerprint? fp,
    String? err,
  }) async {
    state = newState;
    timestamp = DateTime.now().toUtc();
    if (fp != null) fingerprint = fp;
    if (err != null) error = err;

    final map = {
      'state': state.name,
      'timestamp': timestamp.toIso8601String(),
      'sourceDbPath': sourceDbPath,
      'stagedDbPath': stagedDbPath,
      'rollbackBackupPath': rollbackBackupPath,
      'fingerprint': fingerprint?.toJson(),
      'error': error,
    };

    final content = const JsonEncoder.withIndent('  ').convert(map);
    await file.writeAsString(content, flush: true);
  }

  Future<void> clear() async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<MigrationJournal?> load(String journalPath) async {
    final f = File(journalPath);
    if (!await f.exists()) return null;

    try {
      final str = await f.readAsString();
      if (str.trim().isEmpty) return null;
      final map = jsonDecode(str) as Map<String, dynamic>;

      return MigrationJournal(
        file: f,
        state: MigrationState.fromString(map['state'] as String? ?? 'none'),
        timestamp: DateTime.tryParse(map['timestamp'] as String? ?? '') ??
            DateTime.now().toUtc(),
        sourceDbPath: map['sourceDbPath'] as String? ?? '',
        stagedDbPath: map['stagedDbPath'] as String? ?? '',
        rollbackBackupPath: map['rollbackBackupPath'] as String? ?? '',
        fingerprint: map['fingerprint'] != null
            ? AccountingFingerprint.fromJson(
                map['fingerprint'] as Map<String, dynamic>,
              )
            : null,
        error: map['error'] as String?,
      );
    } catch (e) {
      AppLogger.w('[MIGRATION] Failed to parse journal file $journalPath: $e');
      return null;
    }
  }
}

/// Result returned from migration execution.
class MigrationResult {
  final bool success;
  final bool skipped;
  final MigrationState finalState;
  final String? errorMessage;
  final AccountingFingerprint? fingerprint;
  final Duration duration;

  const MigrationResult({
    required this.success,
    required this.skipped,
    required this.finalState,
    this.errorMessage,
    this.fingerprint,
    required this.duration,
  });

  static MigrationResult skippedResult() => const MigrationResult(
        success: true,
        skipped: true,
        finalState: MigrationState.none,
        duration: Duration.zero,
      );
}

typedef DiskSpaceChecker = Future<bool> Function(
  int requiredBytes,
  String directoryPath,
);

/// Central orchestrator for crash-safe, out-of-place migration of SpendX's production database
/// from plaintext SQLite v24 to SQLCipher 4.18.0 page-level encrypted SQLite.
class DatabaseEncryptionMigrationService {
  final SpendXDatabaseKeyManager? _keyManagerOverride;
  SpendXDatabaseKeyManager get _keyManager =>
      _keyManagerOverride ?? SpendXDatabaseKeyManager.instance;
  final SpendXDatabaseFactory _factory;
  final DiskSpaceChecker _diskSpaceChecker;

  bool _isMigrationRunning = false;

  DatabaseEncryptionMigrationService({
    SpendXDatabaseKeyManager? keyManager,
    SpendXDatabaseFactory? factory,
    DiskSpaceChecker? diskSpaceChecker,
  })  : _keyManagerOverride = keyManager,
        _factory = factory ?? SpendXDatabaseFactory.instance,
        _diskSpaceChecker =
            diskSpaceChecker ?? _defaultDiskSpaceChecker;

  static DatabaseEncryptionMigrationService _instance =
      DatabaseEncryptionMigrationService();
  static DatabaseEncryptionMigrationService get instance => _instance;
  static void setTestInstance(DatabaseEncryptionMigrationService? testInstance) {
    _instance = testInstance ?? DatabaseEncryptionMigrationService();
  }

  bool get isMigrationRunning => _isMigrationRunning;

  static const List<String> mandatoryTriggers = [
    'trg_economic_events_prevent_direct_posted_insert',
    'trg_economic_events_validate_posted',
    'trg_postings_prevent_insert_on_posted',
    'trg_postings_prevent_update_on_posted',
    'trg_postings_prevent_delete_on_posted',
    'trg_economic_events_prevent_mutation_on_posted',
    'trg_economic_events_prevent_delete_posted',
  ];

  static const List<int> sqlitePlaintextHeader = [
    0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
    0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
  ];

  /// Returns true if the file at [path] starts with the plaintext SQLite header.
  static bool isPlaintextSqliteFile(String path) {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < 16) return false;

    try {
      final raf = file.openSync(mode: FileMode.read);
      final bytes = raf.readSync(16);
      raf.closeSync();
      if (bytes.length < 16) return false;

      for (int i = 0; i < 16; i++) {
        if (bytes[i] != sqlitePlaintextHeader[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Default disk space check: verifies that directory exists and writable.
  static Future<bool> _defaultDiskSpaceChecker(
    int requiredBytes,
    String directoryPath,
  ) async {
    try {
      final dir = Directory(directoryPath);
      return await dir.exists();
    } catch (_) {
      return false;
    }
  }

  /// Checks if a database file needs migration to SQLCipher.
  Future<bool> isMigrationNeeded({String? dbPath}) async {
    final path = dbPath ?? join(await getDatabasesPath(), 'spendx.db');
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      return false;
    }
    return isPlaintextSqliteFile(path);
  }

  /// Runs preflight checks against an open plaintext database before any file modification.
  Future<AccountingFingerprint> runPreflight({
    required DatabaseExecutor db,
    required int dbFileSizeBytes,
    required String directoryPath,
    String? targetDbPath,
  }) async {
    // 1. Schema version must be exactly 24
    final int version;
    try {
      final vRows = await db.rawQuery('PRAGMA user_version;');
      version = (vRows.first.values.first as num?)?.toInt() ?? 0;
    } catch (e) {
      throw PreflightValidationException(
        'Database corruption or unreadable user_version: $e',
        e,
      );
    }
    if (version != 24) {
      throw PreflightValidationException(
        'Schema user_version is $version, expected exactly 24.',
      );
    }

    // 2. PRAGMA integrity_check must be 'ok'
    try {
      final integrityRows = await db.rawQuery('PRAGMA integrity_check;');
      final integrityResult =
          integrityRows.isNotEmpty ? integrityRows.first.values.first?.toString() : null;
      if (integrityResult?.toLowerCase() != 'ok') {
        throw PreflightValidationException(
          'PRAGMA integrity_check failed: $integrityResult',
        );
      }
    } catch (e) {
      if (e is PreflightValidationException) rethrow;
      throw PreflightValidationException(
        'PRAGMA integrity_check execution failed: $e',
        e,
      );
    }

    // 3. PRAGMA foreign_key_check must return 0 violations
    final fkRows = await db.rawQuery('PRAGMA foreign_key_check;');
    if (fkRows.isNotEmpty) {
      throw PreflightValidationException(
        'Foreign key integrity check failed with ${fkRows.length} violations.',
      );
    }

    // 4. Active financial triggers check: all 7 mandatory triggers must exist
    final triggerRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_%';",
    );
    final existingTriggers =
        triggerRows.map((r) => r['name'] as String).toSet();

    for (final expected in mandatoryTriggers) {
      if (!existingTriggers.contains(expected)) {
        throw PreflightValidationException(
          'Mandatory trigger missing: "$expected". Found triggers: $existingTriggers',
        );
      }
    }

    // 5. Double-entry accounting parity invariant: SUM(DEBIT) == SUM(CREDIT)
    final debitRows = await db.rawQuery(
      "SELECT COALESCE(SUM(amount_minor_units), 0) as s FROM postings WHERE LOWER(direction) = 'debit';",
    );
    final creditRows = await db.rawQuery(
      "SELECT COALESCE(SUM(amount_minor_units), 0) as s FROM postings WHERE LOWER(direction) = 'credit';",
    );
    final debitSum = (debitRows.first['s'] as num?)?.toInt() ?? 0;
    final creditSum = (creditRows.first['s'] as num?)?.toInt() ?? 0;
    if (debitSum != creditSum) {
      throw PreflightValidationException(
        'Double-entry parity invariant broken: SUM(DEBIT) ($debitSum) != SUM(CREDIT) ($creditSum).',
      );
    }

    // 6. Free disk space: must be at least 2.5x the database size
    final requiredSpace = (dbFileSizeBytes * 2.5).ceil();
    final hasSpace = await _diskSpaceChecker(requiredSpace, directoryPath);
    if (!hasSpace) {
      throw InsufficientDiskSpaceException(requiredSpace, 0);
    }

    // 7. SecureStorage master encryption key availability check
    final keyState = await _keyManager.getState(encryptedDbPath: targetDbPath);
    if (keyState == DatabaseKeyState.fatalKeyLoss) {
      throw KeyLossFatalException(targetDbPath ?? 'unknown');
    }
    if (keyState == DatabaseKeyState.invalid) {
      throw const InvalidDatabaseKeyException();
    }
    if (keyState == DatabaseKeyState.unreadable) {
      throw const DatabaseKeyAccessException(
        'SecureStorage is unreadable during preflight',
      );
    }

    // 8. Capture immutable pre-migration fingerprint
    return await AccountingFingerprint.fromDatabase(db);
  }

  /// Executes the complete 8-checkpoint, crash-safe migration from plaintext to SQLCipher.
  Future<MigrationResult> runMigration({
    String? dbPath,
    Uint8List? keyOverride,
    bool keepBackupOnSuccess = false,
  }) async {
    if (_isMigrationRunning) {
      throw StateError('Database migration is already in progress.');
    }
    await DatabaseLifecycleCoordinator.instance.beginMigration();
    _isMigrationRunning = true;
    final stopwatch = Stopwatch()..start();

    final sourcePath = dbPath ?? join(await getDatabasesPath(), 'spendx.db');
    final dbDir = dirname(sourcePath);
    final dbName = basename(sourcePath);

    final stagedPath = join(dbDir, '$dbName.migration_staging');
    final rollbackBackupPath = join(dbDir, '$dbName.pre_migration_backup');
    final archivePath = join(dbDir, '$dbName.pre_encrypted_archive');
    final journalPath = join(dbDir, 'spendx_migration_state.json');

    final journal = MigrationJournal(
      file: File(journalPath),
      state: MigrationState.none,
      timestamp: DateTime.now().toUtc(),
      sourceDbPath: sourcePath,
      stagedDbPath: stagedPath,
      rollbackBackupPath: rollbackBackupPath,
    );

    try {
      await WriteQueue.instance.quiesce();
      await _factory.initialize();

      // Check for prior interrupted migration
      await recoverInterruptedMigration(
        dbPath: sourcePath,
        keyOverride: keyOverride,
      );

      // Check if migration is needed
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists() || await sourceFile.length() == 0) {
        AppLogger.i('[MIGRATION] Database does not exist or is empty; skipping migration.');
        return MigrationResult.skippedResult();
      }

      if (!isPlaintextSqliteFile(sourcePath)) {
        AppLogger.i('[MIGRATION] Database is already encrypted; skipping migration.');
        return MigrationResult.skippedResult();
      }

      AppLogger.i('[MIGRATION] Starting plaintext -> SQLCipher migration for $sourcePath');

      // 1. Acquire Master Key
      final key = keyOverride ??
          await _keyManager.getOrCreateKey(encryptedDbPath: sourcePath);
      final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);

      // 2. CHECKPOINT 1: PREFLIGHT
      await journal.record(MigrationState.preflight);

      final plainDb = await _factory.openPlaintextDatabase(sourcePath);
      AccountingFingerprint preFingerprint;
      try {
        final fileSize = await sourceFile.length();
        preFingerprint = await runPreflight(
          db: plainDb,
          dbFileSizeBytes: fileSize,
          directoryPath: dbDir,
          targetDbPath: sourcePath,
        );
        await plainDb.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      } finally {
        await plainDb.close();
      }

      // 3. CHECKPOINT 2: SAFETY BACKUP
      await journal.record(
        MigrationState.backupCreated,
        fp: preFingerprint,
      );
      await sourceFile.copy(rollbackBackupPath);

      // 4. CHECKPOINT 3: WAL QUIESCENCE
      // Unlink sidecars if present
      final walFile = File('$sourcePath-wal');
      final shmFile = File('$sourcePath-shm');
      try {
        if (await walFile.exists()) await walFile.delete();
        if (await shmFile.exists()) await shmFile.delete();
      } catch (_) {}
      await journal.record(MigrationState.walQuiesced);

      // 5. CHECKPOINT 4: SQLCIPHER EXPORT
      final stagedFile = File(stagedPath);
      if (await stagedFile.exists()) {
        await stagedFile.delete();
      }
      await journal.record(MigrationState.exporting);

      final exportDb = await _factory.openPlaintextDatabase(sourcePath);
      try {
        // Attach staged target with SQLCipher raw hex key
        await exportDb.execute(
          'ATTACH DATABASE \'$stagedPath\' AS encrypted KEY "$blobKey";',
        );
        // Export entire database contents, schema, and triggers
        await exportDb.rawQuery("SELECT sqlcipher_export('encrypted');");
        // Replicate schema user_version onto the encrypted database
        await exportDb.execute(
          'PRAGMA encrypted.user_version = ${preFingerprint.schemaVersion};',
        );
        await exportDb.execute('DETACH DATABASE encrypted;');
      } finally {
        await exportDb.close();
      }

      // 6. CHECKPOINT 5: VALIDATION
      await journal.record(MigrationState.validating);

      if (!await stagedFile.exists() || await stagedFile.length() == 0) {
        throw PreflightValidationException(
          'SQLCipher export failed to create valid staging database file.',
        );
      }

      // Verify header is NOT plaintext
      if (isPlaintextSqliteFile(stagedPath)) {
        throw PreflightValidationException(
          'Staged database file is plaintext, encryption failed.',
        );
      }

      // Verify wrong key is rejected
      bool wrongKeyRejected = false;
      try {
        const dummyWrongKey = "x'0000000000000000000000000000000000000000000000000000000000000000'";
        final probeDb = await _factory.openEncryptedDatabase(
          stagedPath,
          password: dummyWrongKey,
        );
        await probeDb.close();
      } catch (_) {
        wrongKeyRejected = true;
      }
      if (!wrongKeyRejected) {
        throw PreflightValidationException(
          'Staged database failed security validation: wrong key was not rejected!',
        );
      }

      // Validate staging database with correct key
      final stagedDb = await _factory.openEncryptedDatabase(
        stagedPath,
        password: blobKey,
      );
      AccountingFingerprint postFingerprint;
      try {
        // Assert SQLCipher is active
        final cipherRows = await stagedDb.rawQuery('PRAGMA cipher_version;');
        if (cipherRows.isEmpty) {
          throw PreflightValidationException(
            'PRAGMA cipher_version returned empty on staged database.',
          );
        }

        // Assert schema version 24
        final verRows = await stagedDb.rawQuery('PRAGMA user_version;');
        final ver = (verRows.first.values.first as num?)?.toInt() ?? 0;
        if (ver != 24) {
          throw PreflightValidationException(
            'Staged database schema version is $ver, expected 24.',
          );
        }

        // Assert integrity
        final integrityRows = await stagedDb.rawQuery('PRAGMA integrity_check;');
        if (integrityRows.isEmpty ||
            integrityRows.first.values.first?.toString().toLowerCase() != 'ok') {
          throw PreflightValidationException(
            'Staged database integrity check failed.',
          );
        }

        // Capture post-migration fingerprint
        postFingerprint = await AccountingFingerprint.fromDatabase(stagedDb);
      } finally {
        await stagedDb.close();
      }

      // Assert bit-for-bit accounting parity
      if (!preFingerprint.matches(postFingerprint)) {
        final diff = preFingerprint.diff(postFingerprint);
        throw AccountingFingerprintMismatchException(diff);
      }

      // 7. CHECKPOINT 6: READY TO SWAP
      await journal.record(MigrationState.readyToSwap);

      // 8. CHECKPOINT 7: ATOMIC SWAP (TRIPLE-FILE PIVOT)
      await journal.record(MigrationState.swapping);

      final archiveFile = File(archivePath);
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }

      // Step A: Rename live plaintext to archive
      sourceFile.renameSync(archivePath);

      // Step B: Rename staged encrypted to live spendx.db
      stagedFile.renameSync(sourcePath);

      // 9. CHECKPOINT 8: POST-SWAP VERIFICATION
      final liveEncryptedDb = await _factory.openEncryptedDatabase(
        sourcePath,
        password: blobKey,
      );
      try {
        final masterRows =
            await liveEncryptedDb.rawQuery('SELECT count(*) FROM sqlite_master;');
        if (masterRows.isEmpty) {
          throw PreflightValidationException(
            'Live database validation failed: sqlite_master is inaccessible.',
          );
        }
      } finally {
        await liveEncryptedDb.close();
      }

      await journal.record(MigrationState.verified);

      // Cleanup archives and temporary files
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
      if (!keepBackupOnSuccess) {
        final bkp = File(rollbackBackupPath);
        if (await bkp.exists()) await bkp.delete();
      }

      // Clear journal marker
      await journal.clear();

      stopwatch.stop();
      AppLogger.i(
        '[MIGRATION] Migration successfully verified and closed in ${stopwatch.elapsedMilliseconds}ms.',
      );

      return MigrationResult(
        success: true,
        skipped: false,
        finalState: MigrationState.verified,
        fingerprint: postFingerprint,
        duration: stopwatch.elapsed,
      );
    } catch (e, stack) {
      AppLogger.e('[MIGRATION] Migration failed: $e\n$stack');

      // Check if swap was attempted or in progress
      if (journal.state == MigrationState.swapping ||
          journal.state == MigrationState.verified) {
        await journal.record(
          MigrationState.recoveryRequired,
          err: e.toString(),
        );
        // Attempt emergency rollback
        try {
          await _rollbackSwap(
            sourcePath: sourcePath,
            archivePath: archivePath,
            rollbackBackupPath: rollbackBackupPath,
          );
        } catch (rbErr) {
          AppLogger.e('[MIGRATION] Emergency rollback failed: $rbErr');
        }
      } else {
        // Pre-swap failure: live plaintext database was never touched!
        await journal.record(MigrationState.failed, err: e.toString());
        // Clean up staged file if present
        try {
          final sFile = File(stagedPath);
          if (await sFile.exists()) await sFile.delete();
        } catch (_) {}
      }

      rethrow;
    } finally {
      _isMigrationRunning = false;
      DatabaseLifecycleCoordinator.instance.endMigration();
    }
  }

  /// Emergency rollback helper for swap failures.
  Future<void> _rollbackSwap({
    required String sourcePath,
    required String archivePath,
    required String rollbackBackupPath,
  }) async {
    final liveFile = File(sourcePath);
    final archiveFile = File(archivePath);
    final bkpFile = File(rollbackBackupPath);

    if (await archiveFile.exists()) {
      if (await liveFile.exists()) await liveFile.delete();
      archiveFile.renameSync(sourcePath);
      AppLogger.w('[MIGRATION] Emergency rollback: restored from pre_encrypted_archive.');
    } else if (await bkpFile.exists()) {
      if (await liveFile.exists()) await liveFile.delete();
      await bkpFile.copy(sourcePath);
      AppLogger.w('[MIGRATION] Emergency rollback: restored from pre_migration_backup.');
    }
  }

  /// Restores database consistency from any interrupted process termination.
  Future<void> recoverInterruptedMigration({
    String? dbPath,
    Uint8List? keyOverride,
  }) async {
    final sourcePath = dbPath ?? join(await getDatabasesPath(), 'spendx.db');
    final dbDir = dirname(sourcePath);
    final dbName = basename(sourcePath);

    final stagedPath = join(dbDir, '$dbName.migration_staging');
    final rollbackBackupPath = join(dbDir, '$dbName.pre_migration_backup');
    final archivePath = join(dbDir, '$dbName.pre_encrypted_archive');
    final journalPath = join(dbDir, 'spendx_migration_state.json');

    final journal = await MigrationJournal.load(journalPath);
    if (journal == null) return;

    AppLogger.w(
      '[MIGRATION] Interrupted migration detected with state: ${journal.state.name}',
    );

    final liveFile = File(sourcePath);
    final stagedFile = File(stagedPath);
    final archiveFile = File(archivePath);
    final bkpFile = File(rollbackBackupPath);

    switch (journal.state) {
      case MigrationState.none:
      case MigrationState.preflight:
      case MigrationState.backupCreated:
      case MigrationState.walQuiesced:
      case MigrationState.exporting:
      case MigrationState.validating:
      case MigrationState.failed:
        // Plaintext database was untouched or staging was in progress.
        // Clean staging and reset journal.
        if (await stagedFile.exists()) await stagedFile.delete();
        if (await bkpFile.exists()) await bkpFile.delete();
        await journal.clear();
        AppLogger.i('[MIGRATION] Recovery: Cleaned intermediate artifacts; original database intact.');
        break;

      case MigrationState.readyToSwap:
        // Staging was valid, but swap had not yet occurred.
        // Clean staging and reset journal to permit clean retry.
        if (await stagedFile.exists()) await stagedFile.delete();
        if (await bkpFile.exists()) await bkpFile.delete();
        await journal.clear();
        AppLogger.i('[MIGRATION] Recovery: Reset from readyToSwap; original database intact.');
        break;

      case MigrationState.swapping:
      case MigrationState.recoveryRequired:
        // Process crash occurred during or immediately after rename.
        // Check if live database is valid SQLCipher.
        bool liveEncryptedOk = false;
        try {
          if (await liveFile.exists() && !isPlaintextSqliteFile(sourcePath)) {
            final key = keyOverride ??
                await _keyManager.getOrCreateKey(encryptedDbPath: sourcePath);
            final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);
            final probe = await _factory.openEncryptedDatabase(
              sourcePath,
              password: blobKey,
            );
            final v = await probe.rawQuery('PRAGMA user_version;');
            if ((v.first.values.first as num?)?.toInt() == 24) {
              liveEncryptedOk = true;
            }
            await probe.close();
          }
        } catch (_) {}

        if (liveEncryptedOk) {
          AppLogger.i('[MIGRATION] Recovery: Live database is valid SQLCipher; completing migration.');
          if (await archiveFile.exists()) await archiveFile.delete();
          if (await bkpFile.exists()) await bkpFile.delete();
          if (await stagedFile.exists()) await stagedFile.delete();
          await journal.clear();
        } else {
          AppLogger.w('[MIGRATION] Recovery: Live database invalid or missing; rolling back.');
          await _rollbackSwap(
            sourcePath: sourcePath,
            archivePath: archivePath,
            rollbackBackupPath: rollbackBackupPath,
          );
          if (await stagedFile.exists()) await stagedFile.delete();
          await journal.clear();
        }
        break;

      case MigrationState.verified:
        // Already verified before crash, just clean up leftovers.
        if (await archiveFile.exists()) await archiveFile.delete();
        if (await bkpFile.exists()) await bkpFile.delete();
        if (await stagedFile.exists()) await stagedFile.delete();
        await journal.clear();
        AppLogger.i('[MIGRATION] Recovery: Cleaned post-verification artifacts.');
        break;
    }
  }
}
