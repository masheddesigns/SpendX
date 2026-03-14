import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../models/transaction.dart';
import '../../models/category.dart';
import '../../services/transaction_service.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../widgets/transaction_tile.dart';
import 'package:intl/intl.dart';

class SearchFilterScreen extends StatefulWidget {
  const SearchFilterScreen({super.key});

  @override
  State<SearchFilterScreen> createState() => _SearchFilterScreenState();
}

class _SearchFilterScreenState extends State<SearchFilterScreen> {
  final TextEditingController _searchController = TextEditingController();
  
  String? _selectedType;
  String? _selectedCategoryId;
  DateTime? _startDate;
  DateTime? _endDate;

  List<Transaction> _results = [];
  Map<String, Category> _categoriesMap = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _performSearch();
  }

  Future<void> _loadCategories() async {
    if (kIsWeb) return;
    try {
      final db = await DatabaseHelper.instance.database;
      final catMaps = await db.query(DatabaseHelper.tableCategories);
      final fetchedCategories = { for (var item in catMaps) item['id'] as String : Category.fromMap(item) };
      if (mounted) {
        setState(() => _categoriesMap = fetchedCategories);
      }
    } catch (e) {
      debugPrint('SearchFilter load categories error: $e');
    }
  }

  Future<void> _performSearch() async {
    setState(() => _isLoading = true);
    
    final query = _searchController.text.trim();
    
    final fetched = await TransactionService.instance.searchTransactions(
      query: query.isEmpty ? null : query,
      type: _selectedType,
      categoryId: _selectedCategoryId,
      startDate: _startDate?.toIso8601String(),
      endDate: _endDate?.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1)).toIso8601String(), // End of day
    );

    if (mounted) {
      setState(() {
        _results = fetched;
        _isLoading = false;
      });
    }
  }

  void _resetFilters() {
    setState(() {
      _searchController.clear();
      _selectedType = null;
      _selectedCategoryId = null;
      _startDate = null;
      _endDate = null;
    });
    _performSearch();
  }

  Future<void> _selectDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: _startDate != null && _endDate != null 
        ? DateTimeRange(start: _startDate!, end: _endDate!) 
        : null,
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

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _performSearch();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search & Filter'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset Filters',
            onPressed: _resetFilters,
          ),
        ],
      ),
      body: Column(
        children: [
          // Search & Filter Panel
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Search Bar
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search notes, tags...',
                    prefixIcon: Icon(Icons.search, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.clear, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      onPressed: () {
                        _searchController.clear();
                        _performSearch();
                      },
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _performSearch(),
                ),
                const SizedBox(height: 16),
                
                // Horizontal Filter Chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // Type Filter
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedType,
                          hint: Text("Any Type", style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                          items: const [
                            DropdownMenuItem(value: null, child: Text("Any Type")),
                            DropdownMenuItem(value: 'income', child: Text("Income")),
                            DropdownMenuItem(value: 'expense', child: Text("Expense")),
                          ],
                          onChanged: (val) {
                            setState(() => _selectedType = val);
                            _performSearch();
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Category Filter
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedCategoryId,
                          hint: Text("Any Category", style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                          items: [
                            const DropdownMenuItem(value: null, child: Text("Any Category")),
                            ..._categoriesMap.values.map((c) => 
                              DropdownMenuItem(value: c.id, child: Text(c.name))
                            ),
                          ],
                          onChanged: (val) {
                            setState(() => _selectedCategoryId = val);
                            _performSearch();
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Date Filter Button
                        ActionChip(
                        label: Text(_startDate != null 
                            ? "${DateFormat('MMM d').format(_startDate!)} - ${DateFormat('MMM d').format(_endDate!)}"
                            : "Any Date"),
                        avatar: Icon(Icons.calendar_today, size: 16, color: Theme.of(context).colorScheme.primary),
                        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                        onPressed: _selectDateRange,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Results
          Expanded(
            child: _isLoading 
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(
                        child: Text(
                          "No transactions found.", 
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            decoration: TextDecoration.none, // Fix underline bug
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final t = _results[index];
                          return TransactionTile(
                            transaction: t,
                            category: _categoriesMap[t.categoryId],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
