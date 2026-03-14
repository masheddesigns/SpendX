import 'dart:io' as dart_io;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../models/transaction.dart';
import '../../models/bank_account.dart';
import '../../models/category.dart';
import '../../models/tag.dart';
import '../../services/transaction_service.dart';
import '../../services/database_helper.dart';
import '../../services/gemini_service.dart';
import '../../widgets/custom_snackbar.dart';
import '../vehicles/add_fuel_screen.dart';
import '../../models/vehicle.dart';

import '../../utils/app_format.dart';
import 'package:intl/intl.dart';

class AddExpenseScreen extends StatefulWidget {
  final String initialType; // 'expense' or 'income'
  final Transaction? existingTransaction;
  final Map<String, String?>? prefillData; // Data from Gemini AI

  const AddExpenseScreen({
    super.key,
    this.initialType = 'expense',
    this.existingTransaction,
    this.prefillData,
  });

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  late String _selectedType;
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  String? _selectedCategoryId;
  bool _isRecurring = false;
  
  List<Category> _availableCategories = [];
  List<Tag> _availableTags = [];
  List<String> _selectedTags = [];
  List<BankAccount> _availableAccounts = [];
  String? _selectedAccountId;
  List<Vehicle> _availableVehicles = [];
  String? _selectedVehicleId;

