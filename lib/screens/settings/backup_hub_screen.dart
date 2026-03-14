import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/backup_service.dart';
import '../../services/export_service.dart';
import '../../services/cloud_backup_service.dart';
import '../../services/google_drive_provider.dart';
import '../../services/dropbox_provider.dart';
import '../../services/notification_service.dart';
// AppTheme import removed

import '../../widgets/custom_snackbar.dart';
import '../import_screen.dart';
import '../../services/settings_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../../widgets/custom_dialog.dart';
import '../../widgets/settings_tile.dart';
import '../../widgets/spendx_app_bar.dart';


class BackupHubScreen extends StatefulWidget {
  const BackupHubScreen({super.key});

  @override
  State<BackupHubScreen> createState() => _BackupHubScreenState();
}

class _BackupHubScreenState extends State<BackupHubScreen> {
  List<File> _backups = [];
  List<CloudFile> _cloudBackups = [];
  bool _isLoading = true;
  bool _isCloudLoading = false;
  CloudProvider? _activeProvider;

  @override
  void initState() {
    super.initState();
    _loadBackups();
    _checkCloudStatus().then((_) {
      if (_activeProvider != null) {
        _syncWithCloud(silent: true);
      }
    });
  }

  Future<void> _checkCloudStatus() async {
    // Check if any provider is already signed in (default to Google for now)
    final google = GoogleDriveProvider.instance;
    final isConnected = await google
        .recoverSession(); // Try silent recovery when opening this screen

    if (isConnected) {
      if (!mounted) return;
      setState(() {
        _activeProvider = google;
        CloudBackupService.instance.setProvider(google);
      });
      _loadCloudBackups();
    }
  }

  Future<void> _loadCloudBackups() async {
    if (_activeProvider == null) return;
    setState(() => _isCloudLoading = true);
    final cloudFiles = await _activeProvider!.listFiles();
    if (!mounted) return;
    setState(() {
      _cloudBackups = cloudFiles;
      _isCloudLoading = false;
    });
  }

  Future<void> _connectCloud(CloudProvider provider) async {
    final success = await provider.signIn();
    if (success) {
      if (!mounted) return;
      setState(() {
        _activeProvider = provider;
        CloudBackupService.instance.setProvider(provider);
      });
      CustomSnackBar.show(context, message: 'Connected to ${provider.name}!');
      _loadCloudBackups();
    } else if (provider is DropboxProvider &&
        dotenv.get('DROPBOX_CLIENT_ID', fallback: '').isNotEmpty) {
      // Show manual token entry for Dropbox
      _showDropboxTokenDialog(provider);
    } else {
      CustomSnackBar.show(
        context,
        message: 'Failed to connect to ${provider.name}',
        isError: true,
      );
    }
  }

