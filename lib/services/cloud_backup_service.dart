import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'backup_service.dart';
import 'settings_service.dart';
import 'google_drive_provider.dart';
import 'dropbox_provider.dart';
import 'database_helper.dart';
import 'notification_service.dart';

abstract class CloudProvider {
  String get name;
  Future<bool> signIn();
  Future<void> signOut();
  Future<bool> isSignedIn();
  
  Future<String?> uploadFile({
    required File file,
    required String remoteName,
    String? folderId,
  });

  Future<File?> downloadFile({
    required String fileId,
    required String localPath,
  });
  
  Future<bool> deleteFile(String fileId);
  
  Future<bool> wipeAllData();
  
  Future<List<CloudFile>> listFiles();
}

class CloudFile {
  final String id;
  final String name;
  final DateTime modifiedAt;
  final int size;

  CloudFile({
    required this.id,
    required this.name,
    required this.modifiedAt,
    required this.size,
  });
}

class CloudBackupService {
  CloudBackupService._();
  static final instance = CloudBackupService._();

  CloudProvider? _currentProvider;
  Timer? _debounceTimer;
  bool _isExporting = false;

  /// Initialize the service and subscribe to database changes
  Future<void> init() async {
    if (SettingsService.instance.lastCloudProvider != null) {
      debugPrint('CloudBackupService: Previously connected to ${SettingsService.instance.lastCloudProvider}. Recovery will happen on-demand.');
    }

    // 2. Subscribe to DB changes for debounced auto-backup
    DatabaseHelper.instance.setOnDataChange(() {
      scheduleAutoBackup();
    });
  }

  void setProvider(CloudProvider provider) {
    _currentProvider = provider;
  }

  CloudProvider? get currentProvider => _currentProvider;

  Future<bool> backupToCloud(File localFile) async {
    if (_currentProvider == null) {
      // Try to auto-resolve provider if not set
      await _resolveProvider();
    }
    if (_currentProvider == null) return false;
    
    final remoteName = localFile.path.split('/').last;
    final fileId = await _currentProvider!.uploadFile(
      file: localFile,
      remoteName: remoteName,
    );
    
    // Update last sync time on success
    if (fileId != null) {
      await SettingsService.instance.setLastSyncTime(DateTime.now());
    }
    
    return fileId != null;
  }

  /// Checks cloud for newer backups and returns the newest file if it's newer than current data
  Future<CloudFile?> checkForUpdates() async {
    if (_currentProvider == null) await _resolveProvider();
    if (_currentProvider == null) return null;

    final cloudFiles = await _currentProvider!.listFiles();
    if (cloudFiles.isEmpty) return null;

    // Sort by date newest first
    cloudFiles.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final newestCloud = cloudFiles.first;

    final lastSync = SettingsService.instance.lastSyncTime;
    if (lastSync == null || newestCloud.modifiedAt.isAfter(lastSync.add(const Duration(seconds: 1)))) {
      return newestCloud;
    }

    return null;
  }

  /// Schedules an auto-backup with a debounce delay to avoid spamming during high activity
  void scheduleAutoBackup() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(minutes: 2), () {
      triggerAutoBackup();
    });
  }

  /// Automatically creates a snapshot and uploads it if auto-backup is enabled
  Future<void> triggerAutoBackup() async {
    final settings = SettingsService.instance;
    if (!settings.autoBackupEnabled || _isExporting) return;

    _isExporting = true;
    try {
      debugPrint('Triggering optimized auto-backup...');
      
      // 1. Show notification starting
      await NotificationService.instance.showInstant(
        id: 888,
        title: 'Cloud Backup',
        body: 'Preparing your financial backup...',
      );

      // 2. Create backup in Isolate (already optimized in BackupService)
      final file = await BackupService.instance.createBackup(isSync: true);
      
      if (file != null) {
        // 3. Update notification for upload
        await NotificationService.instance.showInstant(
          id: 888,
          title: 'Cloud Backup',
          body: 'Uploading to cloud storage...',
        );

        final success = await backupToCloud(file);
        
        if (success) {
          await NotificationService.instance.showInstant(
            id: 888,
            title: 'Backup Successful',
            body: 'Your data is safe in the cloud.',
          );
          debugPrint('✅ Auto-backup to cloud successful');
        } else {
          await NotificationService.instance.showInstant(
            id: 888,
            title: 'Backup Failed',
            body: 'Cloud upload failed. Please check your connection.',
          );
          debugPrint('❌ Auto-backup failed: Upload error');
        }
      }
    } catch (e) {
      debugPrint('Backup internal error: $e');
    } finally {
      _isExporting = false;
    }
  }

  Future<void> _resolveProvider() async {
    final google = GoogleDriveProvider.instance;
    if (await google.isSignedIn()) {
      _currentProvider = google;
      return;
    }
    final dropbox = DropboxProvider.instance;
    if (await dropbox.isSignedIn()) {
      _currentProvider = dropbox;
      return;
    }
  }
}

