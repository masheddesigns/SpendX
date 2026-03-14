import 'package:flutter/material.dart';
import '../../models/recurring_template.dart';
import '../../models/category.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';

class RecurringPaymentsScreen extends StatefulWidget {
  const RecurringPaymentsScreen({super.key});

  @override
  State<RecurringPaymentsScreen> createState() => _RecurringPaymentsScreenState();
}

class _RecurringPaymentsScreenState extends State<RecurringPaymentsScreen> {
  List<RecurringTemplate> _templates = [];
  Map<String, Category> _categoriesMap = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final templates = await DatabaseHelper.instance.getAllRecurringTemplates();
      final db = await DatabaseHelper.instance.database;
      final catMaps = await db.query(DatabaseHelper.tableCategories);
      final catMap = {for (var m in catMaps) m['id'] as String: Category.fromMap(m)};
      if (mounted) {
        setState(() {
          _templates = templates;
          _categoriesMap = catMap;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showAddDialog([RecurringTemplate? existing]) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final amountCtrl = TextEditingController(text: existing?.amount.toStringAsFixed(0) ?? '');
    String type = existing?.type ?? 'expense';
    String? categoryId = existing?.categoryId;
    String frequency = existing?.frequency ?? 'monthly';

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDs) {
          final cats = _categoriesMap.values.where((c) => c.type == type).toList();
          return AlertDialog(
            title: Text(existing == null ? 'New Recurring Payment' : 'Edit Template'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name (e.g. Netflix, Rent)'),
                    textCapitalization: TextCapitalization.words),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'expense', label: Text('Expense')),
                    ButtonSegment(value: 'income', label: Text('Income')),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => setDs(() { type = s.first; categoryId = null; }),
                ),
                const SizedBox(height: 12),
                TextField(controller: amountCtrl, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Amount')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: frequency,
                  decoration: const InputDecoration(labelText: 'Frequency'),
                  items: const [
                    DropdownMenuItem(value: 'daily', child: Text('Daily')),
                    DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                    DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                    DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                  ],
                  onChanged: (v) => setDs(() => frequency = v!),
                ),
                const SizedBox(height: 12),
                if (cats.isNotEmpty)
                  DropdownButtonFormField<String?>(
                    value: cats.any((c) => c.id == categoryId) ? categoryId : null,
                    decoration: const InputDecoration(labelText: 'Category (optional)'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None')),
                      ...cats.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
                    ],
                    onChanged: (v) => setDs(() => categoryId = v),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  final amount = double.tryParse(amountCtrl.text);
                  if (name.isEmpty || amount == null || amount <= 0) return;

                  if (existing != null) {
                    await DatabaseHelper.instance.updateRecurringTemplate(RecurringTemplate(
                      id: existing.id,
                      name: name,
                      amount: amount,
                      type: type,
                      categoryId: categoryId,
                      frequency: frequency,
                      startDate: existing.startDate,
                      lastGeneratedDate: existing.lastGeneratedDate,
                    ));
                  } else {
                    await DatabaseHelper.instance.insertRecurringTemplate(RecurringTemplate(
                      name: name,
                      amount: amount,
                      type: type,
                      categoryId: categoryId,
                      frequency: frequency,
                      startDate: DateTime.now(),
                    ));
                  }
                  if (mounted) { Navigator.pop(ctx); _loadData(); }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _frequencyLabel(String f) {
    switch (f) {
      case 'daily': return 'Daily';
      case 'weekly': return 'Weekly';
      case 'yearly': return 'Yearly';
      default: return 'Monthly';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recurring Payments'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _templates.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.repeat, size: 72, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.2)),
                  const SizedBox(height: 16),
                  Text('No recurring payments', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 18)),
                  const SizedBox(height: 8),
                  Text('Tap + to add rent, subscriptions, salary etc.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6))),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _templates.length,
                  itemBuilder: (_, i) {
                    final t = _templates[i];
                    final cat = t.categoryId != null ? _categoriesMap[t.categoryId] : null;
                    final isExpense = t.type == 'expense';
                    final color = isExpense ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: CircleAvatar(
                          backgroundColor: color.withValues(alpha: 0.15),
                          child: Icon(Icons.repeat, color: color, size: 20),
                        ),
                        title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${_frequencyLabel(t.frequency)}${cat != null ? ' • ${cat.name}' : ''}',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                        ),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(
                            '${isExpense ? '-' : '+'}${AppFormat.currency(t.amount)}',
                            style: TextStyle(fontWeight: FontWeight.w600, color: color, fontSize: 15),
                          ),
                          IconButton(
                            icon: Icon(Icons.edit_outlined, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            onPressed: () => _showAddDialog(t),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_outline, size: 18, color: Theme.of(context).colorScheme.error.withValues(alpha: 0.7)),
                            onPressed: () async {
                              await DatabaseHelper.instance.deleteRecurringTemplate(t.id);
                              _loadData();
                            },
                          ),
                        ]),
                      ),
                    );
                  },
                ),
    );
  }
}
