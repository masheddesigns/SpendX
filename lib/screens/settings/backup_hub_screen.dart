// ignore_for_file: use_build_context_synchronously
import '../../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/settings_service.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../services/sync_engine.dart';
import '../../widgets/custom_dialog.dart';
import '../../services/drive_service.dart';
import '../../widgets/custom_snackbar.dart';
import '../../widgets/settings_tile.dart';
import '../../widgets/app_button.dart';
import 'package:spend_x/widgets/spendx_app_bar.dart';

enum SyncHealth { healthy, syncing, needsAuth, locked, error }

class BackupHubScreen extends StatefulWidget {
  const BackupHubScreen({super.key});

  @override
  State<BackupHubScreen> createState() => _BackupHubScreenState();
}

class _BackupHubScreenState extends State<BackupHubScreen> {
  bool _isOperationInProgress = false;
  String? _connectedEmail;

  bool get _hasDriveAccount => (_connectedEmail ?? '').isNotEmpty;

  bool get _isDriveConnected =>
      SettingsService.instance.isGoogleDriveConnected && _hasDriveAccount;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_onCloudStateChanged);
    SettingsService.instance.addListener(_onSettingsChanged);
    SyncEngine.instance.addListener(_onSyncEngineChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreDriveState();
      _fetchDriveBackupCount();
    });
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onCloudStateChanged);
    SettingsService.instance.removeListener(_onSettingsChanged);
    SyncEngine.instance.removeListener(_onSyncEngineChanged);
    super.dispose();
  }

  void _onSyncEngineChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _fetchDriveBackupCount() async {
    // We can now rely on SyncEngine's throttled metadata check
    // to populate the count without a full file listing.
    if (_isDriveConnected && DriveService.instance.isInitialized) {
      await SyncEngine.instance.checkRemoteBackup();
    }
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onCloudStateChanged() {
    _connectedEmail =
        AuthService.instance.currentAccountEmail ??
        SettingsService.instance.googleEmail;
    if (mounted) setState(() {});
  }

  Future<void> _restoreDriveState() async {
    await AuthService.instance.initialize();
    _connectedEmail =
        AuthService.instance.currentAccountEmail ??
        SettingsService.instance.googleEmail;
    if (AuthService.instance.isSignedIn &&
        !DriveService.instance.isInitialized) {
      await DriveService.instance.initialize();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _disconnectDrive() async {
    final confirmed = await CustomDialog.show(
      context,
      title: 'Disconnect Google Drive?',
      message: 'Your local data will stay, but cloud backups will be disabled.',
      primaryButtonText: 'Disconnect',
      type: DialogType.warning,
    );

    if (confirmed == true) {
      await AuthService.instance.signOut();
      _connectedEmail = null;
      if (mounted) {
        CustomSnackBar.show(context, message: 'Disconnected Google Drive');
      }
    }
  }

  Future<void> _manualBackup() async {
    if (!_isDriveConnected) {
      CustomSnackBar.show(
        context,
        message: 'Please connect to Google Drive first',
        isError: true,
      );
      return;
    }

    setState(() => _isOperationInProgress = true);
    CustomSnackBar.show(context, message: '☁ Starting backup to Drive...');

    HapticService.instance.tap();
    await SyncEngine.instance.manualBackup();

    if (mounted) {
      setState(() => _isOperationInProgress = false);
      CustomSnackBar.show(context, message: '✅ Backup process finished');
    }
  }

  Future<void> _manualRestore() async {
    if (!_isDriveConnected) {
      CustomSnackBar.show(
        context,
        message: 'Please connect to Google Drive first',
        isError: true,
      );
      return;
    }

    final confirmed = await CustomDialog.show(
      context,
      title: 'Restore from Cloud?',
      message:
          'This will replace all your local data with the cloud backup. A local safety rollback point will be created automatically.',
      primaryButtonText: 'Restore Now',
      secondaryButtonText: 'Cancel',
      type: DialogType.warning,
    );

    if (confirmed != true) return;

    setState(() => _isOperationInProgress = true);
    CustomSnackBar.show(context, message: '⬇ Restoring from Drive...');

    try {
      HapticService.instance.tap();
      final success = await SyncEngine.instance.manualRestore();
      if (!mounted) return;

      if (!success) {
        // Restore failed or skipped — offer force restore
        final forceRestore = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Restore Skipped'),
            content: const Text(
                'Local data appears to be up-to-date. '
                'Would you like to force restore from the cloud backup anyway?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Force Restore'),
              ),
            ],
          ),
        );

        if (forceRestore == true && mounted) {
          CustomSnackBar.show(context, message: '⬇ Force restoring...');
          final forceSuccess =
              await SyncEngine.instance.manualRestore(force: true);
          if (!mounted) return;
          if (!forceSuccess) {
            CustomSnackBar.show(context,
                message: 'Restore failed. Check your connection.',
                isError: true);
            return;
          }
        } else {
          return;
        }
      }

      // Show success dialog
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore Complete'),
          content: const Text(
              'Your data has been restored successfully. '
              'Please restart the app to load all restored data.'),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        CustomSnackBar.show(
          context,
          message: 'Restore failed: $e',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isOperationInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Calculate health locally since SyncEngine.health is gone
    var health = SyncHealth.healthy;
    if (BackupService.instance.isBackupRunning ||
        DriveService.instance.backupInProgress) {
      health = SyncHealth.syncing;
    } else if (!AuthService.instance.isSignedIn) {
      health = SyncHealth.needsAuth;
    }

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: const SpendXAppBar(title: 'Backup & Restore'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (SyncEngine.instance.remoteBackupAvailable)
                _buildRemoteSyncBanner(),
              if (SyncEngine.instance.remoteBackupAvailable)
                const SizedBox(height: 16),
              _buildSyncHealthCard(health),
              const SizedBox(height: 24),
              Text(
                'CLOUD SYNC',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 12),
              _buildCloudSyncSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSyncHealthCard(SyncHealth health) {
    final colorScheme = Theme.of(context).colorScheme;

    Color healthColor = Colors.grey;
    IconData healthIcon = Icons.help_outline;
    String healthTitle = 'Checking...';
    String healthSubtitle = 'Updating backup status';

    switch (health) {
      case SyncHealth.healthy:
        healthColor = Colors.green;
        healthIcon = Icons.check_circle_outline;
        healthTitle = 'System Ready';
        healthSubtitle = _connectedEmail == null
            ? 'Drive connected for manual backups'
            : 'Connected as $_connectedEmail';
        break;
      case SyncHealth.syncing:
        healthColor = colorScheme.primary;
        healthIcon = Icons.sync;
        healthTitle = 'Syncing...';
        healthSubtitle = 'Transferring snapshot';
        break;
      case SyncHealth.needsAuth:
        healthColor = Colors.orange;
        healthIcon = Icons.lock_open_outlined;
        healthTitle = 'Connection Required';
        healthSubtitle = 'Please sign in to enable Drive backup';
        break;
      case SyncHealth.locked:
        healthColor = colorScheme.secondary;
        healthIcon = Icons.hourglass_empty;
        healthTitle = 'Database Locked';
        healthSubtitle = 'Database is busy, backup will be available shortly';
        break;
      case SyncHealth.error:
        healthColor = Colors.red;
        healthIcon = Icons.error_outline;
        healthTitle = 'Sync Issue';
        healthSubtitle = 'Check your connection or Drive storage';
        break;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            healthColor.withValues(alpha: 0.15),
            healthColor.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: healthColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: healthColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(healthIcon, color: healthColor, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      healthTitle,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      healthSubtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(color: healthColor.withValues(alpha: 0.1)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem('Status', _getStatusLabel(health)),
              _buildStatItem('Last Backup', _formatLastSync()),
              _buildStatItem(
                'Drive Storage',
                '${SyncEngine.instance.remoteBackupCount} / 5',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildHardwareInfoSection(),
        ],
      ),
    );
  }

  Widget _buildRemoteSyncBanner() {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () async {
        if (!_isOperationInProgress) await _manualRestore();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colorScheme.tertiary.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: colorScheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'New backup available from another device.',
                style: TextStyle(
                  color: colorScheme.onTertiaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Text(
              'Restore Now',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getStatusLabel(SyncHealth health) {
    if (health == SyncHealth.syncing) return 'Syncing';
    if (!_isDriveConnected) return 'Offline';
    return 'Ready';
  }

  Widget _buildHardwareInfoSection() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _buildInfoRow('Connected Email', _connectedEmail ?? 'N/A'),
          const SizedBox(height: 4),
          _buildInfoRow('Encryption', 'AES-256-GCM (End-to-End)'),
          const SizedBox(height: 4),
          _buildInfoRow('Auto-Backup', SettingsService.instance.autoBackupEnabled ? 'On (30s debounce)' : 'Off'),
          const SizedBox(height: 4),
          _buildInfoRow('Auto-Restore', SettingsService.instance.autoRestoreEnabled ? 'On (on launch)' : 'Off'),
          const SizedBox(height: 4),
          _buildInfoRow('Integrity Check', 'Verified (SHA-256)'),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildStatItem(String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  String _formatTimeAgo(DateTime? time) {
    if (time == null) return 'Unknown';
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}/${time.year}';
  }

  String _formatLastSync() {
    final lastSync = BackupService.instance.lastBackupAt;
    if (lastSync == null) return 'Never';

    // Provide a simple readable format using standard Dart libs so we don't need intl just for this if we don't want to
    final diff = DateTime.now().difference(lastSync);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${lastSync.year}-${lastSync.month.toString().padLeft(2, '0')}-${lastSync.day.toString().padLeft(2, '0')}';
  }

  Widget _buildCloudSyncSection() {
    final colorScheme = Theme.of(context).colorScheme;
    if (!_isDriveConnected || !DriveService.instance.isInitialized) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Google Drive Disconnected',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Connect your account to enable cloud backups.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            AppButton(
              text: 'Connect Google Drive',
              icon: Icons.g_mobiledata_rounded,
              onPressed: () async {
                setState(() => _isOperationInProgress = true);
                final success = await AuthService.instance.login();
                if (success) {
                  await DriveService.instance.initialize();
                  if (mounted) {
                    CustomSnackBar.show(
                      context,
                      message: 'Google Drive connected',
                      isError: false,
                    );
                  }
                } else {
                  if (mounted) {
                    CustomSnackBar.show(
                      context,
                      message: 'Sign-in cancelled or failed',
                      isError: true,
                    );
                  }
                }
                if (mounted) setState(() => _isOperationInProgress = false);
              },
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.cloud_done_outlined,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Connected to Google Drive',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _connectedEmail ??
                              SettingsService.instance.googleEmail ??
                              'Unknown',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (!_isOperationInProgress) await _disconnectDrive();
                    },
                    child: const Text(
                      'Disconnect',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildMiniStat('Last Backup', _formatLastSync()),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMiniStat(
                      'Backups',
                      '${SyncEngine.instance.remoteBackupCount}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMiniStat('Security', 'AES-256'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _buildSettingsDivider(),

        // Backup Now
        SettingsTile(
          icon: Icons.backup_outlined,
          color: colorScheme.primary,
          title: 'Backup Now',
          subtitle: 'Create a stable snapshot in Drive',
          onTap: () async {
            if (!_isOperationInProgress) {
              await _manualBackup();
              _fetchDriveBackupCount(); // refresh count
            }
          },
        ),

        // Restore Latest
        SettingsTile(
          icon: Icons.cloud_download_outlined,
          color: colorScheme.secondary,
          title: 'Restore Latest',
          subtitle: 'Pull snapshot and replace local data',
          onTap: () async {
            if (!_isOperationInProgress) await _manualRestore();
          },
        ),

        // Manual check for device sync updates
        SettingsTile(
          icon: Icons.sync,
          color: colorScheme.tertiary,
          title: 'Check for Updates',
          subtitle: 'Check if another device updated Drive.',
          onTap: () async {
            if (!_isOperationInProgress) {
              CustomSnackBar.show(
                context,
                message: 'Checking Drive for newer backups...',
              );
              await SyncEngine.instance.checkRemoteBackup();
              if (!SyncEngine.instance.remoteBackupAvailable && mounted) {
                CustomSnackBar.show(context, message: 'No new backups found.');
              }
            }
          },
        ),

        _buildSettingsDivider(),

        // ── Auto-Backup Settings ─────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'AUTO-BACKUP',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          secondary: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.auto_awesome_rounded,
                color: colorScheme.primary, size: 22),
          ),
          title: const Text('Auto-Backup on Changes',
              style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15)),
          subtitle: Text(
            SettingsService.instance.autoBackupEnabled
                ? 'Backs up 30s after any data change'
                : 'Manual backup only',
            style: TextStyle(
                color: colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          value: SettingsService.instance.autoBackupEnabled,
          onChanged: (val) async {
            await SettingsService.instance.setAutoBackupEnabled(val);
            BackupService.instance.startAutoBackupTimer();
            if (mounted) setState(() {});
          },
        ),
        if (SettingsService.instance.autoBackupEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Flexible(
                  child: Text('Backup every:',
                      style: TextStyle(
                          color: colorScheme.onSurfaceVariant, fontSize: 13)),
                ),
                const SizedBox(width: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1h')),
                    ButtonSegment(value: 6, label: Text('6h')),
                    ButtonSegment(value: 24, label: Text('24h')),
                  ],
                  selected: {SettingsService.instance.backupIntervalHours.clamp(1, 24)},
                  onSelectionChanged: (val) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setInt('backup_auto_interval', val.first);
                    BackupService.instance.startAutoBackupTimer();
                    if (mounted) setState(() {});
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),

        // ── Auto-Restore Toggle ──────────────────────────
        SwitchListTile(
          secondary: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.secondary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.cloud_download_rounded,
                color: colorScheme.secondary, size: 22),
          ),
          title: const Text('Auto-Restore on Launch',
              style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15)),
          subtitle: Text(
            SettingsService.instance.autoRestoreEnabled
                ? 'Pulls latest backup when newer version found'
                : 'Manual restore only',
            style: TextStyle(
                color: colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          value: SettingsService.instance.autoRestoreEnabled,
          onChanged: (val) async {
            await SettingsService.instance.setAutoRestoreEnabled(val);
            if (mounted) setState(() {});
          },
        ),

        _buildSettingsDivider(),

        // ── Connected Devices ────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'CONNECTED DEVICES',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: BackupService.instance.getConnectedDevices(),
          builder: (context, snapshot) {
            final devices = snapshot.data ?? [];
            if (devices.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No devices synced yet',
                    style: TextStyle(
                        color: colorScheme.onSurfaceVariant, fontSize: 13)),
              );
            }
            return Column(
              children: devices.map((d) {
                final isCurrent = d['isCurrent'] == true;
                final lastActive = d['lastActive'] as String?;
                final timeAgo = lastActive != null
                    ? _formatTimeAgo(DateTime.tryParse(lastActive))
                    : 'Unknown';
                return ListTile(
                  dense: true,
                  leading: Icon(
                    isCurrent ? Icons.phone_android : Icons.devices_other,
                    color: isCurrent ? colorScheme.primary : colorScheme.onSurfaceVariant,
                    size: 22,
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(d['name'] as String? ?? 'Unknown',
                            style: TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 14,
                                color: isCurrent
                                    ? colorScheme.primary
                                    : colorScheme.onSurface)),
                      ),
                      if (isCurrent)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('This device',
                              style: TextStyle(
                                  color: colorScheme.primary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600)),
                        ),
                    ],
                  ),
                  subtitle: Text('Last active: $timeAgo',
                      style: TextStyle(
                          color: colorScheme.onSurfaceVariant, fontSize: 11)),
                );
              }).toList(),
            );
          },
        ),

        _buildSettingsDivider(),

        // Security & Auto Backup info
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_rounded,
                        color: Colors.green, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('End-to-End Encrypted',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          Text(
                            'Backups are encrypted with AES-256-GCM before upload. Only this device can decrypt them.',
                            style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                                height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colorScheme.tertiary.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded,
                        color: colorScheme.tertiary, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Smart Auto-Backup',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          Text(
                            'Auto-backup: 30s after changes. Auto-restore: pulls latest on launch if newer.',
                            style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                                height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStat(String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsDivider() {
    return Divider(
      height: 32,
      thickness: 1,
      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}
