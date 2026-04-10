import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/sync_engine.dart';
import '../services/backup_service.dart';
import '../utils/app_format.dart';

class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final syncEngine = Provider.of<SyncEngine>(context);
    final cs = Theme.of(context).colorScheme;
    final lastBackup = BackupService.instance.lastBackupAt;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (syncEngine.status) {
      case SyncStatus.syncing:
        statusColor = cs.primary;
        statusText = 'Syncing...';
        statusIcon = Icons.sync;
        break;
      case SyncStatus.newBackupAvailable:
        statusColor = cs.tertiary;
        statusText = 'New backup available';
        statusIcon = Icons.cloud_download;
        break;
      case SyncStatus.offline:
        statusColor = cs.error;
        statusText = 'Drive Offline';
        statusIcon = Icons.cloud_off;
        break;
      case SyncStatus.connected:
        statusColor = Colors.green;
        statusText = 'Cloud Connected';
        statusIcon = Icons.cloud_done;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(statusIcon, color: statusColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusText,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                    ),
                    Text(
                      lastBackup != null
                          ? 'Last Backup: ${AppFormat.dateTime(lastBackup)}'
                          : 'No backups yet',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                onPressed: () => syncEngine.checkRemoteBackup(),
                icon: Icon(Icons.refresh, size: 20, color: cs.primary),
                tooltip: 'Check for Updates',
                style: IconButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
          if (syncEngine.status == SyncStatus.newBackupAvailable) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => syncEngine.manualRestore(),
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Restore Latest'),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.tertiary,
                  foregroundColor: cs.onTertiary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
