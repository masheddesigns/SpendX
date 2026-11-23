import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/categories/providers/category_providers.dart';
import '../../features/goals/goal_providers.dart';
import '../../models/goal.dart';
import '../../shared/widgets/primary_button.dart';

class AddGoalScreen extends ConsumerStatefulWidget {
  final Goal? existing;

  const AddGoalScreen({super.key, this.existing});

  @override
  ConsumerState<AddGoalScreen> createState() => _AddGoalScreenState();
}

class _AddGoalScreenState extends ConsumerState<AddGoalScreen> {
  GoalType _type = GoalType.savings;
  final _titleCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  int _durationDays = 30;
  String? _selectedCategoryId;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _type = e.type;
      _titleCtrl.text = e.title;
      _amountCtrl.text = e.targetAmount.toStringAsFixed(0);
      _durationDays = e.endDate.difference(e.startDate).inDays.clamp(1, 365);
      _selectedCategoryId = e.categoryId;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  double? get _parsedAmount {
    final raw = _amountCtrl.text.trim().replaceAll(',', '').replaceAll(' ', '');
    return double.tryParse(raw);
  }

  bool get _isValid {
    if (_titleCtrl.text.trim().isEmpty) return false;
    final amount = _parsedAmount;
    if (amount == null || amount <= 0) return false;
    if (_type == GoalType.spendingLimit && _selectedCategoryId == null) {
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    debugPrint('🎯 _save called, isValid: $_isValid');
    if (!_isValid || !(_formKey.currentState?.validate() ?? false)) return;

    try {
      if (_isEditing) {
        final updated = widget.existing!.copyWith(
          title: _titleCtrl.text.trim(),
          type: _type,
          targetAmount: _parsedAmount!,
          endDate: widget.existing!.startDate.add(
            Duration(days: _durationDays),
          ),
          categoryId: _type == GoalType.spendingLimit
              ? _selectedCategoryId
              : null,
        );
        await ref.read(goalRepoProvider).update(updated);
        debugPrint('🎯 Goal updated: ${updated.title}');
      } else {
        final goal = Goal(
          title: _titleCtrl.text.trim(),
          type: _type,
          targetAmount: _parsedAmount!,
          startDate: DateTime.now(),
          endDate: DateTime.now().add(Duration(days: _durationDays)),
          categoryId: _type == GoalType.spendingLimit
              ? _selectedCategoryId
              : null,
        );
        await ref.read(goalRepoProvider).insert(goal);
        debugPrint('🎯 Goal created: ${goal.title}');
      }
    } catch (e, st) {
      debugPrint('🎯 Goal save FAILED: $e');
      debugPrint('$st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save goal: $e')));
      }
      return;
    }

    ref.invalidate(goalsProvider);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final categories = ref.watch(categoriesProvider).valueOrNull ?? [];
    final expenseCategories = categories
        .where((c) => c.type == 'expense')
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit Goal' : 'Create Goal')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Goal Type ──────────────────────────────────────────
                Text(
                  'What is your goal?',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: GoalType.values.map((t) {
                    final selected = _type == t;
                    final String label;
                    final IconData icon;
                    switch (t) {
                      case GoalType.savings:
                        label = 'Save Money';
                        icon = Icons.savings_rounded;
                      case GoalType.spendingLimit:
                        label = 'Limit Spending';
                        icon = Icons.speed_rounded;
                      case GoalType.debtPayoff:
                        label = 'Pay Off Debt';
                        icon = Icons.credit_score_rounded;
                    }
                    return GestureDetector(
                      onTap: () => setState(() => _type = t),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? cs.primary.withValues(alpha: 0.12)
                              : cs.surfaceContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected ? cs.primary : cs.outlineVariant,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              icon,
                              size: 18,
                              color: selected
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              label,
                              style: TextStyle(
                                color: selected
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 24),

                // ── Title ──────────────────────────────────────────────
                TextFormField(
                  controller: _titleCtrl,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'Enter a goal title'
                      : null,
                  decoration: InputDecoration(
                    labelText: 'Goal title',
                    hintText: _type == GoalType.savings
                        ? 'e.g. Emergency Fund'
                        : _type == GoalType.spendingLimit
                        ? 'e.g. Food Budget'
                        : 'e.g. Clear HDFC Card',
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),

                const SizedBox(height: 16),

                // ── Amount ─────────────────────────────────────────────
                TextFormField(
                  controller: _amountCtrl,
                  validator: (value) {
                    final amount = double.tryParse(
                      (value ?? '')
                          .trim()
                          .replaceAll(',', '')
                          .replaceAll(' ', ''),
                    );
                    if (amount == null || !amount.isFinite || amount <= 0) {
                      return 'Amount must be greater than zero';
                    }
                    return null;
                  },
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,2}'),
                    ),
                  ],
                  decoration: InputDecoration(
                    labelText: _type == GoalType.spendingLimit
                        ? 'Monthly limit'
                        : 'Target amount',
                    prefixText: '\u20b9 ',
                    hintText: '0.00',
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),

                const SizedBox(height: 16),

                // ── Duration ───────────────────────────────────────────
                Text(
                  'Duration',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _DurationChip(
                      days: 30,
                      label: '1 month',
                      selected: _durationDays == 30,
                      onTap: () => setState(() => _durationDays = 30),
                    ),
                    _DurationChip(
                      days: 90,
                      label: '3 months',
                      selected: _durationDays == 90,
                      onTap: () => setState(() => _durationDays = 90),
                    ),
                    _DurationChip(
                      days: 180,
                      label: '6 months',
                      selected: _durationDays == 180,
                      onTap: () => setState(() => _durationDays = 180),
                    ),
                    _DurationChip(
                      days: 365,
                      label: '1 year',
                      selected: _durationDays == 365,
                      onTap: () => setState(() => _durationDays = 365),
                    ),
                  ],
                ),

                // ── Category (spending limit only) ─────────────────────
                if (_type == GoalType.spendingLimit) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedCategoryId,
                    decoration: InputDecoration(
                      labelText: 'Category',
                      filled: true,
                      fillColor: cs.surfaceContainer,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    dropdownColor: cs.surfaceContainerHigh,
                    items: expenseCategories.map((c) {
                      return DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (v) => setState(() => _selectedCategoryId = v),
                  ),
                ],

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    foregroundColor: cs.onSurfaceVariant,
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: PrimaryButton(
                  label: _isEditing ? 'Save Changes' : 'Create Goal',
                  onPressed: _isValid ? _save : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationChip extends StatelessWidget {
  final int days;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DurationChip({
    required this.days,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label duration',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? cs.primary.withValues(alpha: 0.12)
                  : cs.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? cs.primary : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
