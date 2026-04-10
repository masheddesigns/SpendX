import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/category.dart';
import '../../models/recurring_template.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/undo_snackbar_listener.dart';
import '../../utils/app_format.dart';
import '../../widgets/common/spendx_fab.dart';

class RecurringPaymentsScreen extends ConsumerStatefulWidget {
  const RecurringPaymentsScreen({super.key});

  @override
  ConsumerState<RecurringPaymentsScreen> createState() =>
      _RecurringPaymentsScreenState();
}

class _RecurringPaymentsScreenState
    extends ConsumerState<RecurringPaymentsScreen> {
  void _showAddDialog(
    Map<String, Category> categoriesMap, [
    RecurringTemplate? existing,
  ]) {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final amountController = TextEditingController(
      text: existing?.amount.toStringAsFixed(0) ?? '',
    );
    String type = existing?.type ?? 'expense';
    String? categoryId = existing?.categoryId;
    String frequency = existing?.frequency ?? 'monthly';
    DateTime startDate = existing?.startDate ?? DateTime.now();

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final categories =
              categoriesMap.values
                  .where((category) => category.type == type)
                  .toList()
                ..sort((a, b) => a.name.compareTo(b.name));

          return AlertDialog(
            title: Text(
              existing == null ? 'New Recurring Payment' : 'Edit Template',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name (e.g. Netflix, Rent)',
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'expense', label: Text('Expense')),
                      ButtonSegment(value: 'income', label: Text('Income')),
                    ],
                    selected: {type},
                    onSelectionChanged: (value) {
                      setDialogState(() {
                        type = value.first;
                        categoryId = null;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Amount'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: frequency,
                    decoration: const InputDecoration(labelText: 'Frequency'),
                    items: const [
                      DropdownMenuItem(value: 'daily', child: Text('Daily')),
                      DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                      DropdownMenuItem(
                        value: 'monthly',
                        child: Text('Monthly'),
                      ),
                      DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setDialogState(() => frequency = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  if (categories.isNotEmpty)
                    DropdownButtonFormField<String?>(
                      initialValue: categories.any((item) => item.id == categoryId)
                          ? categoryId
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Category (optional)',
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None'),
                        ),
                        ...categories.map(
                          (category) => DropdownMenuItem<String?>(
                            value: category.id,
                            child: Text(category.name),
                          ),
                        ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => categoryId = value),
                    ),
                  const SizedBox(height: 16),
                  // Start date picker
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: dialogContext,
                        initialDate: startDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 730)),
                        helpText: 'First payment date',
                      );
                      if (picked != null) {
                        setDialogState(() => startDate = picked);
                      }
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Start Date',
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${startDate.day}/${startDate.month}/${startDate.year}',
                          ),
                          const Icon(Icons.calendar_today, size: 18),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  final amount = double.tryParse(amountController.text);
                  if (name.isEmpty || amount == null || amount <= 0) {
                    return;
                  }

                  final template = RecurringTemplate(
                    id: existing?.id,
                    userId: existing?.userId ?? 'offline_user',
                    name: name,
                    amount: amount,
                    type: type,
                    categoryId: categoryId,
                    frequency: frequency,
                    startDate: startDate,
                    endDate: existing?.endDate,
                    lastGeneratedDate: existing?.lastGeneratedDate,
                    isActive: existing?.isActive ?? true,
                    notes: existing?.notes,
                    createdAt: existing?.createdAt,
                    updatedAt: existing?.updatedAt,
                  );

                  if (existing == null) {
                    await ref.read(recurringProvider.notifier).add(template);
                  } else {
                    await ref
                        .read(recurringProvider.notifier)
                        .replace(template);
                  }

                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteTemplate(RecurringTemplate template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Recurring Payment?'),
        content: Text("Delete '${template.name}'?"),
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

    if (confirmed == true) {
      await ref.read(recurringProvider.notifier).remove(template);
    }
  }

  String _frequencyLabel(String frequency) {
    switch (frequency) {
      case 'daily':
        return 'Daily';
      case 'weekly':
        return 'Weekly';
      case 'yearly':
        return 'Yearly';
      default:
        return 'Monthly';
    }
  }

  @override
  Widget build(BuildContext context) {
    final templatesAsync = ref.watch(recurringProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is RecurringTemplate,
    );

    final isLoading =
        (templatesAsync.isLoading && templatesAsync.valueOrNull == null) ||
        (categoriesAsync.isLoading && categoriesAsync.valueOrNull == null);

    final templates = [
      ...(templatesAsync.valueOrNull ?? const <RecurringTemplate>[]),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final categoriesMap = {
      for (final category in categoriesAsync.valueOrNull ?? const <Category>[])
        category.id: category,
    };

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Recurring Payments'),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: SpendXFAB(
        icon: Icons.add_rounded,
        label: 'Add Recurring',
        onPressed: () => _showAddDialog(categoriesMap),
      ),
      body: SafeArea(
        child: isLoading
            ? const Center(child: CircularProgressIndicator())
            : templates.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.repeat,
                      size: 72,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No recurring payments',
                      style: AppTextStyles.titleMedium.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap + to add rent, subscriptions, salary etc.',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: templates.length,
                itemBuilder: (context, index) {
                  final template = templates[index];
                  final category = template.categoryId != null
                      ? categoriesMap[template.categoryId]
                      : null;
                  final isExpense = template.type == 'expense';
                  final color = isExpense
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary;

                  return AppCard(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: color.withValues(alpha: 0.15),
                        child: Icon(Icons.repeat, color: color, size: 20),
                      ),
                      title: Text(
                        template.name,
                        style: AppTextStyles.titleSmall,
                      ),
                      subtitle: Text(
                        '${_frequencyLabel(template.frequency)}${category != null ? ' • ${category.name}' : ''}'
                        '\nStarts ${template.startDate.day}/${template.startDate.month}/${template.startDate.year}',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${isExpense ? '-' : '+'}${AppFormat.currency(template.amount)}',
                            style: AppTextStyles.titleMedium.copyWith(
                              color: color,
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
                            onPressed: () =>
                                _showAddDialog(categoriesMap, template),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Theme.of(
                                context,
                              ).colorScheme.error.withValues(alpha: 0.7),
                            ),
                            onPressed: () => _deleteTemplate(template),
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