  void _showDropboxTokenDialog(DropboxProvider dropbox) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        title: Text(
          'Dropbox Authentication',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '1. A browser tab should have opened. Log in and allow SpendX.\n2. Copy the "access_token" from the resulting URL (it looks like a long string of letters/numbers).\n3. Paste it below:',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'Paste Access Token',
                hintStyle: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                ),
                filled: true,
                fillColor: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final token = controller.text.trim();
              if (token.isNotEmpty) {
                await dropbox.setAccessToken(token);
                // Also set it as the active provider in the service
                CloudBackupService.instance.setProvider(dropbox);
                if (mounted) {
                  setState(() => _activeProvider = dropbox);
                  Navigator.pop(ctx);
                  _checkCloudStatus();
                  _loadCloudBackups();
                  CustomSnackBar.show(context, message: '✅ Dropbox connected!');
                }
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadToCloud(File file) async {
    if (_activeProvider == null) {
      CustomSnackBar.show(
        context,
        message: 'Please connect to cloud first',
        isError: true,
      );
      return;
    }
    // Show system upload notification
    await NotificationService.instance.showBackupStarted();
    CustomSnackBar.show(
      context,
      message: 'Uploading to ${_activeProvider!.name}...',
    );
    final success = await CloudBackupService.instance.backupToCloud(file);
    await NotificationService.instance.showBackupComplete(success);
    if (success) {
      CustomSnackBar.show(context, message: '✅ Uploaded successfully!');
      _loadCloudBackups();
    } else {
      CustomSnackBar.show(context, message: 'Upload failed', isError: true);
    }
  }

  Future<void> _syncWithCloud({bool silent = false}) async {
    if (_activeProvider == null) {
      if (!silent)
        CustomSnackBar.show(
          context,
          message: 'Please connect to cloud first',
          isError: true,
        );
      return;
    }

    setState(() => _isCloudLoading = true);
    if (!silent)
      CustomSnackBar.show(context, message: 'Checking for updates...');

    final update = await CloudBackupService.instance.checkForUpdates();

    if (update != null) {
      // Only prompt restore if cloud file is NEWER than last local sync
      final lastSync = SettingsService.instance.lastSyncTime;
      final cloudIsNewer =
          lastSync == null || update.modifiedAt.isAfter(lastSync);

      if (mounted) {
        setState(() => _isCloudLoading = false);
        if (cloudIsNewer) {
          _confirmCloudRestore(update);
        } else {
          // Cloud has a file but it's not newer – we're already up-to-date or ahead
          if (!silent)
            CustomSnackBar.show(context, message: '✅ Already up to date');
          await SettingsService.instance.setLastSyncTime(DateTime.now());
        }
      }
    } else {
      if (mounted) {
        setState(() => _isCloudLoading = false);
        if (!silent)
          CustomSnackBar.show(context, message: '✅ Already up to date');
        await SettingsService.instance.setLastSyncTime(DateTime.now());
      }
    }
  }

  Future<void> _switchAccount() async {
    if (_activeProvider == null) return;

    final confirmed = await CustomDialog.show(
      context,
      title: 'Switch Account?',
      message:
          'This will sign you out of your current ${_activeProvider!.name} account so you can link a different one.',
      primaryButtonText: 'Sign Out & Switch',
      secondaryButtonText: 'Cancel',
      type: DialogType.info,
    );

    if (confirmed == true) {
      final provider = _activeProvider!;
      await provider.signOut();
      if (!mounted) return;
      setState(() {
        _activeProvider = null;
        _cloudBackups = [];
      });
      CloudBackupService.instance.setProvider(null as dynamic);

      // Immediately trigger sign-in flow for the same provider type
      _connectCloud(provider);
    }
  }

  Future<void> _resetCloudData() async {
    if (_activeProvider == null) return;

    final confirmed = await CustomDialog.show(
      context,
      title: 'ERASE ALL CLOUD DATA?',
      message:
          'This will permanently delete ALL backups for SpendX from your ${_activeProvider!.name} storage. This action is irreversible.',
      primaryButtonText: 'Erase Everything',
      secondaryButtonText: 'Cancel',
      type: DialogType.warning,
    );

    if (confirmed == true) {
      setState(() => _isCloudLoading = true);
      final success = await _activeProvider!.wipeAllData();
      if (mounted) {
        setState(() => _isCloudLoading = false);
        if (success) {
          CustomSnackBar.show(
            context,
            message: '✅ Cloud storage has been reset',
          );
          _loadCloudBackups();
        } else {
          CustomSnackBar.show(
            context,
            message: 'Failed to wipe cloud data',
            isError: true,
          );
        }
      }
    }
  }

  Future<void> _disconnectCloud() async {
    if (_activeProvider == null) return;

    final confirmed = await CustomDialog.show(
      context,
      title: 'Unlink ${_activeProvider!.name}?',
      message:
          'Your cloud backups will remain safe, but this device will stop syncing until you link again.',
      primaryButtonText: 'Unlink Account',
      secondaryButtonText: 'Cancel',
      type: DialogType.warning,
    );

    if (confirmed == true) {
      await _activeProvider!.signOut();
      setState(() {
        _activeProvider = null;
        _cloudBackups = [];
      });
      CloudBackupService.instance.setProvider(null as dynamic);
      CustomSnackBar.show(context, message: 'Account unlinked successfully');
    }
  }

  Future<void> _deleteCloudFile(CloudFile cloudFile) async {
    if (_activeProvider == null) return;

    final confirmed = await CustomDialog.show(
      context,
      title: 'Delete from Cloud?',
      message:
          'Are you sure you want to delete "${cloudFile.name}" from your cloud storage? This cannot be undone.',
      primaryButtonText: 'Delete Forever',
      secondaryButtonText: 'Cancel',
      type: DialogType.warning,
    );

    if (confirmed == true) {
      setState(() => _isCloudLoading = true);
      final success = await _activeProvider!.deleteFile(cloudFile.id);
      if (mounted) {
        setState(() => _isCloudLoading = false);
        if (success) {
          CustomSnackBar.show(context, message: '✅ Deleted from cloud');
          _loadCloudBackups();
        } else {
          CustomSnackBar.show(
            context,
            message: 'Failed to delete file',
            isError: true,
          );
        }
      }
    }
  }

  Future<void> _confirmCloudRestore(CloudFile cloudFile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_download_outlined,
                  color: Theme.of(context).colorScheme.primary,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Restore from Cloud',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 24),
              _dialogDetailRow('File', cloudFile.name),
              _dialogDetailRow(
                'Size',
                '${(cloudFile.size / 1024).toStringAsFixed(1)} KB',
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(height: 1),
              ),
              Text(
                'This will overwrite your current device data. This action is irreversible.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        elevation: 0,
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Download & Restore'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      if (_activeProvider == null) return;

      setState(() => _isLoading = true);
      CustomSnackBar.show(
        context,
        message: 'Downloading snapshot from ${_activeProvider!.name}...',
      );

      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/${cloudFile.name}';

      final file = await _activeProvider!.downloadFile(
        fileId: cloudFile.id,
        localPath: localPath,
      );

      if (file != null) {
        final success = await BackupService.instance.restoreFromBackup(file);
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          if (success) {
            CustomSnackBar.show(
              context,
              message: '✅ Cloud restore successful!',
            );
            Navigator.of(context).popUntil((route) => route.isFirst);
          } else {
            CustomSnackBar.show(
              context,
              message: 'Failed to apply snapshot',
              isError: true,
            );
          }
        }
      } else {
        if (mounted) {
          setState(() => _isLoading = false);
          CustomSnackBar.show(
            context,
            message: 'Download failed',
            isError: true,
          );
        }
      }
    }
  }

