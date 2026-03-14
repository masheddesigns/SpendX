import 'package:flutter/material.dart';
import '../../services/database_helper.dart';
import '../../widgets/custom_dialog.dart';
import '../../widgets/custom_snackbar.dart';
import '../../widgets/spendx_app_bar.dart';


class DataManagementScreen extends StatefulWidget {
  const DataManagementScreen({super.key});

  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  bool _isCleaning = false;

  Future<void> _clearData(String type) async {
    final confirm = await CustomDialog.show(
      context,
      type: DialogType.warning,
      title: 'Warning',
      message: 'This action will permanently erase selected data from your device.\nThis cannot be undone.',
      primaryButtonText: 'Erase Data',
      secondaryButtonText: 'Cancel',
    );

    if (confirm == true) {
      setState(() => _isCleaning = true);
      try {
        int count = 0;
        String message = "";
        
        switch (type) {
          case 'imported':
            count = await DatabaseHelper.instance.deleteImportedTransactions();
            message = 'Successfully cleared $count imported transactions.';
            break;
          case 'expense':
            count = await DatabaseHelper.instance.deleteExpenseData();
            message = 'Successfully cleared all expense transactions.';
            break;
          case 'income':
            count = await DatabaseHelper.instance.deleteIncomeData();
            message = 'Successfully cleared all income transactions.';
            break;
          case 'lending':
            count = await DatabaseHelper.instance.deleteLendingData();
            message = 'Successfully cleared all lending data.';
            break;
          case 'vehicle':
            count = await DatabaseHelper.instance.deleteVehicleData();
            message = 'Successfully cleared all vehicle data.';
            break;
          case 'credit':
            count = await DatabaseHelper.instance.deleteCreditData();
            message = 'Successfully cleared all credit card data.';
            break;
          case 'all':
            await DatabaseHelper.instance.clearAllUserData();
            message = 'Successfully cleared all app data.';
            break;
        }

        if (mounted) {
          CustomSnackBar.show(context, message: message);
        }
      } catch (e) {
        if (mounted) {
          CustomSnackBar.show(context, message: 'Error: $e', isError: true);
        }
      } finally {
        if (mounted) setState(() => _isCleaning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SpendXAppBar(title: 'Data Management'),

      body: _isCleaning
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _buildSection(
                  title: 'Data Clearing Options',
                  description: 'Select specific data to erase from your device.',
                  icon: Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                  children: [
                    _buildActionButton('Clear Imported Data', () => _clearData('imported')),
                    _buildActionButton('Clear Expense Data', () => _clearData('expense')),
                    _buildActionButton('Clear Income Data', () => _clearData('income')),
                    _buildActionButton('Clear Lending Data', () => _clearData('lending')),
                    _buildActionButton('Clear Vehicle Data', () => _clearData('vehicle')),
                    _buildActionButton('Clear Credit Data', () => _clearData('credit')),
                    const Divider(height: 32),
                    _buildActionButton('Clear All App Data', () => _clearData('all'), isPrimary: true),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildActionButton(String label, VoidCallback onTap, {bool isPrimary = false}) {
    final color = isPrimary ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: color.withValues(alpha: 0.1),
            foregroundColor: color,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 16),
              Text(
                title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }
}
