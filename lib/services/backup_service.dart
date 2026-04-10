import '../core/logging/app_logger.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'notification_service_v2.dart';

import 'backup_encryption.dart';
import 'backup_file_service.dart';
import 'data_change_bus.dart';
import 'database_helper.dart';
import 'drive_service.dart';
import 'settings_service.dart';
import 'auth_service.dart';

/// BackupService — simple Fuelio-style manual backup and restore.
///
/// No compression. No hashing. No mutation detection.
/// Backup only runs when the user presses "Backup Now".
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const String _deviceIdKey      = 'spendx_device_id';
  static const String _lastBackupAtKey  = 'spendx_last_backup_at';

  bool _busy = false;
  DateTime? _lastBackupAt;
  Timer? _autoBackupTimer;
  Timer? _debounceTimer;

  bool get isBackupRunning => _busy;
  DateTime? get lastBackupAt => _lastBackupAt;

  // ─── Init ────────────────────────────────────────────

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

  /// Called when any data changes. Debounces to avoid rapid-fire backups.
  void _onDataChanged() {
    if (!SettingsService.instance.autoBackupEnabled) return;
    if (!DriveService.instance.isInitialized) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 30), () {
      _log('auto-backup: triggered by data change');
      backupNow();
    });
  }

  /// Starts the periodic auto-backup timer if Drive is connected and
  /// the user has configured an interval. Safe to call multiple times.
  void startAutoBackupTimer() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;

    final settings = SettingsService.instance;
    if (!settings.autoBackupEnabled) {
      _log('auto-backup: disabled');
      return;
    }
    final intervalHours = settings.backupIntervalHours;
    if (intervalHours <= 0) {
      _log('auto-backup: interval not set');
      return;
    }
    if (!AuthService.instance.isSignedIn) {
      _log('auto-backup: no Google account — timer not started');
      return;
    }

    final duration = Duration(hours: intervalHours);
    _log('auto-backup: timer started (every ${intervalHours}h)');
    _autoBackupTimer = Timer.periodic(duration, (_) async {
      _log('auto-backup: timer fired');
      await backupNow();
    });
  }

  /// Cancels the auto-backup timer.
  void stopAutoBackupTimer() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;
    _log('auto-backup: timer stopped');
  }

  Future<String> _getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  Future<String> _getDeviceName() async {
    try {
      if (Platform.isAndroid) {
        // Use model name from system
        final result = await Process.run('getprop', ['ro.product.model']);
        final model = result.stdout.toString().trim();
        if (model.isNotEmpty) return model;
      }
    } catch (_) {}
    return Platform.operatingSystem;
  }

  /// Get the current device ID.
  Future<String> getDeviceId() => _getOrCreateDeviceId();

  /// Fetch connected devices from Drive metadata.
  Future<List<Map<String, dynamic>>> getConnectedDevices() async {
    if (!DriveService.instance.isInitialized) return [];
    try {
      final meta = await DriveService.instance.downloadMetadata();
      if (meta == null || meta['devices'] is! Map) return [];

      final currentId = await _getOrCreateDeviceId();
      final devices = Map<String, dynamic>.from(meta['devices'] as Map);

      return devices.entries.map((e) {
        final info = e.value is Map ? Map<String, dynamic>.from(e.value as Map) : <String, dynamic>{};
        return {
          'id': e.key,
          'name': info['name'] ?? 'Unknown',
          'lastBackup': info['lastBackup'],
          'lastActive': info['lastActive'],
          'isCurrent': e.key == currentId,
        };
      }).toList()
        ..sort((a, b) {
          // Current device first, then by lastActive desc
          if (a['isCurrent'] == true) return -1;
          if (b['isCurrent'] == true) return 1;
          final aTime = a['lastActive'] as String? ?? '';
          final bTime = b['lastActive'] as String? ?? '';
          return bTime.compareTo(aTime);
        });
    } catch (e) {
      _log("getConnectedDevices error: $e");
      return [];
    }
  }

  // ─── Backup Now ──────────────────────────────────────

  /// Create a clean JSON backup and upload it to Google Drive.
  Future<bool> backupNow() async {
    if (_busy) {
      _log("backup skipped: already running");
      return false;
    }
    if (!DriveService.instance.isInitialized) {
      _log("backup skipped: Drive not initialized");
      return false;
    }

    _busy = true;
    _log("backup started");
    NotificationServiceV2().showNotification(
      title: "Backup started",
      body: "Uploading your data securely",
      category: 'backupStatus',
    );

    try {
      // 1. Build JSON
      final (jsonString, checksum) = await BackupFileService.instance.createBackupJson();

      // 2. Encrypt before upload (use Google email as shared key for multi-device)
      final deviceId = await _getOrCreateDeviceId();
      final encryptionKey = SettingsService.instance.googleEmail ?? deviceId;
      final encrypted = BackupEncryption.instance.encrypt(jsonString, encryptionKey);
      final jsonBytes = utf8.encode(encrypted);
      _log("backup encrypted (${jsonBytes.length} bytes)");

      // 3. Upload encrypted data
      final count = await DriveService.instance.uploadJson(jsonBytes);

      // 3. Persist timestamp locally
      await _saveBackupTimestamp();

      // 4. Update remote metadata with device tracking
      Map<String, dynamic>? existingMeta;
      try {
        existingMeta = await DriveService.instance.downloadMetadata();
      } catch (_) {}

      // Build devices list — update this device, keep others
      final devices = <String, dynamic>{};
      if (existingMeta != null && existingMeta['devices'] is Map) {
        devices.addAll(Map<String, dynamic>.from(existingMeta['devices'] as Map));
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
        'checksum': checksum,
        'backupCount': count,
        'appVersion': 1,
        'devices': devices,
      });

      _log("backup complete");
      NotificationServiceV2().showNotification(
        title: "Backup completed",
        body: "Your data is safely backed up",
        category: 'backupStatus',
      );
      return true;
    } catch (e) {
      _log("backup error: $e");
      NotificationServiceV2().showNotification(
        title: "Backup failed",
        body: "Check your connection and try again",
        category: 'backupStatus',
      );
      return false;
    } finally {
      _busy = false;
    }
  }

  // ─── Restore ─────────────────────────────────────────

  /// Download the backup from Drive and restore the database.
  Future<bool> restoreFromDrive({bool forceRestore = false}) async {
    if (_busy) {
      _log("restore skipped: busy");
      return false;
    }
    if (!DriveService.instance.isInitialized) {
      _log("restore skipped: Drive not initialized");
      return false;
    }

    _busy = true;
    _log("restore started");

    try {
      // 1. Download
      var jsonString = await DriveService.instance.downloadJson();
      if (jsonString == null) {
        _log("restore skipped: no backup found on Drive");
        return false;
      }

      // 2. Decrypt if encrypted (try shared key first, then device key, then plain)
      if (BackupEncryption.instance.isEncrypted(jsonString)) {
        final deviceId = await _getOrCreateDeviceId();
        final sharedKey = SettingsService.instance.googleEmail ?? deviceId;
        bool decrypted = false;

        // Try shared key (Google email — works across devices)
        try {
          jsonString = BackupEncryption.instance.decrypt(jsonString, sharedKey);
          _log("restore: decrypted with shared key");
          decrypted = true;
        } catch (_) {}

        // Fallback: try device-specific key (old backups)
        if (!decrypted && sharedKey != deviceId) {
          try {
            // Re-download since jsonString may be corrupted from failed decrypt
            jsonString = await DriveService.instance.downloadJson();
            if (jsonString != null && BackupEncryption.instance.isEncrypted(jsonString)) {
              jsonString = BackupEncryption.instance.decrypt(jsonString, deviceId);
              _log("restore: decrypted with device key (legacy)");
              decrypted = true;
            }
          } catch (_) {}
        }

        if (!decrypted) {
          _log("restore: decryption failed — trying as plain JSON");
        }
      }

      // 3. Parse
      final backup = await BackupFileService.instance.parseBackupJson(jsonString!);
      if (backup == null) {
        _log("restore failed: invalid backup file");
        return false;
      }

      // 3. Rollback Protection: Don't restore if local data is already newer
      if (!forceRestore) {
        final createdAtStr = backup['createdAt'] as String?;
        if (createdAtStr != null) {
          final createdAt = DateTime.tryParse(createdAtStr);
          if (createdAt != null && _lastBackupAt != null) {
            if (createdAt.isBefore(_lastBackupAt!) || createdAt.isAtSameMomentAs(_lastBackupAt!)) {
              _log("restore skipped: local data is already up to date or newer ($createdAt <= $_lastBackupAt)");
              return false;
            }
          }
        }
      }

      // 4. Restore database tables
      _log("restoring database...");
      await _restoreTables(backup);

      // 5. Restore settings
      if (backup.containsKey('settings') && backup['settings'] is Map) {
        await SettingsService.instance.applySyncedSettings(
          Map<String, dynamic>.from(backup['settings'] as Map),
        );
        _log("settings restored");
      }

      // 6. Loop Prevention: Update local timestamp to exactly match the remote one
      final restoreTimestamp = backup['createdAt'] as String?;
      if (restoreTimestamp != null) {
        final createdAt = DateTime.tryParse(restoreTimestamp);
        if (createdAt != null) {
          await _saveBackupTimestamp(createdAt);
        }
      } else {
        await _saveBackupTimestamp();
      }

      _log("restore complete");

      // Notify all listeners that data changed — providers will refresh
      DataChangeBus.instance.notify();

      NotificationServiceV2().showNotification(
        title: "Restore complete",
        body: "Your data has been successfully restored",
        category: 'backupStatus',
      );
      return true;
    } catch (e) {
      _log("restore error: $e");
      NotificationServiceV2().showNotification(
        title: "Restore failed",
        body: "Could not restore backup. Check integrity.",
        category: 'backupStatus',
      );
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Restore from a local backup [File] (imported by user).
  Future<bool> restoreFromFile(File file) async {
    if (_busy) {
      _log("restore skipped: busy");
      return false;
    }

    _busy = true;
    _log("restoring from file: ${file.path}");

    try {
      final jsonString = await file.readAsString();
      final backup = await BackupFileService.instance.parseBackupJson(jsonString);
      if (backup == null) {
        _log("restore failed: invalid file");
        return false;
      }

      await _restoreTables(backup);

      if (backup.containsKey('settings') && backup['settings'] is Map) {
        await SettingsService.instance.applySyncedSettings(
          Map<String, dynamic>.from(backup['settings'] as Map),
        );
      }

      await _saveBackupTimestamp();
      _log("file restore complete");
      return true;
    } catch (e) {
      _log("file restore error: $e");
      return false;
    } finally {
      _busy = false;
    }
  }

  // Auto Backup — timer-based periodic backup when Drive is connected.
  // Complements the Fuelio-style event-driven sync in SyncEngine.

  // ─── Helpers ─────────────────────────────────────────

  Future<void> _restoreTables(Map<String, dynamic> backup) async {
    // Build a tables map compatible with DatabaseHelper.restoreFromSnapshot
    final tables = <String, dynamic>{};

    // Accept both flat keys (new format) and nested 'tables' key (old format)
    if (backup.containsKey('tables') && backup['tables'] is Map) {
      tables.addAll(Map<String, dynamic>.from(backup['tables'] as Map));
    }

    // All known table keys — flat keys take precedence / supplement
    const allTableKeys = [
      'transactions', 'categories', 'bank_accounts', 'budgets', 'tags',
      'credit_cards', 'credit_transactions', 'credit_emis',
      'emi_installments', 'emi_plans', 'card_statements',
      'loans', 'loan_installments', 'lendings',
      'vehicles', 'fuel_logs', 'vehicle_reminders',
      'recurring_templates', 'reminders', 'ledger_transactions',
      'companies', 'salary_contracts', 'salary_payments',
      'salary_increments', 'salary', 'salary_months', 'salary_ledger',
      'goals', 'goal_logs', 'streaks',
      'merchant_rules', 'review_queue',
      'net_worth_history', 'bank_balance_snapshots', 'health_score_history',
      'challenges', 'achievements', 'insight_compliance',
    ];

    for (final key in allTableKeys) {
      if (backup.containsKey(key)) {
        tables[key] = backup[key];
      }
    }

    await DatabaseHelper.instance.restoreFromSnapshot(tables);
  }


  Future<void> _saveBackupTimestamp([DateTime? time]) async {
    _lastBackupAt = time ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastBackupAtKey, _lastBackupAt!.toIso8601String());
    _log("timestamp saved: $_lastBackupAt");
  }

  void _log(String msg) => AppLogger.d("[BACKUP] $msg");
}
