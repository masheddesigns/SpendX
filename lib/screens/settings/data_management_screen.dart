import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/app_env.dart';
import '../../widgets/spendx_app_bar.dart';
import '../../widgets/settings_tile.dart';
import '../../shared/widgets/app_confirm_dialog.dart';
import '../../widgets/custom_snackbar.dart';
import '../../services/drive_service.dart';
import '../../services/settings_service.dart';
import '../../features/settings/providers/data_management_providers.dart';
import '../debug/debug_hub_screen.dart';

class DataManagementScreen extends ConsumerStatefulWidget {
  const DataManagementScreen({super.key});

  @override
  ConsumerState<DataManagementScreen> createState() =>
      _DataManagementScreenState();
}

class _DataManagementScreenState extends ConsumerState<DataManagementScreen> {
  Future<void> _confirmClear(
    BuildContext context, {
    required String title,
    required String message,
    required Future<void> Function() onClear,
    required String successMessage,
  }) async {
    final confirmed = await AppConfirmDialog.show(
      context,
      title: title,
      message: message,
      confirmLabel: 'Erase Now',
      isDangerous: true,
    );

    if (confirmed == true) {
      await onClear();
      if (context.mounted) {
        CustomSnackBar.show(context, message: successMessage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const SpendXAppBar(title: 'Clear Data'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Clear Data',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Erase locally stored records. This cannot be undone.',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              // ─────────��── CLEAR DATA ────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  'CLEAR BY TYPE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: cs.error,
                  ),
                ),
              ),
              SettingsTile(
                icon: Icons.receipt_long,
                color: cs.primary,
                title: 'Clear Expenses',
                subtitle: 'Delete all expense transactions',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Expenses',
                  message:
                      'This action will permanently erase this data from your device. This cannot be undone.',
                  onClear: () =>
                      ref.read(dataManagementProvider.notifier).clearExpenses(),
                  successMessage: 'Expense data cleared successfully',
                ),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.attach_money,
                color: cs.primary,
                title: 'Clear Income',
                subtitle: 'Delete all income transactions',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Income',
                  message:
                      'This action will permanently erase this data from your device. This cannot be undone.',
                  onClear: () =>
                      ref.read(dataManagementProvider.notifier).clearIncome(),
                  successMessage: 'Income data cleared successfully',
                ),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.handshake,
                color: cs.primary,
                title: 'Clear Lending Data',
                subtitle: 'Remove lending and borrowing records',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Lending Data',
                  message:
                      'This action will permanently erase this data from your device. This cannot be undone.',
                  onClear: () =>
                      ref.read(dataManagementProvider.notifier).clearLending(),
                  successMessage: 'Lending data cleared successfully',
                ),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.credit_card,
                color: cs.primary,
                title: 'Clear Credit / EMI Data',
                subtitle: 'Remove credit cards and EMI plans',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Credit / EMI Data',
                  message:
                      'This action will permanently erase this data from your device. This cannot be undone.',
                  onClear: () => ref
                      .read(dataManagementProvider.notifier)
                      .clearCreditData(),
                  successMessage: 'Credit data cleared successfully',
                ),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.account_balance,
                color: cs.primary,
                title: 'Clear Loans',
                subtitle: 'Remove all loan records and history',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Loans',
                  message:
                      'This action will permanently erase this data from your device. This cannot be undone.',
                  onClear: () =>
                      ref.read(dataManagementProvider.notifier).clearLoans(),
                  successMessage: 'Loan data cleared successfully',
                ),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.account_balance_wallet,
                color: cs.primary,
                title: 'Clear Salary Data',
                subtitle: 'Remove companies, salary months, payments',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Salary Data',
                  message: 'This will remove all salary tracking data.',
                  onClear: () =>
                      ref.read(dataManagementProvider.notifier).clearSalaryData(),
                  successMessage: 'Salary data cleared',
                ),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.flag_rounded,
                color: cs.primary,
                title: 'Clear Goals',
                subtitle: 'Remove all savings goals and logs',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Goals',
                  message: 'This will remove all goals and progress logs.',
                  onClear: () =>
                      ref.read(dataManagementProvider.notifier).clearGoals(),
                  successMessage: 'Goals cleared',
                ),
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.account_balance_rounded,
                color: cs.primary,
                title: 'Clear Accounts',
                subtitle: 'Remove all bank accounts',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear Accounts',
                  message: 'This will remove all bank accounts and their balances.',
                  onClear: () =>
                      ref.read(dataManagementProvider.notifier).clearAccounts(),
                  successMessage: 'Accounts cleared',
                ),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              SettingsTile(
                icon: Icons.delete_forever,
                color: cs.error,
                title: 'Clear ALL App Data',
                subtitle: 'Erase all local data (transactions, accounts, salary, loans, goals, settings)',
                onTap: () => _confirmClear(
                  context,
                  title: 'Clear ALL App Data',
                  message:
                      'This will permanently erase ALL your local data. THIS CANNOT BE UNDONE.',
                  onClear: () async {
                    await ref.read(dataManagementProvider.notifier).clearAllData();
                    await SettingsService.instance.setOnboardingComplete(false);
                  },
                  successMessage: 'All app data cleared. Restart the app.',
                ),
              ),
              const SizedBox(height: 12),
              if (DriveService.instance.isInitialized)
                SettingsTile(
                  icon: Icons.cloud_off_rounded,
                  color: cs.error,
                  title: 'Delete Cloud Backup',
                  subtitle: 'Remove backup data from Google Drive',
                  onTap: () => _confirmClear(
                    context,
                    title: 'Delete Cloud Backup',
                    message:
                        'This will permanently delete your backup from Google Drive. You cannot undo this.',
                    onClear: () async {
                      try {
                        final files = await DriveService.instance.listBackups();
                        for (final f in files) {
                          if (f.id != null) {
                            await DriveService.instance.api.files.delete(f.id!);
                          }
                        }
                      } catch (e) {
                        debugPrint('Drive cleanup error: $e');
                      }
                    },
                    successMessage: 'Cloud backup deleted',
                  ),
                ),
              const SizedBox(height: 32),

              if (AppEnv.enableDebugTools) ...[
                const Divider(),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    'DEVELOPER TOOLS (DEBUG)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: cs.tertiary,
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.developer_mode,
                  color: cs.tertiary,
                  title: 'Open Debug Hub',
                  subtitle: 'Seed data, stress tests, and diagnostics',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DebugHubScreen(),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
