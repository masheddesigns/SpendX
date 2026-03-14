import os

filepath = '/Users/sivek/Documents/SpendX/lib/screens/expense/add_expense_screen.dart'

with open(filepath, 'r') as f:
    content = f.read()

# 1. Imports
if "import '../../models/bank_account.dart';" not in content:
    content = content.replace(
        "import '../../models/transaction.dart';",
        "import '../../models/transaction.dart';\nimport '../../models/bank_account.dart';"
    )

# 2. State vars
if "List<BankAccount> _availableAccounts = [];" not in content:
    content = content.replace(
        "  List<Tag> _availableTags = [];\n  List<String> _selectedTags = []; // Store IDs of selected tags",
        "  List<Tag> _availableTags = [];\n  List<String> _selectedTags = [];\n  List<BankAccount> _availableAccounts = [];\n  String? _selectedAccountId;"
    )

# 3. initState
if "if (txn.source == 'bank_account')" not in content:
    content = content.replace(
        "      _selectedTags = List.from(txn.tags);\n    } else {",
        "      _selectedTags = List.from(txn.tags);\n      if (txn.source == 'bank_account') _selectedAccountId = txn.relatedEntityId;\n    } else {"
    )

# 4. _loadInitialData
old_load = """    final tagMaps = await db.query(
      DatabaseHelper.tableTags,
      orderBy: 'name',
    );
    
    if (!mounted) return;

    final categories = catMaps.map((m) => Category.fromMap(m)).toList();
    final tags = tagMaps.map((m) => Tag.fromMap(m)).toList();
    
    setState(() {
      _availableCategories = categories;
      _availableTags = tags;"""

new_load = """    final tagMaps = await db.query(
      DatabaseHelper.tableTags,
      orderBy: 'name',
    );
    final accounts = await DatabaseHelper.instance.getAllBankAccounts();
    
    if (!mounted) return;

    final categories = catMaps.map((m) => Category.fromMap(m)).toList();
    final tags = tagMaps.map((m) => Tag.fromMap(m)).toList();
    
    setState(() {
      _availableCategories = categories;
      _availableTags = tags;
      _availableAccounts = accounts.where((a) => a.isAsset).toList();
      
      if (_selectedAccountId == null && _availableAccounts.isNotEmpty) {
        final cash = _availableAccounts.where((a) => a.accountType == 'cash').firstOrNull;
        _selectedAccountId = cash?.id ?? _availableAccounts.first.id;
      }"""
content = content.replace(old_load, new_load)

# 5. _saveTransaction
old_txn = """    final newTransaction = Transaction(
      id: widget.existingTransaction?.id,
      userId: widget.existingTransaction?.userId ?? 'offline_user',
      type: _selectedType,
      categoryId: _selectedCategoryId,
      amount: amount,
      date: _selectedDate,
      notes: _notesController.text.trim(),
      tags: _selectedTags,
      source: widget.existingTransaction?.source ?? 'manual',
      relatedEntityId: widget.existingTransaction?.relatedEntityId,
      createdAt: widget.existingTransaction?.createdAt,
    );"""

new_txn = """    final newTransaction = Transaction(
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
      createdAt: widget.existingTransaction?.createdAt,
    );"""
content = content.replace(old_txn, new_txn)

# 6. Build UI (below the Amount box)
old_ui = """            const SizedBox(height: 32),
            
            // Category Selector
            Text"""
            
new_ui = """            const SizedBox(height: 32),
            
            // Source Account Selector
            if (_availableAccounts.isNotEmpty) ...[
              Text('Source Account', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedAccountId,
                    isExpanded: true,
                    dropdownColor: AppTheme.surfaceColor,
                    hint: const Text('Select Account', style: TextStyle(color: Colors.white70)),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('None / Manual', style: TextStyle(color: Colors.grey))),
                      ..._availableAccounts.map((account) => DropdownMenuItem(
                        value: account.id,
                        child: Row(
                          children: [
                            Icon(Icons.account_balance_wallet, size: 18, color: Color(int.parse('FF${account.color.replaceAll('#', '')}', radix: 16))),
                            const SizedBox(width: 12),
                            Text('${account.name} (\\$${account.balance.toStringAsFixed(0)})', style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      )),
                    ],
                    onChanged: (val) {
                      setState(() => _selectedAccountId = val);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Category Selector
            Text"""
            
content = content.replace(old_ui, new_ui)

with open(filepath, 'w') as f:
    f.write(content)

print("AddExpenseScreen updated.")
