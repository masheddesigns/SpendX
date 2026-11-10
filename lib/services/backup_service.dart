import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/logging/app_logger.dart';
import '../data/core/app_database.dart';
import '../data/providers.dart';
import 'auth_service.dart';
import 'backup_encryption.dart';
import 'backup_file_service.dart';
import 'canonical_backup_validator.dart';
import 'data_change_bus.dart';
import 'drive_service.dart';
import 'notification_service_v2.dart';
import 'settings_service.dart';
import '../data/core/canonical_path_validator.dart';
import '../data/core/database_lifecycle_coordinator.dart';
import '../data/core/database_access_gate.dart';
import '../data/core/write_queue.dart';
import 'platform_process_lock_service.dart';
import '../data/core/tables_v24.dart';
import '../data/security/database_key_manager.dart';
import '../data/core/restore_recovery_service.dart';
import '../data/security/database_encryption_migration_service.dart';


/// BackupService — Canonical SpendX 2.0 backup and restore orchestrator.
///
/// Features:
/// - Atomic `.spendx` package creation with SQLite native snapshot (`VACUUM INTO`).
/// - SHA-256 cryptographic manifest verification.
/// - In-depth pre-restore validation (SQLite integrity, foreign keys, double-entry parity).
/// - 30-day raw SMS privacy scrubbing before backup and after restore.
/// - Atomic staging database replacement with automatic rollback on error.
/// - Centralized Riverpod provider invalidation.
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const String _deviceIdKey = 'spendx_device_id';
  static const String _lastBackupAtKey = 'spendx_last_backup_at';

  bool _busy = false;
  DateTime? _lastBackupAt;
  Timer? _autoBackupTimer;
  Timer? _debounceTimer;

  bool get isBackupRunning => _busy;
  bool get isBusy => _busy;
  DateTime? get lastBackupAt => _lastBackupAt;

  /// Test-only injection seam for temporary staging directory creation.
  @visibleForTesting
  static Future<Directory> Function(String prefix)? stagingDirectoryCreatorForTesting;

  @visibleForTesting
  static bool failWalCheckpointForTesting = false;

  @visibleForTesting
  static bool failConnectionCloseForTesting = false;

  @visibleForTesting
  static bool failBackupCreationForTesting = false;

  @visibleForTesting
  static bool failFirstRenameForTesting = false;

  @visibleForTesting
  static bool failReplacementRenameForTesting = false;

  @visibleForTesting
  static bool failReopenForTesting = false;

  @visibleForTesting
  static bool failIntegrityValidationForTesting = false;

  @visibleForTesting
  static bool failRollbackForTesting = false;

  /// Test-only crash barrier hook invoked after recording each restore journal state.
  static Future<void> Function(RestoreJournalState phase, Directory dbDir, File? journalFile)? _crashBarrierForTesting;
  @visibleForTesting
  static Future<void> Function(RestoreJournalState phase, Directory dbDir, File? journalFile)? get crashBarrierForTesting =>
      !_isReleaseBuild ? _crashBarrierForTesting : null;
  @visibleForTesting
  static set crashBarrierForTesting(Future<void> Function(RestoreJournalState phase, Directory dbDir, File? journalFile)? value) {
    if (_isReleaseBuild) {
      throw UnsupportedError('crashBarrierForTesting cannot be set in release builds');
    }
    _crashBarrierForTesting = value;
  }

  /// Test-only safeguard to abort any operation targeting production `spendx.db`.
  static bool _enforceDisposableIsolation = false;
  @visibleForTesting
  static bool get enforceDisposableIsolation => !_isReleaseBuild && _enforceDisposableIsolation;
  @visibleForTesting
  static set enforceDisposableIsolation(bool value) {
    if (_isReleaseBuild) {
      throw UnsupportedError('enforceDisposableIsolation cannot be set in release builds');
    }
    _enforceDisposableIsolation = value;
  }

  static bool get _isReleaseBuild => const bool.fromEnvironment('dart.vm.product');

  @visibleForTesting
  static void resetTestingFlags() {
    if (!_isReleaseBuild) {
      stagingDirectoryCreatorForTesting = null;
      failWalCheckpointForTesting = false;
      failConnectionCloseForTesting = false;
      failBackupCreationForTesting = false;
      failFirstRenameForTesting = false;
      failReplacementRenameForTesting = false;
      failReopenForTesting = false;
      failIntegrityValidationForTesting = false;
      failRollbackForTesting = false;
      _crashBarrierForTesting = null;
      _enforceDisposableIsolation = false;
    }
  }

  static final Set<String> _activeStagingPaths = <String>{};

  // ─── Initialization ──────────────────────────────────────────

  Future<void> initialize() async {
    await _getOrCreateDeviceId();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_lastBackupAtKey);
    if (saved != null) _lastBackupAt = DateTime.tryParse(saved);
    _log('initialized (lastBackup: $_lastBackupAt)');

    // Listen for data changes — auto-backup with 30s debounce
    DataChangeBus.instance.addListener(_onDataChanged);

    // Restore auto-backup timer if Drive is connected and interval configured
    startAutoBackupTimer();
  }

  void _onDataChanged() {
    if (!SettingsService.instance.autoBackupEnabled) return;
    if (!DriveService.instance.isInitialized) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 30), () {
      _log('auto-backup: triggered by data change');
      backupNow();
    });
  }

  void startAutoBackupTimer() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;

    final settings = SettingsService.instance;
    if (!settings.autoBackupEnabled) return;
    final intervalHours = settings.backupIntervalHours;
    if (intervalHours <= 0) return;
    if (!AuthService.instance.isSignedIn) return;

    final duration = Duration(hours: intervalHours);
    _log('auto-backup: timer started (every ${intervalHours}h)');
    _autoBackupTimer = Timer.periodic(duration, (_) async {
      _log('auto-backup: timer fired');
      await backupNow();
    });
  }

  void stopAutoBackupTimer() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;
    _log('auto-backup: timer stopped');
  }

  String? _inMemoryDeviceId;

  Future<String> _getOrCreateDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_deviceIdKey);
      if (id == null) {
        id = const Uuid().v4();
        await prefs.setString(_deviceIdKey, id);
      }
      return id;
    } catch (_) {
      _inMemoryDeviceId ??= const Uuid().v4();
      return _inMemoryDeviceId!;
    }
  }

  Future<String> getDeviceId() => _getOrCreateDeviceId();

  Future<String> _getDeviceName() async {
    try {
      if (Platform.isAndroid) {
        final result = await Process.run('getprop', ['ro.product.model']);
        final model = result.stdout.toString().trim();
        if (model.isNotEmpty) return model;
      }
    } catch (_) {}
    return Platform.operatingSystem;
  }

  /// Fetch connected devices from Drive metadata.
  Future<List<Map<String, dynamic>>> getConnectedDevices() async {
    if (!DriveService.instance.isInitialized) return [];
    try {
      final meta = await DriveService.instance.downloadMetadata();
      if (meta == null || meta['devices'] is! Map) return [];

      final currentId = await _getOrCreateDeviceId();
      final devices = Map<String, dynamic>.from(meta['devices'] as Map);

      return devices.entries.map((e) {
        final info = e.value is Map
            ? Map<String, dynamic>.from(e.value as Map)
            : <String, dynamic>{};
        return {
          'id': e.key,
          'name': info['name'] ?? 'Unknown',
          'lastBackup': info['lastBackup'],
          'lastActive': info['lastActive'],
          'isCurrent': e.key == currentId,
        };
      }).toList()
        ..sort((a, b) {
          if (a['isCurrent'] == true) return -1;
          if (b['isCurrent'] == true) return 1;
          final aTime = a['lastActive'] as String? ?? '';
          final bTime = b['lastActive'] as String? ?? '';
          return bTime.compareTo(aTime);
        });
    } catch (e) {
      _log('getConnectedDevices error: $e');
      return [];
    }
  }

  // ─── Canonical Package Creation ──────────────────────────────

  /// Creates a canonical `.spendx` package containing the database snapshot and manifest.
  ///
  /// Can operate on production `AppDatabase` or a custom test database.
  Future<(File, BackupManifest)> createBackupPackage({
    Database? sourceDb,
    String? sourceDbPath,
    File? outputFile,
    String? password,
  }) async {
    if (DatabaseEncryptionMigrationService.instance.isMigrationRunning) {
      throw StateError('Cannot create backup while database migration is in progress');
    }
    await DatabaseLifecycleCoordinator.instance.beginBackup();
    try {
      await WriteQueue.instance.quiesce();
      _log('Creating canonical backup package...');
      final Database db = sourceDb ?? await AppDatabase.instance.database;

    // 1. Privacy Scrubbing: Purge expired evidence before snapshot
    await CanonicalBackupValidator.scrubExpiredEvidence(db);

    // 2. Checkpoint WAL
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {}

    // 3. Create point-in-time consistent SQLite snapshot
    final tempDir =
        await Directory.systemTemp.createTemp('spendx_backup_stage_');
    try {
      final snapFile = File(join(tempDir.path, 'spendx_snapshot.db'));
      if (await snapFile.exists()) {
        await snapFile.delete();
      }

      try {
        await db.execute("VACUUM INTO '${snapFile.path}';");
      } catch (e) {
        _log('VACUUM INTO snapshot failed: $e');
        throw BackupValidationException(
          'Failed to create consistent point-in-time database snapshot via VACUUM INTO: $e',
        );
      }

      if (!await snapFile.exists() || await snapFile.length() == 0) {
        throw const BackupValidationException(
          'Failed to produce valid non-zero database snapshot file.',
        );
      }

      // 4. Compute metrics and manifest
      final Database snapDb;
      if (DatabaseEncryptionMigrationService.isPlaintextSqliteFile(snapFile.path)) {
        snapDb = await openDatabase(
          snapFile.path,
          readOnly: true,
        );
      } else {
        final key = await SpendXDatabaseKeyManager.instance.getOrCreateKey();
        final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);
        snapDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
          snapFile.path,
          password: blobKey,
          readOnly: true,
        );
      }
      final metrics =
          await CanonicalBackupValidator.computeDatabaseMetrics(snapDb);
      await snapDb.close();

      final dbBytes = await snapFile.readAsBytes();
      final dbHash = sha256.convert(dbBytes).toString();
      final deviceId = await getDeviceId();
      Map<String, dynamic> syncedSettings = const {};
      try {
        syncedSettings = SettingsService.instance.getSyncedSettings();
      } catch (_) {}

      final manifest = BackupManifest(
        formatVersion: BackupManifest.currentFormatVersion,
        schemaVersion: BackupManifest.currentSchemaVersion,
        appVersion: '2.0.0',
        appName: 'SpendX',
        createdAt: DateTime.now().toUtc(),
        databaseSha256: dbHash,
        databaseSize: dbBytes.length,
        recordCounts: metrics['record_counts'] as Map<String, int>,
        canonicalEventCount: metrics['canonical_event_count'] as int,
        postingCount: metrics['posting_count'] as int,
        evidenceCount: metrics['evidence_count'] as int,
        reviewCandidateCount: metrics['review_candidate_count'] as int,
        debitTotal: metrics['debit_total'] as int,
        creditTotal: metrics['credit_total'] as int,
        deviceId: deviceId,
        settings: syncedSettings,
      );

      // 5. Package into .spendx archive
      File targetOutput;
      if (outputFile != null) {
        targetOutput = outputFile;
      } else {
        Directory defaultDir;
        try {
          defaultDir = await getApplicationDocumentsDirectory();
        } catch (_) {
          defaultDir = Directory.systemTemp;
        }
        targetOutput =
            File(join(defaultDir.path, BackupFileService.backupFileName));
      }

      final (packageFile, finalManifest) =
          await BackupFileService.instance.createPackage(
        dbFile: snapFile,
        manifest: manifest,
        outputFile: targetOutput,
        password: password,
      );

      _log('Canonical backup package created successfully: ${packageFile.path}');
      return (packageFile, finalManifest);
    } finally {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }
    } finally {
      DatabaseLifecycleCoordinator.instance.endBackup();
    }
  }

  // ─── Manual / Scheduled Backup ───────────────────────────────

  /// Creates a canonical backup and uploads it to Google Drive if connected.
  Future<bool> backupNow({String? password}) async {
    if (_busy) {
      _log('backup skipped: already running');
      return false;
    }
    if (!DriveService.instance.isInitialized) {
      _log('backup skipped: Drive not initialized');
      return false;
    }

    _busy = true;
    _log('backup started');
    NotificationServiceV2().showNotification(
      title: 'Backup started',
      body: 'Creating secure double-entry financial backup',
      category: 'backupStatus',
    );

    try {
      // 1. Build canonical .spendx package
      final (packageFile, manifest) = await createBackupPackage();

      // 2. Encrypt package bytes for Drive
      final packageBytes = await packageFile.readAsBytes();
      final deviceId = await _getOrCreateDeviceId();
      final encryptionKey = SettingsService.instance.googleEmail ?? deviceId;
      final encryptedString = BackupEncryption.instance.encrypt(
        base64Encode(packageBytes),
        encryptionKey,
      );
      final encryptedBytes = utf8.encode(encryptedString);

      // 3. Upload to Google Drive
      final count = await DriveService.instance.uploadJson(encryptedBytes);

      // 4. Update local timestamp
      await _saveBackupTimestamp();

      // 5. Update Drive metadata with canonical metrics
      Map<String, dynamic>? existingMeta;
      try {
        existingMeta = await DriveService.instance.downloadMetadata();
      } catch (_) {}

      final devices = <String, dynamic>{};
      if (existingMeta != null && existingMeta['devices'] is Map) {
        devices.addAll(
            Map<String, dynamic>.from(existingMeta['devices'] as Map));
      }
      final deviceName = await _getDeviceName();
      devices[deviceId] = {
        'name': deviceName,
        'lastBackup': _lastBackupAt?.toIso8601String(),
        'lastActive': DateTime.now().toIso8601String(),
      };

      await DriveService.instance.uploadMetadata({
        'latestTimestamp': _lastBackupAt?.toIso8601String(),
        'deviceId': deviceId,
        'checksum': manifest.databaseSha256,
        'backupCount': count,
        'appVersion': 2,
        'canonical_event_count': manifest.canonicalEventCount,
        'posting_count': manifest.postingCount,
        'devices': devices,
      });

      _log('backup complete');
      NotificationServiceV2().showNotification(
        title: 'Backup completed',
        body: 'Your financial ledger is safely backed up',
        category: 'backupStatus',
      );
      return true;
    } catch (e) {
      _log('backup error: $e');
      NotificationServiceV2().showNotification(
        title: 'Backup failed',
        body: 'Could not complete backup: $e',
        category: 'backupStatus',
      );
      return false;
    } finally {
      _busy = false;
    }
  }

  // ─── Canonical Restore ───────────────────────────────────────

  /// Prepares and validates a staged database from a backup package in isolation.
  ///
  /// Guarantees:
  /// - Staging first: Extracts and validates the database in a dedicated staging directory.
  /// - Complete non-interference: Operates under an isolated database connection without touching,
  ///   closing, or locking the primary database.
  /// - Isolated staging ownership: Enforces mutual exclusion on [stagingDir] so concurrent
  ///   operations cannot share, collide, or overwrite staging artifacts.
  /// - Validates SQLite low-level integrity, foreign keys, schema version, canonical tables,
  ///   double-entry balance parity, and evidence retention.
  /// - Leaves the primary database completely untouched and usable.
  Future<StagedBackup> prepareStagedRestore({
    required File packageFile,
    required Directory stagingDir,
    String? password,
  }) async {
    String canonicalPath;
    try {
      canonicalPath = stagingDir.resolveSymbolicLinksSync();
    } catch (_) {
      canonicalPath = canonicalize(stagingDir.absolute.path);
    }
    if (_activeStagingPaths.contains(canonicalPath)) {
      throw BackupValidationException(
        'Staging directory collision: directory "$canonicalPath" is already in use by an active staging operation.',
      );
    }
    _activeStagingPaths.add(canonicalPath);

    try {
      if (await stagingDir.exists() && !await stagingDir.list().isEmpty) {
        throw BackupValidationException(
          'Staging directory collision: directory "$canonicalPath" already exists and is not empty.',
        );
      }

      // 1. Extract package & verify SHA-256
      final staged = await BackupFileService.instance.extractPackage(
        packageFile: packageFile,
        stagingDir: stagingDir,
        password: password,
      );

      // 2. Open staged database in isolation and run complete validation
      final Database stagedDb;
      if (DatabaseEncryptionMigrationService.isPlaintextSqliteFile(
        staged.stagedDbFile.path,
      )) {
        stagedDb = await openDatabase(
          staged.stagedDbFile.path,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON;');
          },
        );
      } else {
        final key = await SpendXDatabaseKeyManager.instance.getOrCreateKey();
        final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);
        stagedDb = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
          staged.stagedDbFile.path,
          password: blobKey,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON;');
          },
        );
      }

      try {
        await CanonicalBackupValidator.validateStagedDatabase(
          stagedDb,
          staged.manifest,
        );
      } finally {
        await stagedDb.close();
      }

      return staged;
    } finally {
      _activeStagingPaths.remove(canonicalPath);
    }
  }

  /// Restores the application state from a local `.spendx` package file.
  ///
  /// Guarantees:
  /// - Staging first: Active DB remains 100% untouched until validation passes completely.
  /// - Full SQLite integrity, foreign keys, double-entry parity, and system account checks.
  /// - Privacy retention scrubbing on restored state.
  /// - Atomic database replacement with rollback on any failure.
  /// - Centralized Riverpod provider invalidation.
  Future<bool> restoreFromFile(
    File packageFile, {
    String? targetDbPath,
    Database? targetDb,
    ProviderContainer? container,
    String? password,
  }) async {
    if (_busy) {
      _log('restore skipped: busy');
      return false;
    }
    _busy = true;
    _log('Starting canonical restore from file: ${packageFile.path}');

    Directory? stagingDir;
    StagedBackup? staged;
    bool gateAdmissionClosed = false;
    String? restoreToken;
    bool restoreBegun = false;
    bool isQuarantined = false;
    bool restoreSucceeded = false;

    try {
      if (enforceDisposableIsolation) {
        final checkPath = targetDbPath ?? await AppDatabase.instance.getDatabasePath();
        final baseName = p.basename(checkPath);
        if (baseName == 'spendx.db' || !baseName.contains('spendx_m45c_qualification.db')) {
          throw StateError('FATAL SAFETY ABORT: Production database access forbidden during 4.5C qualification: $checkPath');
        }
      }

      if (DatabaseEncryptionMigrationService.instance.isMigrationRunning) {
        throw StateError('Cannot restore backup while database migration is in progress');
      }

      final creator = stagingDirectoryCreatorForTesting;
      stagingDir = creator != null
          ? await creator('spendx_restore_stage_')
          : await Directory.systemTemp.createTemp('spendx_restore_stage_');

      // 1 & 2. Extract and validate staged database in isolation
      staged = await prepareStagedRestore(
        packageFile: packageFile,
        stagingDir: stagingDir,
        password: password,
      );

      _log('Staged database passed all validation checks. Establishing exclusive admission...');

      // Phase A — Exclusive admission
      // 1. Quiesce WriteQueue
      await WriteQueue.instance.quiesce();

      // 2, 3, 4. Close DatabaseAccessGate admission, drain active operations and tracked background tasks,
      // and release the native foreground aggregate lease back to the lock lease manager.
      await DatabaseAccessGate.instance.closeAdmissionAndDrain();
      gateAdmissionClosed = true;

      // 5. Acquire native exclusive restore lease
      restoreToken = await PlatformProcessLockService.instance.beginExclusiveRestore();
      if (restoreToken.isEmpty) {
        throw StateError('Acquired empty native exclusive restore token');
      }

      // 6 & 7. Confirm exclusive ownership and notify lifecycle coordinator
      await DatabaseLifecycleCoordinator.instance.beginRestore();
      restoreBegun = true;

      // 3. Atomic Replacement of Target Database
      if (targetDbPath != null) {
        // Test / custom database replacement
        await _atomicReplaceCustomDatabase(
          stagedDbFile: staged.stagedDbFile,
          targetDbPath: targetDbPath,
          targetDb: targetDb,
        );
      } else {
        // Production AppDatabase replacement
        await _atomicReplaceProductionDatabase(
          stagedDbFile: staged.stagedDbFile,
          restoreToken: restoreToken,
        );
      }

      // Phase F — Provider and application invalidation
      if (staged.manifest.settings.isNotEmpty) {
        await SettingsService.instance
            .applySyncedSettings(staged.manifest.settings);
        _log('Synced settings restored from manifest');
      }

      // Update local backup timestamp
      await _saveBackupTimestamp(staged.manifest.createdAt);

      // Centralized Provider and Bus Invalidation
      if (container != null) {
        invalidateAllFinancialProvidersWithContainer(container);
      }
      DataChangeBus.instance.notify();
      DatabaseLifecycleCoordinator.instance.notifyDatabaseReplaced();

      _log('Canonical restore completed successfully');
      restoreSucceeded = true;
      return true;
    } on RestoreQuarantinedException {
      isQuarantined = true;
      rethrow;
    } catch (e) {
      _log('Restore failed: $e');
      rethrow;
    } finally {
      _busy = false;

      // Phase G — Lock and gate recovery
      if (restoreBegun) {
        DatabaseLifecycleCoordinator.instance.endRestore();
      }

      if (restoreToken != null) {
        try {
          if (restoreSucceeded) {
            await PlatformProcessLockService.instance.completeExclusiveRestore(restoreToken);
          } else {
            await PlatformProcessLockService.instance.abortExclusiveRestore(restoreToken);
          }
        } catch (_) {}
      }

      // If admission was closed, reopen it ONLY if NOT quarantined!
      if (gateAdmissionClosed && !isQuarantined) {
        try {
          await DatabaseAccessGate.instance.reopenAdmission();
        } catch (e) {
          _log('Failed to reopen gate admission: $e');
        }
      }

      if (stagingDir != null) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Atomically replaces production `AppDatabase` on disk with rollback protection.
  Future<void> _atomicReplaceProductionDatabase({
    required File stagedDbFile,
    String? restoreToken,
  }) async {
    final activePath = await AppDatabase.instance.getDatabasePath();
    if (enforceDisposableIsolation) {
      final baseName = p.basename(activePath);
      if (baseName == 'spendx.db' || !baseName.contains('spendx_m45c_qualification.db')) {
        throw StateError('FATAL SAFETY ABORT: Production database access forbidden during 4.5C qualification: $activePath');
      }
    }
    CanonicalPathValidator.assertSafeDatabaseMutationPath(
      activePath,
      isDisposableRequired: enforceDisposableIsolation,
    );

    // Live exclusive restore lease validation before beginning mutations
    if (restoreToken != null) {
      final isValid = await PlatformProcessLockService.instance.validateExclusiveRestoreToken(restoreToken);
      if (!isValid) {
        throw StateError('Cannot proceed with database replacement: native exclusive restore lease validation failed');
      }
    }
    final activeFile = File(activePath);
    final rollbackFile = File('$activePath.pre_restore_backup');
    final tempSwapFile = File('$activePath.new_swap');
    final walFile = File('$activePath-wal');
    final shmFile = File('$activePath-shm');
    final journalFile = File(p.join(p.dirname(activePath), RestoreJournal.journalFileName));

    final opId = 'restore_${DateTime.now().millisecondsSinceEpoch}';
    RestoreJournal? journal;
    try {
      final fp = await DatabaseGenerationFingerprint.compute(
        dbPath: stagedDbFile.path,
        restoreOperationId: opId,
        expectedGeneration: 1,
      );
      journal = await RestoreJournal.create(
        journalFile: journalFile,
        restoreOperationId: opId,
        targetDbPath: activePath,
        safetyBackupPath: rollbackFile.path,
        swapCandidatePath: tempSwapFile.path,
        expectedFingerprint: fp.toJson(),
      );
    } catch (_) {}

    // Phase B: Primary database preparation
    // 1. Checkpoint WAL and inspect result
    if (failWalCheckpointForTesting) {
      throw StateError('Injected WAL checkpoint failure for testing');
    }
    final cp = await AppDatabase.instance.checkpointWal();
    if (cp['busy'] != null && cp['busy']! > 0) {
      throw StateError('Cannot proceed with restore: WAL checkpoint busy (${cp['busy']})');
    }

    try {
      await journal?.record(RestoreJournalState.quiesced);
    } catch (_) {}
    if (!_isReleaseBuild && crashBarrierForTesting != null) {
      await crashBarrierForTesting!(RestoreJournalState.quiesced, activeFile.parent, journalFile);
    }

    // 2 & 3. Close primary database connection and confirm closed
    if (failConnectionCloseForTesting) {
      throw StateError('Injected connection close failure for testing');
    }
    await AppDatabase.instance.close();
    if (AppDatabase.instance.isOpen) {
      throw StateError('Primary database failed to close before replacement');
    }

    // Verify staged file is still available
    if (!await stagedDbFile.exists()) {
      throw StateError('Staged database file missing before atomic swap');
    }

    // 4. Preserve current database as rollback file (.pre_restore_backup)
    CanonicalPathValidator.assertSafeSidecarMutation(
      rollbackFile,
      activeDbPath: activePath,
      isDisposableRequired: enforceDisposableIsolation,
    );
    if (restoreToken != null) {
      final isValid = await PlatformProcessLockService.instance.validateExclusiveRestoreToken(restoreToken);
      if (!isValid) {
        throw StateError('Exclusive restore lease validation failed before safety backup creation');
      }
    }
    if (await rollbackFile.exists()) {
      await rollbackFile.delete();
    }
    if (failBackupCreationForTesting) {
      throw StateError('Injected backup creation failure for testing');
    }
    if (await activeFile.exists()) {
      await activeFile.copy(rollbackFile.path);
      DatabaseGenerationFingerprint? backupFp;
      try {
        backupFp = await DatabaseGenerationFingerprint.compute(
          dbPath: rollbackFile.path,
          restoreOperationId: opId,
          expectedGeneration: 0,
        );
      } catch (_) {}
      try {
        await journal?.record(
          RestoreJournalState.backupCreated,
          expectedBackupFingerprint: backupFp?.toJson(),
        );
      } catch (_) {}
      if (!_isReleaseBuild && crashBarrierForTesting != null) {
        await crashBarrierForTesting!(RestoreJournalState.backupCreated, activeFile.parent, journalFile);
      }
    }

    // Phase C: Atomic replacement
    // Prepare same-filesystem temporary swap candidate
    CanonicalPathValidator.assertSafeSidecarMutation(
      tempSwapFile,
      activeDbPath: activePath,
      isDisposableRequired: enforceDisposableIsolation,
    );
    if (restoreToken != null) {
      final isValid = await PlatformProcessLockService.instance.validateExclusiveRestoreToken(restoreToken);
      if (!isValid) {
        throw StateError('Exclusive restore lease validation failed before swap candidate staging');
      }
    }
    if (await tempSwapFile.exists()) {
      await tempSwapFile.delete();
    }
    await stagedDbFile.copy(tempSwapFile.path);

    try {
      // First rename: moving active database to retired location (or testing seam)
      if (failFirstRenameForTesting) {
        if (await tempSwapFile.exists()) await tempSwapFile.delete();
        throw StateError('Injected first rename failure for testing');
      }

      // Re-validate exclusive restore lease before sidecar deletion and replacement rename
      if (restoreToken != null) {
        final isValid = await PlatformProcessLockService.instance.validateExclusiveRestoreToken(restoreToken);
        if (!isValid) {
          throw StateError('Exclusive restore lease validation failed before atomic database swap');
        }
      }

      // Remove active WAL and SHM sidecars to prevent stale association with restored DB
      CanonicalPathValidator.assertSafeSidecarMutation(
        walFile,
        activeDbPath: activePath,
        isDisposableRequired: enforceDisposableIsolation,
      );
      CanonicalPathValidator.assertSafeSidecarMutation(
        shmFile,
        activeDbPath: activePath,
        isDisposableRequired: enforceDisposableIsolation,
      );
      if (await walFile.exists()) await walFile.delete();
      if (await shmFile.exists()) await shmFile.delete();

      try {
        await journal?.record(RestoreJournalState.swapping);
      } catch (_) {}
      if (!_isReleaseBuild && crashBarrierForTesting != null) {
        await crashBarrierForTesting!(RestoreJournalState.swapping, activeFile.parent, journalFile);
      }

      // Replacement rename: atomically rename tempSwapFile to activePath
      if (failReplacementRenameForTesting) {
        if (await activeFile.exists()) await activeFile.delete();
        throw StateError('Injected replacement rename failure for testing');
      }

      try {
        await tempSwapFile.rename(activePath);
      } on FileSystemException {
        // Fallback for filesystems where rename across boundaries fails
        await tempSwapFile.copy(activePath);
        await tempSwapFile.delete();
      }

      try {
        await journal?.record(RestoreJournalState.swapComplete);
      } catch (_) {}
      if (!_isReleaseBuild && crashBarrierForTesting != null) {
        await crashBarrierForTesting!(RestoreJournalState.swapComplete, activeFile.parent, journalFile);
      }

      // Phase D: Reopen and validate restored database.
      // The database is reopened through the normal gated factory so the gate
      // connection is established; post-restore integrity checks are then
      // routed through runPostRestoreIntegrityChecks(), which is a fixed-query
      // interface (not an arbitrary SQL passthrough) gated on the lifecycle
      // coordinator being in the 'restoring' state.
      if (failReopenForTesting) {
        throw StateError('Injected reopen failure for testing');
      }
      await AppDatabase.instance.database; // establishes connection

      if (failIntegrityValidationForTesting) {
        throw StateError('Injected integrity validation failure for testing');
      }

      final validation = await AppDatabase.instance.runPostRestoreIntegrityChecks(
        canonicalTableNames: [
          TablesV24.accounts,
          TablesV24.economicEvents,
          TablesV24.postings,
        ],
      );
      if (!validation.isValid) {
        throw StateError(
          'Post-restore validation failed: ${validation.summary}',
        );
      }

      try {
        await journal?.record(RestoreJournalState.contentVerified);
      } catch (_) {}

      // Validation succeeded: archive rollback backup (zero permanent deletion) and clean temp swap
      if (await rollbackFile.exists()) {
        final archived = File('$activePath.archive_backup_${DateTime.now().millisecondsSinceEpoch}');
        try {
          await rollbackFile.rename(archived.path);
        } catch (_) {
          await rollbackFile.copy(archived.path);
          await rollbackFile.delete();
        }
      }
      if (await tempSwapFile.exists()) await tempSwapFile.delete();
      try {
        await journal?.clear();
      } catch (_) {}
    } catch (e) {
      if (e is RestoreQuarantinedException) rethrow;
      _log('Atomic replacement or validation failed! Initiating rollback: $e');
      await _executeRollback(
        activePath: activePath,
        rollbackFile: rollbackFile,
        cause: e,
        journal: journal,
        restoreToken: restoreToken,
      );
    }
  }

  /// Executes safe rollback using the safety backup file (.pre_restore_backup).
  ///
  /// If rollback succeeds, throws [RestoreException] (gate may be safely reopened).
  /// If rollback fails or is ambiguous, preserves all artifacts and throws [RestoreQuarantinedException]
  /// (gate must remain permanently CLOSED to quarantine corrupted state).
  Future<void> _executeRollback({
    required String activePath,
    required File rollbackFile,
    required Object cause,
    RestoreJournal? journal,
    String? restoreToken,
  }) async {
    final activeFile = File(activePath);
    final walFile = File('$activePath-wal');
    final shmFile = File('$activePath-shm');

    try {
      if (failRollbackForTesting) {
        throw StateError('Injected rollback failure for testing');
      }

      // Live validation of exclusive lease before rollback filesystem mutations
      if (restoreToken != null) {
        final isValid = await PlatformProcessLockService.instance.validateExclusiveRestoreToken(restoreToken);
        if (!isValid) {
          throw RestoreQuarantinedException(
            'Cannot safely execute rollback: native exclusive restore lease validation failed ($cause)',
          );
        }
      }

      CanonicalPathValidator.assertSafeDatabaseMutationPath(
        activePath,
        isDisposableRequired: enforceDisposableIsolation,
      );
      CanonicalPathValidator.assertSafeSidecarMutation(
        rollbackFile,
        activeDbPath: activePath,
        isDisposableRequired: enforceDisposableIsolation,
      );
      CanonicalPathValidator.assertSafeSidecarMutation(
        walFile,
        activeDbPath: activePath,
        isDisposableRequired: enforceDisposableIsolation,
      );
      CanonicalPathValidator.assertSafeSidecarMutation(
        shmFile,
        activeDbPath: activePath,
        isDisposableRequired: enforceDisposableIsolation,
      );

      await AppDatabase.instance.close();

      if (!await rollbackFile.exists()) {
        throw StateError('Rollback file does not exist: ${rollbackFile.path}');
      }

      // Quarantine corrupt active file if it exists
      if (await activeFile.exists()) {
        final corruptFile = File('$activePath.corrupt_${DateTime.now().millisecondsSinceEpoch}');
        try {
          await activeFile.rename(corruptFile.path);
        } catch (_) {
          await activeFile.delete();
        }
      }

      // Clean sidecars
      if (await walFile.exists()) await walFile.delete();
      if (await shmFile.exists()) await shmFile.delete();

      // Restore from rollbackFile
      try {
        await rollbackFile.rename(activePath);
      } on FileSystemException {
        await rollbackFile.copy(activePath);
        await rollbackFile.delete();
      }

      // Reopen and verify rolled back database.
      // The lifecycle coordinator remains in the restoring state during rollback,
      // so runPostRestoreIntegrityChecks() is authorised here.
      await AppDatabase.instance.database; // establishes connection
      final rollbackValidation = await AppDatabase.instance.runPostRestoreIntegrityChecks(
        canonicalTableNames: [
          TablesV24.accounts,
          TablesV24.economicEvents,
          TablesV24.postings,
        ],
      );
      if (rollbackValidation.userVersion != 24) {
        throw StateError(
          'Rolled-back database has invalid user_version: ${rollbackValidation.userVersion}',
        );
      }

      try {
        await journal?.record(RestoreJournalState.rolledBack);
        await journal?.clear();
      } catch (_) {}

      _log('Database rolled back safely to pre-restore state');
      throw RestoreException(
        'Restore failed during atomic swap. Active database rolled back safely: $cause',
      );
    } catch (rollbackError) {
      if (rollbackError is RestoreException) {
        rethrow;
      }
      try {
        await journal?.record(
          RestoreJournalState.quarantined,
          error: rollbackError.toString(),
        );
      } catch (_) {}
      _log('CRITICAL: Rollback failed! Database is in indeterminate/quarantined state: $rollbackError');
      throw RestoreQuarantinedException(
        'Catastrophic failure: restore failed ($cause) and rollback also failed ($rollbackError). '
        'Active database quarantined; gate admission remains closed to protect data integrity.',
      );
    }
  }

  /// Atomically replaces a custom on-disk database with rollback protection.
  Future<void> _atomicReplaceCustomDatabase({
    required File stagedDbFile,
    required String targetDbPath,
    Database? targetDb,
  }) async {
    if (enforceDisposableIsolation) {
      final baseName = p.basename(targetDbPath);
      if (baseName == 'spendx.db' || !baseName.contains('spendx_m45c_qualification.db')) {
        throw StateError('FATAL SAFETY ABORT: Production database access forbidden during 4.5C qualification: $targetDbPath');
      }
    }
    CanonicalPathValidator.assertSafeDatabaseMutationPath(
      targetDbPath,
      isDisposableRequired: enforceDisposableIsolation,
    );
    final activeFile = File(targetDbPath);
    final rollbackFile = File('$targetDbPath.pre_restore_backup');
    final tempSwapFile = File('$targetDbPath.new_swap');
    final walFile = File('$targetDbPath-wal');
    final shmFile = File('$targetDbPath-shm');

    // 1. Checkpoint WAL
    if (failWalCheckpointForTesting) {
      throw StateError('Injected WAL checkpoint failure for testing');
    }
    if (targetDb != null && targetDb.isOpen) {
      try {
        final cp = await targetDb.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
        if (cp.isNotEmpty) {
          final busy = (cp.first['busy'] as num?)?.toInt() ?? 0;
          if (busy > 0) {
            throw StateError('Cannot proceed with restore: WAL checkpoint busy ($busy)');
          }
        }
      } catch (e) {
        if (e is StateError) rethrow;
      }
    }

    // 2. Close connection
    if (failConnectionCloseForTesting) {
      throw StateError('Injected connection close failure for testing');
    }
    if (targetDb != null && targetDb.isOpen) {
      await targetDb.close();
    }

    // 3. Staged file exists check
    if (!await stagedDbFile.exists()) {
      throw StateError('Staged database file missing before atomic swap');
    }

    // 4. Create rollback backup
    if (await rollbackFile.exists()) await rollbackFile.delete();
    if (failBackupCreationForTesting) {
      throw StateError('Injected backup creation failure for testing');
    }
    if (await activeFile.exists()) {
      await activeFile.copy(rollbackFile.path);
    }

    // Prepare temp swap file
    if (await tempSwapFile.exists()) await tempSwapFile.delete();
    await stagedDbFile.copy(tempSwapFile.path);

    try {
      if (failFirstRenameForTesting) {
        if (await tempSwapFile.exists()) await tempSwapFile.delete();
        throw StateError('Injected first rename failure for testing');
      }

      if (await walFile.exists()) await walFile.delete();
      if (await shmFile.exists()) await shmFile.delete();

      if (failReplacementRenameForTesting) {
        if (await activeFile.exists()) await activeFile.delete();
        throw StateError('Injected replacement rename failure for testing');
      }

      try {
        await tempSwapFile.rename(targetDbPath);
      } on FileSystemException {
        await tempSwapFile.copy(targetDbPath);
        await tempSwapFile.delete();
      }

      if (failReopenForTesting) {
        throw StateError('Injected reopen failure for testing');
      }

      final Database testOpen;
      if (DatabaseEncryptionMigrationService.isPlaintextSqliteFile(targetDbPath)) {
        testOpen = await openDatabase(
          targetDbPath,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON;'),
        );
      } else {
        final key = await SpendXDatabaseKeyManager.instance.getOrCreateKey();
        final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);
        testOpen = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
          targetDbPath,
          password: blobKey,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON;'),
        );
      }

      if (failIntegrityValidationForTesting) {
        await testOpen.close();
        throw StateError('Injected integrity validation failure for testing');
      }

      final integrityRows = await testOpen.rawQuery('PRAGMA integrity_check;');
      final integrity = integrityRows.first.values.first as String? ?? '';
      if (integrity.toLowerCase() != 'ok') {
        await testOpen.close();
        throw StateError('Integrity check failed: $integrity');
      }

      final fkRows = await testOpen.rawQuery('PRAGMA foreign_key_check;');
      if (fkRows.isNotEmpty) {
        await testOpen.close();
        throw StateError('Foreign key check failed: ${fkRows.length} violations found');
      }

      final verRows = await testOpen.rawQuery('PRAGMA user_version;');
      final ver = verRows.first.values.first as int? ?? 0;
      await testOpen.close();
      if (ver != 24) {
        throw StateError('Restored target database has invalid version: $ver');
      }

      if (await rollbackFile.exists()) await rollbackFile.delete();
      if (await tempSwapFile.exists()) await tempSwapFile.delete();
    } catch (e) {
      if (e is RestoreQuarantinedException) rethrow;
      _log('Restored custom target validation failed! Initiating rollback: $e');
      try {
        if (failRollbackForTesting) {
          throw StateError('Injected rollback failure for testing');
        }
        if (!await rollbackFile.exists()) {
          throw StateError('Rollback file does not exist: ${rollbackFile.path}');
        }
        if (await activeFile.exists()) {
          final corruptFile = File('$targetDbPath.corrupt_${DateTime.now().millisecondsSinceEpoch}');
          try {
            await activeFile.rename(corruptFile.path);
          } catch (_) {
            await activeFile.delete();
          }
        }
        if (await walFile.exists()) await walFile.delete();
        if (await shmFile.exists()) await shmFile.delete();
        if (await tempSwapFile.exists()) await tempSwapFile.delete();

        try {
          await rollbackFile.rename(targetDbPath);
        } on FileSystemException {
          await rollbackFile.copy(targetDbPath);
          await rollbackFile.delete();
        }

        // Verify reopened rollback custom DB
        final Database rollbackOpen;
        if (DatabaseEncryptionMigrationService.isPlaintextSqliteFile(targetDbPath)) {
          rollbackOpen = await openDatabase(targetDbPath);
        } else {
          final key = await SpendXDatabaseKeyManager.instance.getOrCreateKey();
          final blobKey = SpendXDatabaseKeyManager.keyToSqlCipherBlob(key);
          rollbackOpen = await SpendXDatabaseFactory.instance.openEncryptedDatabase(
            targetDbPath,
            password: blobKey,
          );
        }
        final verRows = await rollbackOpen.rawQuery('PRAGMA user_version;');
        final ver = verRows.first.values.first as int? ?? 0;
        await rollbackOpen.close();
        if (ver != 24) {
          throw StateError('Rolled-back custom database has invalid user_version: $ver');
        }

        throw RestoreException(
          'Restore failed during atomic swap. Custom database rolled back: $e',
        );
      } catch (rollbackError) {
        if (rollbackError is RestoreException) rethrow;
        throw RestoreQuarantinedException(
          'Catastrophic failure: custom target restore failed ($e) and rollback also failed ($rollbackError).',
        );
      }
    }
  }

  // ─── Drive Restore ───────────────────────────────────────────

  /// Downloads the backup package from Drive, decrypts it, and restores it.
  Future<bool> restoreFromDrive({
    bool forceRestore = false,
    String? password,
  }) async {
    if (_busy) {
      _log('restore skipped: busy');
      return false;
    }
    if (!DriveService.instance.isInitialized) {
      _log('restore skipped: Drive not initialized');
      return false;
    }

    _log('Starting canonical restore from Drive...');
    final tempDir =
        await Directory.systemTemp.createTemp('spendx_drive_restore_');
    final tempPackage = File(join(tempDir.path, 'downloaded.spendx'));

    try {
      // 1. Download data from Drive
      var payloadString = await DriveService.instance.downloadJson();
      if (payloadString == null || payloadString.isEmpty) {
        _log('restore skipped: no backup found on Drive');
        return false;
      }

      // 2. Decrypt if encrypted wrapper present
      List<int> packageBytes;
      if (BackupEncryption.instance.isEncrypted(payloadString)) {
        final deviceId = await _getOrCreateDeviceId();
        final sharedKey = SettingsService.instance.googleEmail ?? deviceId;
        bool decrypted = false;
        String decryptedBase64 = '';

        try {
          decryptedBase64 =
              BackupEncryption.instance.decrypt(payloadString, sharedKey);
          decrypted = true;
        } catch (_) {}

        if (!decrypted && sharedKey != deviceId) {
          try {
            decryptedBase64 =
                BackupEncryption.instance.decrypt(payloadString, deviceId);
            decrypted = true;
          } catch (_) {}
        }

        if (decrypted) {
          packageBytes = base64Decode(decryptedBase64);
        } else {
          throw const BackupValidationException(
            'Failed to decrypt backup downloaded from Google Drive.',
          );
        }
      } else {
        // Plain bytes (or legacy json)
        try {
          packageBytes = base64Decode(payloadString);
        } catch (_) {
          packageBytes = utf8.encode(payloadString);
        }
      }

      // 3. Write package to temporary file and execute canonical restore
      await tempPackage.writeAsBytes(packageBytes, flush: true);
      final success = await restoreFromFile(tempPackage, password: password);

      if (success) {
        NotificationServiceV2().showNotification(
          title: 'Restore complete',
          body: 'Your financial ledger has been safely restored',
          category: 'backupStatus',
        );
      }
      return success;
    } catch (e) {
      _log('Drive restore failed: $e');
      NotificationServiceV2().showNotification(
        title: 'Restore failed',
        body: 'Could not restore backup from Google Drive: $e',
        category: 'backupStatus',
      );
      return false;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────

  Future<void> _saveBackupTimestamp([DateTime? time]) async {
    _lastBackupAt = time ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastBackupAtKey, _lastBackupAt!.toIso8601String());
    _log('timestamp saved: $_lastBackupAt');
  }

  void _log(String msg) => AppLogger.d('[BACKUP] $msg');
}
