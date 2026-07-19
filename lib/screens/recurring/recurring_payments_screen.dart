import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/category.dart';
import '../../models/recurring_template.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_amount_field.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../shared/widgets/primary_button.dart';
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

          final cs = Theme.of(dialogContext).colorScheme;

          return AlertDialog(
            backgroundColor: cs.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              existing == null ? 'New Recurring Payment' : 'Edit Template',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppTextField(
                    controller: nameController,
                    hintText: 'e.g. Netflix, Rent',
                    label: 'Name',
                  ),
                  const SizedBox(height: AppSpacing.m),
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      children: [
                        Expanded(
                          child: _TypeSegment(
                            label: 'Expense',
                            selected: type == 'expense',
                            color: cs.error,
                            onTap: () => setDialogState(() {
                              type = 'expense';
                              categoryId = null;
                            }),
                          ),
                        ),
                        Expanded(
                          child: _TypeSegment(
                            label: 'Income',
                            selected: type == 'income',
                            color: cs.primary,
                            onTap: () => setDialogState(() {
                              type = 'income';
                              categoryId = null;
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.m),
                  AppAmountField(controller: amountController),
                  const SizedBox(height: AppSpacing.m),
                  _DropdownField<String>(
                    label: 'Frequency',
                    value: frequency,
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
                  if (categories.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.m),
                    _DropdownField<String?>(
                      label: 'Category (optional)',
                      value: categories.any((item) => item.id == categoryId)
                          ? categoryId
                          : null,
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
                  ],
                  const SizedBox(height: AppSpacing.m),
                  // Start date picker
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
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
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Start Date',
                                  style: Theme.of(dialogContext)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(color: cs.onSurfaceVariant)),
                              const SizedBox(height: 4),
                              Text(AppFormat.date(startDate)),
                            ],
                          ),
                          Icon(Icons.calendar_today, size: 18, color: cs.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              PrimaryButton(
                label: 'Save',
                height: 44,
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
                        '\nStarts ${AppFormat.date(template.startDate)}',
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

class _TypeSegment extends StatelessWidget {
  const _TypeSegment({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: selected ? cs.onError : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButtonFormField<T>(
          initialValue: value,
          decoration: InputDecoration(
            labelText: label,
            border: InputBorder.none,
          ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
