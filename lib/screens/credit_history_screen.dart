import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/credit_transaction.dart';
import '../models/category.dart';
import '../data/providers.dart';
import '../utils/app_format.dart';
import '../widgets/spendx_app_bar.dart';
import '../widgets/empty_state.dart';
import '../widgets/transaction_tile.dart';
import '../models/transaction.dart' as spx;

class CreditHistoryScreen extends ConsumerStatefulWidget {
  final String? cardId; // Optional: filter by card
  const CreditHistoryScreen({super.key, this.cardId});

  @override
  ConsumerState<CreditHistoryScreen> createState() =>
      _CreditHistoryScreenState();
}

class _CreditHistoryScreenState extends ConsumerState<CreditHistoryScreen> {
  final _searchController = TextEditingController();
  List<CreditTransaction> _allTransactions = [];
  List<CreditTransaction> _filteredTransactions = [];
  List<Category> _categories = [];

  String? _selectedCategoryId;
  DateTimeRange? _dateRange;
  RangeValues _amountRange = const RangeValues(0, 100000);
  String _sortBy = 'date_desc'; // date_desc, date_asc, amount_desc, amount_asc

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final txns = await ref.read(
      creditTransactionsProvider(widget.cardId).future,
    );
    final cats = ref.read(expenseCategoriesProvider);

    setState(() {
      _allTransactions = txns;
      _categories = cats;
      _filteredTransactions = txns;
      _isLoading = false;
    });
    _applyFilters();
  }

  void _applyFilters() {
    setState(() {
      _filteredTransactions = _allTransactions.where((txn) {
        // Search filter
        final matchesSearch =
            _searchController.text.isEmpty ||
            (txn.note?.toLowerCase().contains(
                  _searchController.text.toLowerCase(),
                ) ??
                false) ||
            txn.category.toLowerCase().contains(
              _searchController.text.toLowerCase(),
            );

        // Category filter
        final matchesCategory =
            _selectedCategoryId == null ||
            txn.categoryId == _selectedCategoryId;

        // Date filter
        final matchesDate =
            _dateRange == null ||
            (txn.date.isAfter(_dateRange!.start) &&
                txn.date.isBefore(
                  _dateRange!.end.add(const Duration(days: 1)),
                ));

        // Amount filter
        final matchesAmount =
            txn.amount >= _amountRange.start && txn.amount <= _amountRange.end;

        return matchesSearch && matchesCategory && matchesDate && matchesAmount;
      }).toList();

      // Sort
      switch (_sortBy) {
        case 'date_desc':
          _filteredTransactions.sort((a, b) => b.date.compareTo(a.date));
          break;
        case 'date_asc':
          _filteredTransactions.sort((a, b) => a.date.compareTo(b.date));
          break;
        case 'amount_desc':
          _filteredTransactions.sort((a, b) => b.amount.compareTo(a.amount));
          break;
        case 'amount_asc':
          _filteredTransactions.sort((a, b) => a.amount.compareTo(b.amount));
          break;
      }
    });
  }

  void _showSortOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sortTile('Latest First', 'date_desc'),
          _sortTile('Oldest First', 'date_asc'),
          _sortTile('Highest Amount', 'amount_desc'),
          _sortTile('Lowest Amount', 'amount_asc'),
        ],
      ),
    );
  }

  Widget _sortTile(String title, String value) {
    return ListTile(
      title: Text(title),
      trailing: _sortBy == value
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () {
        setState(() => _sortBy = value);
        _applyFilters();
        Navigator.pop(context);
      },
    );
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (sctx, setFs) => Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Filters',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),

              const Text(
                'Category',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              DropdownButton<String>(
                value: _selectedCategoryId,
                isExpanded: true,
                hint: const Text('All Categories'),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('All Categories'),
                  ),
                  ..._categories.map(
                    (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ),
                ],
                onChanged: (v) => setFs(() => _selectedCategoryId = v),
              ),
              const SizedBox(height: 24),

              const Text(
                'Date Range',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              ListTile(
                title: Text(
                  _dateRange == null
                      ? 'All Time'
                      : '${DateFormat.yMMMd().format(_dateRange!.start)} - ${DateFormat.yMMMd().format(_dateRange!.end)}',
                ),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: () async {
                  final range = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (range != null) setFs(() => _dateRange = range);
                },
              ),
              const SizedBox(height: 24),

              Text(
                'Amount: ${AppFormat.currency(_amountRange.start)} - ${AppFormat.currency(_amountRange.end)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              RangeSlider(
                values: _amountRange,
                min: 0,
                max: 500000,
                divisions: 50,
                onChanged: (v) => setFs(() => _amountRange = v),
              ),
              const SizedBox(height: 32),

              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        setFs(() {
                          _selectedCategoryId = null;
                          _dateRange = null;
                          _amountRange = const RangeValues(0, 100000);
                        });
                      },
                      child: const Text('Reset'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        _applyFilters();
                        Navigator.pop(context);
                      },
                      child: const Text('Apply Filters'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Credit History',
        actions: [
          IconButton(
            icon: const Icon(Icons.sort_rounded),
            onPressed: _showSortOptions,
          ),
          IconButton(
            icon: const Icon(Icons.filter_list_rounded),
            onPressed: _showFilterSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search purchases, fees...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => _applyFilters(),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredTransactions.isEmpty
                ? EmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No transactions found',
                    description: 'Try adjusting your filters or search terms.',
                    buttonText: 'Reset Filters',
                    onButtonPressed: () {
                      setState(() {
                        _searchController.clear();
                        _selectedCategoryId = null;
                        _dateRange = null;
                        _amountRange = const RangeValues(0, 100000);
                      });
                      _applyFilters();
                    },
                  )
                : ListView.builder(
                    itemCount: _filteredTransactions.length,
                    itemBuilder: (ctx, i) {
                      final txn = _filteredTransactions[i];
                      Category? category;
                      for (final item in _categories) {
                        if (item.id == txn.categoryId) {
                          category = item;
                          break;
                        }
                      }
                      // Wrap in spx.Transaction for tile compatibility
                      final displayTxn = spx.Transaction(
                        id: txn.id,
                        userId: 'offline_user',
                        type: txn.amount < 0 ? 'income' : 'expense',
                        categoryId: txn.categoryId,
                        amount: txn.amount,
                        date: txn.date,
                        notes: txn.note ?? '',
                        source: 'credit_purchase',
                        relatedEntityId: txn.id,
                      );
                      return TransactionTile(
                        transaction: displayTxn,
                        category: category,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
