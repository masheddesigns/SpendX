import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../../widgets/spendx_app_bar.dart';
import '../../widgets/settings_tile.dart';
import '../../widgets/custom_snackbar.dart';
import '../../services/export_service.dart';
import '../../services/import_service.dart';
import '../smart_import_screen.dart';
import '../import_screen.dart';

class DatabaseToolsScreen extends ConsumerStatefulWidget {
  const DatabaseToolsScreen({super.key});

  @override
  ConsumerState<DatabaseToolsScreen> createState() =>
      _DatabaseToolsScreenState();
}

class _DatabaseToolsScreenState extends ConsumerState<DatabaseToolsScreen> {
  bool _isBusy = false;

  Future<void> _runAction(Future<void> Function() action, String label) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      await action();
      if (mounted) CustomSnackBar.show(context, message: '$label complete');
    } catch (e) {
      if (mounted) {
        CustomSnackBar.show(context, message: '$label failed: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _runImportBackup() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final success = await ImportService.instance.importFromFile(file);
        if (mounted) {
          if (success) {
            CustomSnackBar.show(context, message: 'Import complete');
          } else {
            CustomSnackBar.show(
              context,
              message: 'Import failed: invalid file',
              isError: true,
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        CustomSnackBar.show(context, message: 'Import error: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Database Tools'),
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
                      'Database Tools',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Import transactions from any format or export your data.',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              // ──────────── SMART IMPORT ────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  'IMPORT',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: cs.primary,
                  ),
                ),
              ),
              SettingsTile(
                icon: Icons.auto_awesome_rounded,
                color: Colors.teal,
                title: 'Smart Import',
                subtitle: 'CSV, JSON, Markdown, HTML, ZIP (Notion)',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SmartImportScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.upload_file,
                color: Colors.blue,
                title: 'Manual CSV Import',
                subtitle: 'Map columns manually from any CSV',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ImportScreen(initialMethod: 'csv_generic'),
                    ),
                  );
                },
              ),

              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),

              // ──────────── BACKUP IMPORT / EXPORT ────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  'BACKUP',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: cs.primary,
                  ),
                ),
              ),
              SettingsTile(
                icon: Icons.backup,
                color: cs.primary,
                title: 'Export Full Backup',
                subtitle: 'Save a complete SpendX backup (JSON)',
                onTap: () {
                  if (!_isBusy) {
                    _runAction(
                      ExportService.instance.exportFullBackup,
                      'Export Backup',
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.restore,
                color: cs.primary,
                title: 'Import Full Backup',
                subtitle: 'Restore from a spendx_backup.json file',
                onTap: () {
                  if (!_isBusy) _runImportBackup();
                },
              ),

              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),

              // ──────────── DATA EXPORT ────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  'EXPORT DATA',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: cs.primary,
                  ),
                ),
              ),
              SettingsTile(
                icon: Icons.table_chart_outlined,
                color: const Color(0xFF0EA5E9),
                title: 'Export Transactions CSV',
                subtitle: 'Share transactions as a spreadsheet',
                onTap: () {
                  if (!_isBusy) {
                    _runAction(
                      ExportService.instance.exportTransactionsToCsv,
                      'Export CSV',
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.data_object,
                color: Colors.amber.shade700,
                title: 'Export Transactions JSON',
                subtitle: 'Share transactions as a JSON file',
                onTap: () {
                  if (!_isBusy) {
                    _runAction(
                      ExportService.instance.exportTransactionsToJson,
                      'Export JSON',
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.account_balance_wallet_outlined,
                color: const Color(0xFF8B5CF6),
                title: 'Export Salary Report CSV',
                subtitle: 'All salary payments as CSV',
                onTap: () {
                  if (!_isBusy) {
                    _runAction(
                      ExportService.instance.exportSalaryReportToCsv,
                      'Export Salary CSV',
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.picture_as_pdf_outlined,
                color: Colors.red.shade600,
                title: 'Export Salary Report PDF',
                subtitle: 'Salary intelligence report as PDF',
                onTap: () {
                  if (!_isBusy) {
                    _runAction(
                      ExportService.instance.exportSalaryReportToPdf,
                      'Export Salary PDF',
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              SettingsTile(
                icon: Icons.notifications_outlined,
                color: const Color(0xFFF59E0B),
                title: 'Export Reminders CSV',
                subtitle: 'All due reminders as CSV',
                onTap: () {
                  if (!_isBusy) {
                    _runAction(
                      ExportService.instance.exportReminderReportToCsv,
                      'Export Reminders',
                    );
                  }
                },
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