  Future<void> _loadBackups() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final backups = await BackupService.instance.getLocalBackups();
    if (!mounted) return;
    setState(() {
      _backups = backups;
      _isLoading = false;
    });
  }

  Future<void> _cleanupOldBackups() async {
    final confirmed = await CustomDialog.show(
      context,
      title: 'Clean Up Storage?',
      message:
          'This will delete all old local snapshots except for your active sync file. This is recommended to save space.',
      primaryButtonText: 'Clean Up',
      secondaryButtonText: 'Cancel',
      type: DialogType.info,
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      int count = 0;
      for (final file in _backups) {
        if (!file.path.contains('sync_')) {
          await BackupService.instance.deleteBackup(file);
          count++;
        }
      }
      if (mounted) {
        setState(() => _isLoading = false);
        CustomSnackBar.show(context, message: '✅ Removed $count old snapshots');
        _loadBackups();
      }
    }
  }

  Future<void> _createBackup() async {
    final hasProvider = _activeProvider != null;
    if (hasProvider) {
      await NotificationService.instance.showBackupStarted();
    }
    CustomSnackBar.show(
      context,
      message: hasProvider
          ? 'Syncing to ${_activeProvider!.name}...'
          : 'Saving sync file...',
    );

    // Always use isSync: true now to keep storage efficient
    final file = await BackupService.instance.createBackup(isSync: true);
    if (!mounted) return;

    if (file != null) {
      await SettingsService.instance.setLastBackupTime(DateTime.now());
      if (hasProvider) {
        final success = await CloudBackupService.instance.backupToCloud(file);
        await NotificationService.instance.showBackupComplete(success);
        if (mounted) {
          if (success) {
            CustomSnackBar.show(context, message: '✅ Cloud sync successful!');
            await SettingsService.instance.setLastSyncTime(DateTime.now());
            _loadCloudBackups();
          } else {
            CustomSnackBar.show(
              context,
              message: 'Saved locally, but cloud sync failed',
              isError: true,
            );
          }
        }
      } else {
        CustomSnackBar.show(
          context,
          message: '✅ Sync file saved successfully!',
        );
      }
      _loadBackups();
    } else {
      if (hasProvider)
        await NotificationService.instance.showBackupComplete(false);
      CustomSnackBar.show(
        context,
        message: 'Failed to create sync file',
        isError: true,
      );
    }
  }

  Future<void> _confirmRestore(File file) async {
    final name = file.path.split('/').last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.history,
                  color: Theme.of(context).colorScheme.error,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Restore Snapshot',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 24),
              _dialogDetailRow('File', name),
              _dialogDetailRow(
                'Size',
                '${(file.lengthSync() / 1024).toStringAsFixed(1)} KB',
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(height: 1),
              ),
              Text(
                'This will wipe all CURRENT data and replace it with this local snapshot. This cannot be undone.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        elevation: 0,
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Restore Now'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      final success = await BackupService.instance.restoreFromBackup(file);
      if (!mounted) return;
      setState(() => _isLoading = false);

      if (success) {
        if (mounted) {
          CustomSnackBar.show(
            context,
            message: '✅ Restore successful! Data reloaded.',
          );
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      } else {
        if (mounted) {
          CustomSnackBar.show(
            context,
            message: 'Failed to restore snapshot',
            isError: true,
          );
        }
      }
    }
  }

  String _intervalLabel(String interval) {
    switch (interval) {
      case 'realtime':
        return 'Real-time (on every change)';
      case '30min':
        return 'Every 30 minutes';
      case '1hr':
        return 'Every hour';
      case 'daily':
        return 'Daily';
      default:
        return 'Off';
    }
  }

  Widget _dialogDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _showIntervalPicker(SettingsService settings) {
    final intervals = [
      ('realtime', 'Real-time', 'Sync on every transaction'),
      ('30min', '30 Minutes', 'Sync every half hour'),
      ('1hr', 'Hourly', 'Sync once per hour'),
      ('daily', 'Daily', 'Sync once a day'),
      ('off', 'Off', 'No automatic syncing'),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Auto-Backup Interval',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ...intervals.map((item) {
              final (value, label, desc) = item;
              final selected = settings.autoBackupInterval == value;
              return RadioListTile<String>(
                value: value,
                groupValue: settings.autoBackupInterval,
                onChanged: (v) async {
                  if (v != null) {
                    await settings.setAutoBackupInterval(v);
                    setSheet(() {});
                    setState(() {});
                    if (mounted) Navigator.pop(context);
                  }
                },
                title: Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  desc,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
                activeColor: Theme.of(context).colorScheme.primary,
                controlAffinity: ListTileControlAffinity.trailing,
              );
            }),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: SpendXAppBar(
          title: 'Backup Hub',

          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.05),
                ),
              ),
              child: TabBar(
                tabs: const [
                  Tab(text: 'Cloud Sync'),
                  Tab(text: 'Import'),
                  Tab(text: 'Export'),
                ],
                indicator: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.5),
                  ),
                ),
                indicatorColor: Theme.of(context).colorScheme.primary,
                labelColor: Theme.of(context).colorScheme.primary,
                unselectedLabelColor: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant,
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
        body: TabBarView(
          children: [
            _buildSnapshotsTab(),
            const ImportScreen(),
            _buildExportTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildBackupHealthCard(SettingsService settings) {
    final lastBackup = settings.lastBackupTime;
    final hasProvider = _activeProvider != null;

    String status = 'Critical';
    String message = 'No backup detected';
    List<Color> colors = [
      const Color(0xFF7F1D1D),
      const Color(0xFFEF4444),
    ]; // Red
    IconData icon = Icons.error_outline;

    if (lastBackup != null) {
      final diff = DateTime.now().difference(lastBackup);
      if (diff.inDays >= 7) {
        status = 'Warning';
        message = 'Last backup: ${diff.inDays} days ago';
        colors = [const Color(0xFF9A3412), const Color(0xFFF97316)]; // Orange
        icon = Icons.warning_amber_rounded;
      } else {
        status = 'Healthy';
        final timeAgo = diff.inHours > 0
            ? '${diff.inHours} hours ago'
            : '${diff.inMinutes} minutes ago';
        message =
            'Last backup: $timeAgo\n${hasProvider ? "Cloud sync active (${_activeProvider!.name})" : "Local backup only"}';
        colors = [const Color(0xFF065F46), const Color(0xFF10B981)]; // Green
        icon = Icons.check_circle_outline;
      }
    }

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Backup Health: $status',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapshotsTab() {
    final settings = SettingsService.instance;
    return ListView(
      children: [
        // 1. Backup Health
        _buildBackupHealthCard(settings),

        // 2. Cloud Sync
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Icon(
                Icons.cloud_done_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                'Cloud Sync',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              SettingsTile(
                icon: Icons.add_to_drive,
                color: const Color(0xFF4285F4),
                title: 'Google Drive',
                subtitle: _activeProvider?.name == 'Google Drive'
                    ? 'Connected'
                    : 'Tap to link account',
                onTap: _activeProvider?.name == 'Google Drive'
                    ? () {}
                    : () => _connectCloud(GoogleDriveProvider.instance),
                trailing: _activeProvider?.name == 'Google Drive'
                    ? _buildProviderActions()
                    : null,
              ),
              SettingsTile(
                icon: Icons.cloud_queue,
                color: const Color(0xFF0061FF),
                title: 'Dropbox',
                subtitle: _activeProvider?.name == 'Dropbox'
                    ? 'Connected'
                    : 'Tap to link account',
                onTap: _activeProvider?.name == 'Dropbox'
                    ? () {}
                    : () => _connectCloud(DropboxProvider.instance),
                trailing: _activeProvider?.name == 'Dropbox'
                    ? _buildProviderActions()
                    : null,
              ),
              SettingsTile(
                icon: Icons.cloud_off,
                color: Theme.of(context).colorScheme.error,
                title: 'Restore from another account',
                subtitle: 'Link another Google/Dropbox account to restore',
                onTap: _switchAccount,
                trailing: const Icon(Icons.swap_horiz, size: 14),
              ),
            ],
          ),
        ),

        // 3. Manual Backup
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child: Row(
            children: [
              Icon(
                Icons.backup_outlined,
                color: Theme.of(context).colorScheme.secondary,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                'Manual Backup',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              SettingsTile(
                icon: Icons.upload_file,
                color: Theme.of(context).colorScheme.secondary,
                title: 'Create Manual Snapshot',
                subtitle: 'Save local backup & sync to cloud',
                onTap: _createBackup,
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
              ),
              SettingsTile(
                icon: Icons.schedule,
                color: Theme.of(context).colorScheme.tertiary,
                title: 'Auto-Backup Interval',
                subtitle: _intervalLabel(settings.autoBackupInterval),
                onTap: () => _showIntervalPicker(settings),
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
              ),
            ],
          ),
        ),

        // 4. Backup History
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child: Row(
            children: [
              Icon(
                Icons.history_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                'Backup History',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_backups.any((f) => !f.path.contains('sync_')))
                TextButton(
                  onPressed: _cleanupOldBackups,
                  child: Text(
                    'Clean Old',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),

        if (_isLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_backups.isEmpty && _cloudBackups.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No backup history found.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          _buildHistoryList(),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildProviderActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: _syncWithCloud,
          tooltip: 'Check Updates',
        ),
        IconButton(
          icon: const Icon(Icons.link_off, size: 20),
          onPressed: _disconnectCloud,
          tooltip: 'Unlink',
        ),
      ],
    );
  }

  Widget _buildHistoryList() {
    final allItems = [
      ..._cloudBackups.map((f) => (f, true)),
      ..._backups.map((f) => (f, false)),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: allItems.length,
        separatorBuilder: (context, index) => Divider(
          height: 1,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.05),
          indent: 56,
        ),
        itemBuilder: (context, index) {
          final item = allItems[index];
          if (item.$2) {
            final f = item.$1 as CloudFile;
            final parts = f.name.split('_');
            String device = 'Unknown Device';
            String dateLabel = 'Unknown Date';
            
            if (f.name.contains('sync_')) {
              device = parts.length > 2 ? parts[2].split('.').first : 'Unknown';
              dateLabel = 'Active Sync';
            } else if (f.name.contains('backup_')) {
              device = parts.length > 2 ? parts[2] : 'Unknown';
              dateLabel = parts.length > 3 ? parts[3].split('.').first : 'Backup';
            }

            return ListTile(
              leading: Icon(
                Icons.cloud_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(
                device,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${DateFormat('MMM d, h:mm a').format(f.modifiedAt)} · ${(f.size / 1024).toStringAsFixed(1)} KB',
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => _confirmCloudRestore(f),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _deleteCloudFile(f),
              ),
            );
          } else {
            final f = item.$1 as File;
            final name = f.path.split('/').last;
            final isSync = name.contains('sync_');
            final parts = name.split('_');
            String device = 'Local';
            if (isSync) {
              device = parts.length > 2 ? parts[2].split('.').first : 'Local';
            } else {
              device = parts.length > 2 ? parts[2] : 'Local';
            }

            return ListTile(
              leading: Icon(
                isSync ? Icons.sync : Icons.storage_outlined,
                color: Theme.of(context).colorScheme.secondary,
              ),
              title: Text(
                isSync ? 'Active Sync ($device)' : 'Snapshot ($device)',
                style: const TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                '${DateFormat('MMM d, h:mm a').format(f.lastModifiedSync())} · ${(f.lengthSync() / 1024).toStringAsFixed(1)} KB',
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => _confirmRestore(f),
              trailing: !isSync
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => BackupService.instance
                          .deleteBackup(f)
                          .then((_) => _loadBackups()),
                    )
                  : null,
            );
          }
        },
      ),
    );
  }

  Widget _buildImportTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _hubCard(
          title: 'AI Statement Scan',
          subtitle: 'Scan PDF or Images of bank statements using Gemini AI',
          icon: Icons.auto_awesome,
          color: Colors.teal,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const ImportScreen(initialMethod: 'ai'),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _hubCard(
          title: 'Bulk CSV Import',
          subtitle: 'Map and import standard bank CSV files',
          icon: Icons.table_view,
          color: Colors.orange,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const ImportScreen(initialMethod: 'csv'),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildExportTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _hubCard(
          title: 'Export as CSV',
          subtitle: 'Readable spreadsheet compatible with Excel/Sheets',
          icon: Icons.grid_on,
          color: Colors.green,
          onTap: () => ExportService.instance.exportTransactionsToCsv(),
        ),
        const SizedBox(height: 16),
        _hubCard(
          title: 'Export as JSON',
          subtitle: 'Developer friendly format for data portability',
          icon: Icons.code,
          color: Colors.deepPurple,
          onTap: () => ExportService.instance.exportTransactionsToJson(),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.blue, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Exports include all transactions. Snapshots (in the first tab) include everything: vehicles, cards, and settings.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hubCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            trailing ??
                Icon(
                  Icons.chevron_right,
                  color: Theme.of(context).colorScheme.outline,
                ),
          ],
        ),
      ),
    );
  }

  Widget _snapshotTile(
    String name,
    String date,
    String size,
    File file, {
    bool canUpload = false,
    bool isSync = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.file_present_outlined,
            color: Colors.blueAccent,
          ),
        ),
        title: Text(
          name
              .replaceFirst('spendx_backup_', '')
              .replaceFirst(BackupService.backupExtension, ''),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        subtitle: Text(
          '$date · $size',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canUpload)
              IconButton(
                icon: const Icon(
                  Icons.cloud_upload_outlined,
                  color: Colors.blueAccent,
                  size: 20,
                ),
                onPressed: () => _uploadToCloud(file),
                tooltip: 'Upload to Cloud',
              ),
            IconButton(
              icon: const Icon(
                Icons.restore,
                color: Colors.greenAccent,
                size: 20,
              ),
              onPressed: () => _confirmRestore(file),
              tooltip: 'Restore',
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
                size: 20,
              ),
              onPressed: () async {
                await BackupService.instance.deleteBackup(file);
                _loadBackups();
              },
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String text, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            color: Theme.of(context).colorScheme.outlineVariant,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            text,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // Removed _simpleTile in favor of SettingsTile widget
}
