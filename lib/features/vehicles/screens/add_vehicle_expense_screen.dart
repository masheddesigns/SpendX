import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vehicle_providers.dart';
import '../../../data/providers.dart';
import '../../../models/transaction.dart';
import '../../../models/category.dart';
import '../../../utils/text_formatter.dart';

class AddVehicleExpenseScreen extends ConsumerStatefulWidget {
  final String vehicleId;
  final bool isEmbedded;

  const AddVehicleExpenseScreen({
    super.key,
    required this.vehicleId,
    this.isEmbedded = false,
  });

  @override
  ConsumerState<AddVehicleExpenseScreen> createState() =>
      _AddVehicleExpenseScreenState();
}

class _AddVehicleExpenseScreenState
    extends ConsumerState<AddVehicleExpenseScreen> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  String? _selectedCategoryId;

  List<Category> _availableCategories = [];

  @override
  void initState() {
    super.initState();
    _amountController.addListener(() => setState(() {}));
    _loadInitialData();
  }

  bool get _isValid {
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    return amount > 0;
  }

  Future<void> _loadInitialData() async {
    final catMaps = [
      {'id': 'cat_service', 'name': 'Service', 'icon': '🔧'},
      {'id': 'cat_repair', 'name': 'Repair', 'icon': '⚙️'},
      {'id': 'cat_insurance', 'name': 'Insurance', 'icon': '🛡️'},
      {'id': 'cat_pollution', 'name': 'Pollution', 'icon': '💨'},
      {'id': 'cat_accessories', 'name': 'Accessories', 'icon': '🛒'},
      {'id': 'cat_parking', 'name': 'Parking', 'icon': '🅿️'},
      {'id': 'cat_fine', 'name': 'Fine', 'icon': '🎟️'},
      {'id': 'cat_other', 'name': 'Other', 'icon': '📦'},
    ];

    if (!mounted) return;

    final List<Category> categories = catMaps
        .map(
          (m) => Category(
            id: m['id'] as String,
            userId: 'default',
            name: m['name'] as String,
            icon: m['icon'] as String,
            color: '#3B82F6',
            type: 'expense',
          ),
        )
        .toList();

    setState(() {
      _availableCategories = categories;
      _selectedCategoryId = categories.first.id;
    });
  }

  Future<void> _saveTransaction() async {
    if (_amountController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter an amount')));
      return;
    }

    final double amount = double.tryParse(_amountController.text) ?? 0.0;

    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Amount must be greater than zero')),
      );
      return;
    }

    final newTransaction = Transaction(
      id: 'txn_${DateTime.now().millisecondsSinceEpoch}',
      userId: 'offline_user',
      type: 'expense',
      categoryId: _selectedCategoryId,
      amount: amount,
      date: _selectedDate,
      notes: TextFormatter.normalizeName(_notesController.text),
      tags: [],
      source: 'manual',
      vehicleId: widget.vehicleId,
      isVehicleExpense: true,
      fuelLogId: null,
      location: '',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    try {
      await ref.read(transactionsProvider.notifier).add(newTransaction);
      ref.invalidate(vehicleDetailProvider);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('Failed to save transaction: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.isEmbedded
          ? null
          : AppBar(title: const Text('Add Vehicle Expense')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  'Amount',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixIcon: Icon(Icons.attach_money),
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 24),

              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  'Category',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: _availableCategories.map((cat) {
                  final isSelected = _selectedCategoryId == cat.id;
                  return ChoiceChip(
                    label: Text('${cat.icon} ${cat.name}'),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedCategoryId = cat.id);
                      }
                    },
                  );
                }).toList(),
              ),

              const SizedBox(height: 24),

              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date'),
                subtitle: Text(
                  '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}',
                ),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    setState(() => _selectedDate = picked);
                  }
                },
              ),

              const SizedBox(height: 24),

              TextField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes (Optional)',
                  hintText: 'e.g. Changed oil and filter',
                  prefixIcon: Icon(Icons.notes_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton(
            onPressed: _isValid ? _saveTransaction : null,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
            ),
            child: const Text('Save Expense'),
          ),
        ),
      ),
    );
  }
}
