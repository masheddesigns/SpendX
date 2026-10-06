import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../data/core/spendx_database_factory.dart' hide InvalidDatabaseKeyException;
import '../data/core/database_lifecycle_coordinator.dart';
import '../data/core/write_queue.dart';
import '../data/security/database_key_manager.dart';
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
  DateTime? get lastBackupAt => _lastBackupAt;

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
    final snapFile = File(join(tempDir.path, 'spendx_snapshot.db'));
    if (await snapFile.exists()) {
      await snapFile.delete();
    }

    try {
      await db.execute("VACUUM INTO '${snapFile.path}';");
    } catch (e) {
      _log('VACUUM INTO failed ($e); falling back to file copy if on-disk');
      final path = sourceDbPath ?? (await AppDatabase.instance.getDatabasePath());
      final srcFile = File(path);
      if (await srcFile.exists()) {
        await srcFile.copy(snapFile.path);
      } else {
        rethrow;
      }
    }

    if (!await snapFile.exists() || await snapFile.length() == 0) {
      await tempDir.delete(recursive: true);
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

    // Clean up temporary snapshot directory
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}

    _log('Canonical backup package created successfully: ${packageFile.path}');
    return (packageFile, finalManifest);
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
    await DatabaseLifecycleCoordinator.instance.beginRestore();
    _busy = true;
    _log('Starting canonical restore from file: ${packageFile.path}');

    if (DatabaseEncryptionMigrationService.instance.isMigrationRunning) {
      throw StateError('Cannot restore backup while database migration is in progress');
    }
    final stagingDir =
        await Directory.systemTemp.createTemp('spendx_restore_stage_');
    StagedBackup? staged;

    try {
      await WriteQueue.instance.quiesce();
      // 1. Extract package & verify SHA-256
      staged = await BackupFileService.instance.extractPackage(
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

      _log('Staged database passed all validation checks. Performing atomic replacement...');

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
        );
      }

      // 4. Restore synced settings
      if (staged.manifest.settings.isNotEmpty) {
        await SettingsService.instance
            .applySyncedSettings(staged.manifest.settings);
        _log('Synced settings restored from manifest');
      }

      // 5. Update local backup timestamp
      await _saveBackupTimestamp(staged.manifest.createdAt);

      // 6. Centralized Provider and Bus Invalidation
      if (container != null) {
        invalidateAllFinancialProvidersWithContainer(container);
      }
      DataChangeBus.instance.notify();
      DatabaseLifecycleCoordinator.instance.notifyDatabaseReplaced();

      _log('Canonical restore completed successfully');
      return true;
    } catch (e) {
      _log('Restore failed: $e');
      rethrow;
    } finally {
      _busy = false;
      DatabaseLifecycleCoordinator.instance.endRestore();
      try {
        await stagingDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Atomically replaces production `AppDatabase` on disk with rollback protection.
  Future<void> _atomicReplaceProductionDatabase({
    required File stagedDbFile,
  }) async {
    final activePath = await AppDatabase.instance.getDatabasePath();
    final activeFile = File(activePath);
    final rollbackFile = File('$activePath.pre_restore_backup');

    // 1. Checkpoint and close active database connection
    await AppDatabase.instance.checkpointWal();
    await AppDatabase.instance.close();

    // 2. Prepare rollback backup of active database
    if (await rollbackFile.exists()) await rollbackFile.delete();
    if (await activeFile.exists()) {
      await activeFile.copy(rollbackFile.path);
    }

    // 3. Remove active WAL and SHM files
    final walFile = File('$activePath-wal');
    final shmFile = File('$activePath-shm');
    if (await walFile.exists()) await walFile.delete();
    if (await shmFile.exists()) await shmFile.delete();

    // 4. Move staged database into place
    await stagedDbFile.copy(activePath);

    // 5. Re-open and verify production database
    try {
      final reopenedDb = await AppDatabase.instance.database;
      final verRows = await reopenedDb.rawQuery('PRAGMA user_version;');
      final ver = verRows.first.values.first as int? ?? 0;
      if (ver != 24) {
        throw StateError('Reopened restored database has invalid version: $ver');
      }
      // Success: delete rollback file
      if (await rollbackFile.exists()) await rollbackFile.delete();
    } catch (e) {
      _log('Reopening restored database failed! Initiating automatic rollback: $e');
      await AppDatabase.instance.close();
      if (await rollbackFile.exists()) {
        await rollbackFile.copy(activePath);
        await rollbackFile.delete();
      }
      await AppDatabase.instance.database; // Reopen previous database
      throw RestoreException(
        'Restore failed during atomic swap. Active database rolled back safely: $e',
      );
    }
  }

  /// Atomically replaces a custom on-disk database with rollback protection.
  Future<void> _atomicReplaceCustomDatabase({
    required File stagedDbFile,
    required String targetDbPath,
    Database? targetDb,
  }) async {
    final activeFile = File(targetDbPath);
    final rollbackFile = File('$targetDbPath.pre_restore_backup');

    if (targetDb != null && targetDb.isOpen) {
      try {
        await targetDb.rawQuery('PRAGMA wal_checkpoint(TRUNCATE);');
      } catch (_) {}
      await targetDb.close();
    }

    if (await rollbackFile.exists()) await rollbackFile.delete();
    if (await activeFile.exists()) {
      await activeFile.copy(rollbackFile.path);
    }

    final walFile = File('$targetDbPath-wal');
    final shmFile = File('$targetDbPath-shm');
    if (await walFile.exists()) await walFile.delete();
    if (await shmFile.exists()) await shmFile.delete();

    await stagedDbFile.copy(targetDbPath);

    try {
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
      final verRows = await testOpen.rawQuery('PRAGMA user_version;');
      final ver = verRows.first.values.first as int? ?? 0;
      await testOpen.close();
      if (ver != 24) {
        throw StateError('Restored target database has invalid version: $ver');
      }
      if (await rollbackFile.exists()) await rollbackFile.delete();
    } catch (e) {
      _log('Restored custom target validation failed! Rolling back: $e');
      if (await rollbackFile.exists()) {
        await rollbackFile.copy(targetDbPath);
        await rollbackFile.delete();
      }
      throw RestoreException(
        'Restore failed during atomic swap. Custom database rolled back: $e',
      );
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