  @override
  void initState() {
    super.initState();
    if (widget.existingTransaction != null) {
      final txn = widget.existingTransaction!;
      _selectedType = txn.type;
      _amountController.text = txn.amount.toString();
      _notesController.text = txn.notes;
      _locationController.text = txn.location ?? '';
      _selectedDate = txn.date;
      _selectedCategoryId = txn.categoryId;
      _selectedTags = List.from(txn.tags);
      if (txn.source == 'bank_account') _selectedAccountId = txn.relatedEntityId;
      _selectedVehicleId = txn.vehicleId;
    } else {
      _selectedType = widget.initialType;
      
      // Apply AI Prefill Data if available
      if (widget.prefillData != null) {
        if (widget.prefillData!['amount'] != null) {
          // AI might return strings with commas/symbols, try to clean it
          final cleanAmt = widget.prefillData!['amount']!.replaceAll(RegExp(r'[^0-9.]'), '');
          _amountController.text = cleanAmt;
        }
        if (widget.prefillData!['merchant'] != null) {
          _notesController.text = widget.prefillData!['merchant']!;
        }
        if (widget.prefillData!['date'] != null) {
          try {
            _selectedDate = DateTime.parse(widget.prefillData!['date']!);
          } catch (_) {
            // keep default now() if parsing fails
          }
        }
        // Category will be matched after categories load
      }
    }
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final db = await DatabaseHelper.instance.database;
    
    // Load categories
    final catMaps = await db.query(
      DatabaseHelper.tableCategories,
      where: 'type = ?',
      whereArgs: [_selectedType],
      orderBy: 'name',
    );
    
    // Load tags
    final tagMaps = await db.query(
      DatabaseHelper.tableTags,
      orderBy: 'name',
    );
    final accounts = await DatabaseHelper.instance.getAllBankAccounts();
    final vehicles = await DatabaseHelper.instance.getAllVehicles();
    
    if (!mounted) return;

    final categories = catMaps.map((m) => Category.fromMap(m)).toList();
    final tags = tagMaps.map((m) => Tag.fromMap(m)).toList();
    
    setState(() {
      _availableCategories = categories;
      _availableTags = tags;
      _availableAccounts = accounts.where((a) => a.isAsset).toList();
      _availableVehicles = vehicles;
      
      if (_selectedAccountId == null && _availableAccounts.isNotEmpty) {
        final cash = _availableAccounts.where((a) => a.accountType == 'cash').firstOrNull;
        _selectedAccountId = cash?.id ?? _availableAccounts.first.id;
      }
      
      // Keep existing category if set, or auto-match AI category, or default to first
      if (_selectedCategoryId == null && _availableCategories.isNotEmpty) {
        if (widget.prefillData != null && widget.prefillData!['category'] != null) {
          final aiCatStr = widget.prefillData!['category']!.toLowerCase();
          final matchedCat = _availableCategories.where((c) => c.name.toLowerCase().contains(aiCatStr)).firstOrNull;
          _selectedCategoryId = matchedCat?.id ?? _availableCategories.first.id;
        } else {
          _selectedCategoryId = _availableCategories.first.id;
        }
      }
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: Theme.of(context).colorScheme.primary,
              onPrimary: Theme.of(context).colorScheme.onPrimary,
              surface: Theme.of(context).colorScheme.surfaceContainerHigh,
              onSurface: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
    }
  }

  void _saveTransaction() async {
    if (_amountController.text.isEmpty) {
      CustomSnackBar.show(context, message: 'Please enter an amount', isError: true);
      return;
    }

    final double amount = double.tryParse(_amountController.text) ?? 0.0;
    
    if (amount <= 0) {
      CustomSnackBar.show(context, message: 'Amount must be greater than zero', isError: true);
      return;
    }

    // TODO: Phase 3 Category Picker. For now, map the name as the ID temporarily.
    // We will replace this with real Category models in the next step.
    final newTransaction = Transaction(
      id: widget.existingTransaction?.id,
      userId: widget.existingTransaction?.userId ?? 'offline_user',
      type: _selectedType,
      categoryId: _selectedCategoryId,
      amount: amount,
      date: _selectedDate,
      notes: _notesController.text.trim(),
      tags: _selectedTags,
      source: _selectedAccountId != null ? 'bank_account' : (widget.existingTransaction?.source ?? 'manual'),
      relatedEntityId: _selectedAccountId ?? widget.existingTransaction?.relatedEntityId,
      vehicleId: _selectedVehicleId,
      location: _locationController.text.trim(),
      createdAt: widget.existingTransaction?.createdAt,
    );

    if (widget.existingTransaction != null) {
      await TransactionService.instance.updateTransaction(newTransaction);
    } else {
      await TransactionService.instance.addTransaction(newTransaction);
    }

    if (mounted) {
      Navigator.pop(context, true); // true indicates a new record was added
    }
  }

  void _deleteTransaction() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Transaction?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await TransactionService.instance.deleteTransaction(widget.existingTransaction!.id);
      if (mounted) {
        Navigator.pop(context, true);
      }
    }
  }

  Widget _buildTypeToggle() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedType = 'expense';
                  _loadInitialData();
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _selectedType == 'expense' ? Theme.of(context).colorScheme.error : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Expense',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _selectedType == 'expense' ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedType = 'income';
                  _loadInitialData();
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _selectedType == 'income' ? Theme.of(context).colorScheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Income',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _selectedType == 'income' ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const AddFuelScreen()),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Fuel',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Color headerColor = _selectedType == 'expense' ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingTransaction != null 
            ? 'Edit ${_selectedType == 'expense' ? 'Expense' : 'Income'}' 
            : 'Add ${_selectedType == 'expense' ? 'Expense' : 'Income'}'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.receipt_long, color: Theme.of(context).colorScheme.onSurfaceVariant),
            tooltip: 'Scan Receipt',
            onPressed: _scanReceipt,
          ),
          if (widget.existingTransaction != null)
            IconButton(
              icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              tooltip: 'Delete Transaction',
              onPressed: _deleteTransaction,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTypeToggle(),
            const SizedBox(height: 32),
            
            // Amount Input
            Text('Amount', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
            const SizedBox(height: 8),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(fontSize: 48, fontWeight: FontWeight.w600, color: headerColor),
              decoration: InputDecoration(
                prefixText: '${AppFormat.currencySymbol} ',
                prefixStyle: TextStyle(fontSize: 48, fontWeight: FontWeight.w600, color: headerColor.withValues(alpha: 0.5)),
                border: InputBorder.none,
                hintText: '0.00',
                hintStyle: TextStyle(color: Theme.of(context).colorScheme.outlineVariant),
              ),
            ),
            
            const Divider(color: Colors.white10, height: 40),
            
            // Category Selector
            Text('Category', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _availableCategories.map((cat) {
                final isSelected = _selectedCategoryId == cat.id;
                return GestureDetector(
                  onTap: () => setState(() => _selectedCategoryId = cat.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? headerColor.withValues(alpha: 0.15) : Theme.of(context).colorScheme.surfaceContainer,
                      border: Border.all(color: isSelected ? headerColor : Colors.transparent),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      cat.name,
                      style: TextStyle(
                        color: isSelected ? headerColor : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            
            const SizedBox(height: 32),

            // Bank Account Selector
            if (_availableAccounts.isNotEmpty) ...[
              Text('Linked Account', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
              const SizedBox(height: 12),
              SizedBox(
                height: 50,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _availableAccounts.length,
                  itemBuilder: (context, index) {
                    final acc = _availableAccounts[index];
                    final isSelected = _selectedAccountId == acc.id;
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedAccountId = isSelected ? null : acc.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: isSelected ? headerColor.withValues(alpha: 0.15) : Theme.of(context).colorScheme.surfaceContainer,
                            border: Border.all(color: isSelected ? headerColor : Colors.transparent),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            children: [
                              Icon(Icons.account_balance, size: 16, color: isSelected ? headerColor : Theme.of(context).colorScheme.onSurfaceVariant),
                              const SizedBox(width: 8),
                              Text(
                                acc.name,
                                style: TextStyle(
                                  color: isSelected ? headerColor : Theme.of(context).colorScheme.onSurfaceVariant,
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 32),
            ],
            
            // Tags Selector
            if (_availableTags.isNotEmpty) ...[
              Text('Tags', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _availableTags.map((tag) {
                  final isSelected = _selectedTags.contains(tag.id);
                  return FilterChip(
                    label: Text(tag.name),
                    selected: isSelected,
                    onSelected: (selected) {
                      HapticFeedback.lightImpact();
                      setState(() {
                        if (selected) {
                          _selectedTags.add(tag.id);
                        } else {
                          _selectedTags.remove(tag.id);
                        }
                      });
                    },
                    selectedColor: Theme.of(context).colorScheme.primaryContainer,
                    checkmarkColor: Theme.of(context).colorScheme.primary,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  );
                }).toList(),
              ),
              const SizedBox(height: 32),
            ],
            
            const SizedBox(height: 32),
            
            // Date Picker
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Date', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16)),
              subtitle: Text(DateFormat('EEEE, MMMM d, yyyy').format(_selectedDate), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              trailing: Icon(Icons.calendar_today, color: Theme.of(context).colorScheme.primary),
              onTap: () => _selectDate(context),
            ),
            
            const Divider(color: Colors.white12, height: 16),
            
            // Notes
            TextField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: 'Notes (Optional)',
                labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                border: InputBorder.none,
                prefixIcon: Icon(Icons.notes, color: Theme.of(context).colorScheme.onSurfaceVariant),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
              ),
            ),

            const Divider(color: Colors.white12, height: 16),

            // Location
            TextField(
              controller: _locationController,
              decoration: InputDecoration(
                labelText: 'Location (Optional)',
                labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                border: InputBorder.none,
                prefixIcon: Icon(Icons.location_on_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant),
                prefixIconConstraints: const BoxConstraints(minWidth: 40),
              ),
            ),

            const Divider(color: Colors.white12, height: 16),
            
            // Recurring
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Recurring', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16)),
              subtitle: Text('Repeat this transaction', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              value: _isRecurring,
              activeColor: Theme.of(context).colorScheme.primary,
              onChanged: (val) => setState(() => _isRecurring = val),
            ),
            
            const SizedBox(height: 48),
            
            // Save Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  _saveTransaction();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: headerColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text('Save Transaction', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Future<void> _scanReceipt() async {
    final picker = ImagePicker();
    final choice = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 16),
        Text('Scan Receipt', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 8),
        ListTile(
          leading: Icon(Icons.camera_alt, color: Theme.of(context).colorScheme.primary),
          title: const Text('Take Photo'),
          onTap: () => Navigator.pop(context, ImageSource.camera),
        ),
        ListTile(
          leading: Icon(Icons.photo_library, color: Theme.of(context).colorScheme.secondary),
          title: const Text('Choose from Gallery'),
          onTap: () => Navigator.pop(context, ImageSource.gallery),
        ),
        const SizedBox(height: 16),
      ]),
    );

    if (choice == null) return;

    final picked = await picker.pickImage(source: choice, imageQuality: 80);
    if (picked == null) return;

    CustomSnackBar.show(context, message: 'Reading receipt with AI...');

    GeminiService.instance.init();
    final result = await GeminiService.instance.scanReceipt(dart_io.File(picked.path));

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (result.containsKey('error')) {
      CustomSnackBar.show(context, message: 'Could not read receipt: ${result['error']}', isError: true);
      return;
    }

    // Auto-fill form
    if (result['amount'] != null) {
      _amountController.text = result['amount']!;
    }
    if (result['merchant'] != null) {
      _notesController.text = result['merchant']!;
    }
    // Try to match category
    if (result['category'] != null) {
      final matched = _availableCategories.where((c) =>
        c.name.toLowerCase().contains(result['category']!.toLowerCase()) ||
        result['category']!.toLowerCase().contains(c.name.toLowerCase())).toList();
      if (matched.isNotEmpty) {
        setState(() => _selectedCategoryId = matched.first.id);
      }
    }

    CustomSnackBar.show(context, message: '✓ Receipt scanned! Please verify the details.');
  }
}

