import '../core/logging/app_logger.dart';
import 'dart:async';
import 'package:flutter/widgets.dart';

import 'auth_service.dart';
import 'backup_service.dart';
import 'drive_service.dart';
import 'notification_service.dart';
import 'settings_service.dart';

enum SyncStatus {
  connected,
  syncing,
  newBackupAvailable,
  offline,
}

/// SyncEngine — orchestration layer over BackupService and DriveService.
///
/// Implements Fuelio-style event-driven sync.
/// Triggers on:
/// - App Launch
/// - App Resume
/// - Manual action
class SyncEngine extends ChangeNotifier with WidgetsBindingObserver {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  SyncStatus _status = SyncStatus.offline;
  SyncStatus get status => _status;

  DateTime? _lastSyncCheckTime;
  bool _isChecking = false;
  bool _isInitialized = false;

  bool _remoteBackupAvailable = false;
  int _remoteBackupCount = 0;

  bool get remoteBackupAvailable => _remoteBackupAvailable;
  int get remoteBackupCount => _remoteBackupCount;

  void init() {
    if (_isInitialized) return;
    _isInitialized = true;
    WidgetsBinding.instance.addObserver(this);
    
    // Initial sync check on launch
    _log("initializing SyncEngine - running launch sync check");
    WidgetsBinding.instance.addPostFrameCallback((_) {
      checkRemoteBackup(isLaunch: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _log("app resumed — refreshing token then sync check");
      // Refresh the Google access token first, THEN do sync check.
      // This prevents the 'invalid_token' error showing Drive as Disconnected.
      AuthService.instance.ensureValidToken().then((_) {
        checkRemoteBackup();
      });
    }
  }

  // ─── Remote Detection ────────────────────────────────

  Future<bool> manualBackup() async {
    _log("manual backup started");
    await NotificationService.instance.showBackupStarted();

    final success = await BackupService.instance.backupNow();

    await NotificationService.instance.showBackupComplete(success);
    if (success) {
      _log("upload finished");
    } else {
      _log("backup failed");
    }
    return success;
  }

  Future<bool> manualRestore({bool force = false}) async {
    _log("manual restore started (force: $force)");
    await NotificationService.instance.showRestoreStarted();

    final success = await BackupService.instance.restoreFromDrive(forceRestore: force);

    await NotificationService.instance.showRestoreComplete(success);
    if (success) {
      _log("restore finished");
    } else {
      _log("restore failed");
    }
    return success;
  }

  // ─── Sync Detection ──────────────────────────────────

  /// Silently checks if Drive has a newer backup than the local device.
  /// Implement Fuelio-style sync logic:
  /// 1. Remote > Local -> Show banner/Update status.
  /// 2. Local > Remote -> Auto upload new backup.
  Future<void> checkRemoteBackup({bool isLaunch = false}) async {
    if (!DriveService.instance.isInitialized) {
      _updateStatus(SyncStatus.offline);
      return;
    }

    // --- Throttling: Max 1 check every 2 minutes for resume, allow launch always ---
    if (!isLaunch && _lastSyncCheckTime != null) {
      final diff = DateTime.now().difference(_lastSyncCheckTime!);
      if (diff < const Duration(minutes: 2)) {
        _log("sync check throttled (last check ${diff.inMinutes}m ago)");
        return;
      }
    }
    
    if (_isChecking) {
      _log("sync check already in progress — skipping");
      return;
    }

    _isChecking = true;
    _lastSyncCheckTime = DateTime.now();
    _updateStatus(SyncStatus.syncing);

    try {
      // 1. Fetch metadata (lightweight)
      Map<String, dynamic>? meta;
      try {
        meta = await DriveService.instance.downloadMetadata();
      } catch (e) {
        _log("metadata download failed: $e - attempting rebuild");
      }
      
      if (meta == null) {
        _log("metadata missing or failed — falling back to rebuild from file listing...");
        final files = await DriveService.instance.listBackups();
        
        if (files.isEmpty) {
          _log("no backups found on Drive - status connected");
          _remoteBackupCount = 0;
          _setRemoteAvailable(false);
          _updateStatus(SyncStatus.connected);
          return;
        }
        
        final latestRemote = files.first;
        if (latestRemote.modifiedTime == null) {
          _updateStatus(SyncStatus.connected);
          return;
        }

        // Rebuild basic metadata for comparison
        meta = {
          'latestTimestamp': latestRemote.modifiedTime!.toIso8601String(),
          'backupCount': files.length,
        };
        _log("metadata rebuilt from file listing: $meta");
      }

      final remoteStr = meta['latestTimestamp'] as String?;
      if (remoteStr == null) {
        _updateStatus(SyncStatus.connected);
        return;
      }
      final remoteTime = DateTime.tryParse(remoteStr);
      if (remoteTime == null) {
        _updateStatus(SyncStatus.connected);
        return;
      }

      _remoteBackupCount = (meta['backupCount'] as int?) ?? 0;
      notifyListeners();

      await _evaluateSyncState(remoteTime);
    } catch (e) {
      _log("sync check error: $e");
      _updateStatus(SyncStatus.connected);
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _evaluateSyncState(DateTime remoteTime) async {
    final localTime = BackupService.instance.lastBackupAt;

    if (localTime == null) {
      // If we have never backed up but remote exists, show new backup available
      _log("local backup missing, remote exists: $remoteTime");
      _setRemoteAvailable(true);
      _updateStatus(SyncStatus.newBackupAvailable);
      return;
    }

    // Precise comparison (ignoring millisecond differences often caused by ISO parsing)
    final diff = remoteTime.difference(localTime).inSeconds;

    if (diff > 5) {
      _log("newer remote backup detected: $remoteTime (local: $localTime)");

      // Auto-restore if enabled
      if (SettingsService.instance.autoRestoreEnabled) {
        _log("auto-restore enabled — restoring from Drive...");
        _updateStatus(SyncStatus.syncing);
        final success = await BackupService.instance.restoreFromDrive();
        if (success) {
          _log("auto-restore completed successfully");
          _setRemoteAvailable(false);
          _updateStatus(SyncStatus.connected);
          return;
        }
        _log("auto-restore failed — showing banner instead");
      }

      _setRemoteAvailable(true);
      _updateStatus(SyncStatus.newBackupAvailable);
    } else if (diff < -5) {
      _log("local data is newer: $localTime (remote: $remoteTime) - triggering auto-upload");
      _setRemoteAvailable(false);
      _updateStatus(SyncStatus.syncing);
      final success = await manualBackup();
      if (success) {
        _updateStatus(SyncStatus.connected);
      } else {
        _updateStatus(SyncStatus.connected); // Fallback to connected if upload fails
      }
    } else {
      _log("backups are synchronized");
      _setRemoteAvailable(false);
      _updateStatus(SyncStatus.connected);
    }
  }

  void _updateStatus(SyncStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      notifyListeners();
    }
  }

  void _setRemoteAvailable(bool available) async {
    if (_remoteBackupAvailable != available) {
      _remoteBackupAvailable = available;
      notifyListeners();

      if (available) {
        await NotificationService.instance.showSyncReminder(
          body: "New data available from another device.",
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _log(String msg) => AppLogger.d("[SYNC] $msg");
}
