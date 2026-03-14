import 'package:flutter/material.dart';
import '../../models/budget.dart';
import '../../models/category.dart';
import '../../services/database_helper.dart';
import '../../widgets/spendx_app_bar.dart';

import '../../widgets/custom_snackbar.dart';
import '../../widgets/custom_dialog.dart';
import '../../utils/app_format.dart';

class BudgetManagementScreen extends StatefulWidget {
  const BudgetManagementScreen({super.key});

  @override
  State<BudgetManagementScreen> createState() => _BudgetManagementScreenState();
}

class _BudgetManagementScreenState extends State<BudgetManagementScreen> {
  List<_BudgetWithMeta> _budgets = [];
  List<Category> _expenseCategories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final db = await DatabaseHelper.instance.database;
      final catMaps = await db.query(DatabaseHelper.tableCategories,
          where: 'type = ?', whereArgs: ['expense']);
      final categories = catMaps.map((m) => Category.fromMap(m)).toList();
      final budgets = await DatabaseHelper.instance.getAllBudgets();

      final enriched = await Future.wait(budgets.map((b) async {
        final spent = await DatabaseHelper.instance.getSpentThisMonth(b.categoryId);
        final cat = categories.firstWhere(
          (c) => c.id == b.categoryId,
          orElse: () => Category(userId: 'default', name: 'Unknown', icon: 'category', color: '#888888', type: 'expense'),
        );
        return _BudgetWithMeta(budget: b, category: cat, spent: spent);
      }));

      // Double check deduplication in UI memory
      final uniqueEnriched = <String, _BudgetWithMeta>{};
      for (var item in enriched) {
        uniqueEnriched[item.budget.categoryId] = item;
      }

      if (mounted) {
        setState(() {
          _expenseCategories = categories;
          _budgets = uniqueEnriched.values.toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showAddBudgetDialog([_BudgetWithMeta? existing]) {
    final amountController = TextEditingController(
        text: existing?.budget.limit.toStringAsFixed(0) ?? '');
    String? selectedCategoryId = existing?.budget.categoryId;

    // Filter out already-budgeted categories (unless editing)
    final available = _expenseCategories.where((c) {
      if (existing != null && c.id == existing.budget.categoryId) return true;
      return !_budgets.any((b) => b.budget.categoryId == c.id);
    }).toList();

    if (available.isEmpty && existing == null) {
      CustomSnackBar.show(context, message: 'All expense categories already have budgets!', isWarning: true);      return;
    }

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New Budget' : 'Edit Budget'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (existing == null)
                DropdownButtonFormField<String>(
                  value: selectedCategoryId,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: available
                      .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
                      .toList(),
                  onChanged: (val) => setDialogState(() => selectedCategoryId = val),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Monthly Limit'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final limit = double.tryParse(amountController.text.trim());
                if (limit == null || limit <= 0) return;
                if (selectedCategoryId == null && existing == null) return;

                if (existing != null) {
                  final updated = Budget(
                    id: existing.budget.id,
                    categoryId: existing.budget.categoryId,
                    limit: limit,
                  );
                  await DatabaseHelper.instance.updateBudget(updated);
                } else {
                  final newBudget = Budget(
                    categoryId: selectedCategoryId!,
                    limit: limit,
                  );
                  await DatabaseHelper.instance.insertBudget(newBudget);
                }
                if (mounted) {
                  Navigator.pop(context);
                  _loadData();
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteBudget(String id) async {
    final confirm = await CustomDialog.show(
      context,
      type: DialogType.warning,
      title: 'Delete Budget?',
      message: 'This will remove the spending limit for this category.',
      primaryButtonText: 'Delete',
      secondaryButtonText: 'Cancel',
    );
    if (confirm == true) {
      await DatabaseHelper.instance.deleteBudget(id);
      _loadData();
    }
  }

  Color _hexToColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SpendXAppBar(
        title: 'Budgets',
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddBudgetDialog(),
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _budgets.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.account_balance_wallet, size: 72, color: Colors.grey),

                      const SizedBox(height: 16),
                      Text('No budgets set yet', style: TextStyle(color: Colors.grey[400], fontSize: 18)),
                      const SizedBox(height: 8),
                      Text('Tap + to set a monthly limit per category', style: TextStyle(color: Colors.grey[600])),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _budgets.length,
                  itemBuilder: (context, index) {
                    final item = _budgets[index];
                    final progress = (item.spent / item.budget.limit).clamp(0.0, 1.0);
                    final catColor = _hexToColor(item.category.color);
                    final progressColor = progress < 0.7
                        ? Theme.of(context).colorScheme.primary
                        : progress < 0.9
                            ? Colors.orange
                            : Theme.of(context).colorScheme.error;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: catColor.withValues(alpha: 0.2),
                                  child: Icon(Icons.category, color: catColor, size: 16),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(item.category.name,
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18, color: Colors.white54),
                                  onPressed: () => _showAddBudgetDialog(item),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white38),
                                  onPressed: () => _deleteBudget(item.budget.id),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 8,
                                backgroundColor: Colors.white12,
                                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Spent: ${AppFormat.currency(item.spent)}',
                                  style: TextStyle(color: progressColor, fontSize: 13),
                                ),
                                Text(
                                  'Limit: ${AppFormat.currency(item.budget.limit)}',
                                  style: TextStyle(color: Colors.grey[500], fontSize: 13),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class _BudgetWithMeta {
  final Budget budget;
  final Category category;
  final double spent;
  const _BudgetWithMeta({required this.budget, required this.category, required this.spent});
}
