import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/budget.dart';
import '../../models/category.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../../shared/widgets/undo_snackbar_listener.dart';

class BudgetManagementScreen extends ConsumerStatefulWidget {
  const BudgetManagementScreen({super.key});

  @override
  ConsumerState<BudgetManagementScreen> createState() =>
      _BudgetManagementScreenState();
}

class _BudgetManagementScreenState
    extends ConsumerState<BudgetManagementScreen> {
  void _showAddBudgetDialog(
    List<Category> expenseCategories,
    List<_BudgetWithMeta> budgets, [
    _BudgetWithMeta? existing,
  ]) {
    final amountController = TextEditingController(
      text: existing?.budget.limit.toStringAsFixed(0) ?? '',
    );
    String? selectedCategoryId = existing?.budget.categoryId;

    final available = expenseCategories.where((category) {
      if (existing != null && category.id == existing.budget.categoryId) {
        return true;
      }

      return !budgets.any((item) => item.budget.categoryId == category.id);
    }).toList();

    if (available.isEmpty && existing == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All expense categories already have budgets!'),
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          bool isValid() {
            final limit = double.tryParse(amountController.text.trim()) ?? 0.0;
            if (limit <= 0) {
              return false;
            }
            if (existing == null && selectedCategoryId == null) {
              return false;
            }
            return true;
          }

          return AlertDialog(
            title: Text(existing == null ? 'New Budget' : 'Edit Budget'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (existing == null)
                  DropdownButtonFormField<String>(
                    initialValue: selectedCategoryId,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: available
                        .map(
                          (category) => DropdownMenuItem<String>(
                            value: category.id,
                            child: Text(category.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setDialogState(() => selectedCategoryId = value);
                    },
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Monthly Limit'),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: isValid()
                    ? () async {
                        final limit = double.tryParse(
                          amountController.text.trim(),
                        );
                        if (limit == null || limit <= 0) {
                          return;
                        }

                        if (existing != null) {
                          await ref
                              .read(budgetsProvider.notifier)
                              .updateLimit(existing.budget.id, limit);
                        } else if (selectedCategoryId != null) {
                          await ref
                              .read(budgetsProvider.notifier)
                              .add(
                                Budget(
                                  categoryId: selectedCategoryId!,
                                  limit: limit,
                                ),
                              );
                        }

                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      }
                    : null,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteBudget(_BudgetWithMeta item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Budget?'),
        content: const Text(
          'This will remove the spending limit for this category.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ref.read(budgetsProvider.notifier).remove(item.budget);
    }
  }

  Color _hexToColor(String hex) {
    try {
      var normalized = hex.replaceAll('#', '');
      if (normalized.length == 6) {
        normalized = 'FF$normalized';
      }
      return Color(int.parse(normalized, radix: 16));
    } catch (_) {
      return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final budgetsAsync = ref.watch(budgetsProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is Budget,
    );

    final expenseCategories =
        (categoriesAsync.valueOrNull ?? const <Category>[])
            .where((category) => category.type == 'expense')
            .toList();
    final budgets = ref
        .watch(budgetSummaryProvider)
        .map(
          (item) => _BudgetWithMeta(
            budget: item.budget,
            category: item.category,
            spent: item.spent,
          ),
        )
        .toList();

    final isLoading =
        (budgetsAsync.isLoading && budgetsAsync.valueOrNull == null) ||
        (categoriesAsync.isLoading && categoriesAsync.valueOrNull == null);

    return Scaffold(
      appBar: AppBar(title: const Text('Budgets')),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Budget'),
        onPressed: expenseCategories.isEmpty
            ? null
            : () => _showAddBudgetDialog(expenseCategories, budgets),
      ),
      body: SafeArea(
        child: isLoading
            ? const SkeletonLoader.transactions()
            : budgets.isEmpty
            ? const EmptyStateWidget(
                icon: Icons.account_balance_wallet_outlined,
                title: 'No budgets set yet',
                description: 'Tap + to set a monthly limit per category.',
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: budgets.length,
                itemBuilder: (context, index) {
                  final item = budgets[index];
                  final progress = (item.spent / item.budget.limit).clamp(
                    0.0,
                    1.0,
                  );
                  final categoryColor = _hexToColor(item.category.color);
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
                                backgroundColor: categoryColor.withValues(
                                  alpha: 0.2,
                                ),
                                child: Icon(
                                  Icons.category,
                                  color: categoryColor,
                                  size: 16,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  item.category.name,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.edit_outlined,
                                  size: 18,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                                onPressed: () => _showAddBudgetDialog(
                                  expenseCategories,
                                  budgets,
                                  item,
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.error.withValues(alpha: 0.7),
                                ),
                                onPressed: () => _deleteBudget(item),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 8,
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                progressColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Spent: ${AppFormat.currency(item.spent)}',
                                style: AppTextStyles.labelMedium.copyWith(
                                  color: progressColor,
                                ),
                              ),
                              Text(
                                'Limit: ${AppFormat.currency(item.budget.limit)}',
                                style: AppTextStyles.labelMedium.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _BudgetWithMeta {
  const _BudgetWithMeta({
    required this.budget,
    required this.category,
    required this.spent,
  });

  final Budget budget;
  final Category category;
  final double spent;
}
