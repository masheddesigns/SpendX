import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/transaction.dart';
import '../../models/category.dart';
import '../../data/providers.dart';
import '../../services/transaction_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/transaction_tile.dart';
import '../transaction_detail_screen.dart';
import '../expense/add_expense_screen.dart';
import 'package:provider/provider.dart';
import '../../services/settings_service.dart';
import 'package:intl/intl.dart';
import '../../shared/widgets/app_page_route.dart';

class SearchFilterScreen extends ConsumerStatefulWidget {
  const SearchFilterScreen({super.key});

  @override
  ConsumerState<SearchFilterScreen> createState() => _SearchFilterScreenState();
}

class _SearchFilterScreenState extends ConsumerState<SearchFilterScreen> {
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
    _performSearch();
  }

  Future<void> _performSearch() async {
    setState(() => _isLoading = true);

    final query = _searchController.text.trim();

    final fetched = await TransactionService.instance.searchTransactions(
      query: query.isEmpty ? null : query,
      type: _selectedType,
      categoryId: _selectedCategoryId,
      startDate: _startDate?.toIso8601String(),
      endDate: _endDate
          ?.add(const Duration(days: 1))
          .subtract(const Duration(milliseconds: 1))
          .toIso8601String(), // End of day
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
    if (!kIsWeb) {
      final categories = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
      _categoriesMap = {for (final item in categories) item.id: item};
    }
    final isIncomeDisabled = context.watch<SettingsService>().isIncomeDisabled;

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
      body: SafeArea(
        child: Column(
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
                      prefixIcon: Icon(
                        Icons.search,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          _performSearch();
                        },
                      ),
                      filled: true,
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh,
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
                            hint: Text(
                              "Any Type",
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            dropdownColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHigh,
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text("Any Type"),
                              ),
                              if (!isIncomeDisabled)
                                const DropdownMenuItem(
                                  value: 'income',
                                  child: Text("Income"),
                                ),
                              const DropdownMenuItem(
                                value: 'expense',
                                child: Text("Expense"),
                              ),
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
                            hint: Text(
                              "Any Category",
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            dropdownColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHigh,
                            items: [
                              const DropdownMenuItem(
                                value: null,
                                child: Text("Any Category"),
                              ),
                              ..._categoriesMap.values.map(
                                (c) => DropdownMenuItem(
                                  value: c.id,
                                  child: Text(c.name),
                                ),
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
                          label: Text(
                            _startDate != null
                                ? "${DateFormat('MMM d').format(_startDate!)} - ${DateFormat('MMM d').format(_endDate!)}"
                                : "Any Date",
                          ),
                          avatar: Icon(
                            Icons.calendar_today,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.2),
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
                  : ListView.separated(
                      padding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.listHorizontalPadding,
                          vertical: 8),
                      itemCount: _results.length,
                      separatorBuilder: (_, _) =>
                          SizedBox(height: AppSpacing.cardGap),
                      itemBuilder: (context, index) {
                        final t = _results[index];
                        return TransactionTile(
                          transaction: t,
                          category: _categoriesMap[t.categoryId],
                          onTap: () async {
                            final result = await Navigator.push(
                              context,
                              AppPageRoute(
                                builder: (_) => UnifiedTransactionDetailScreen(
                                  transaction: t,
                                  category: _categoriesMap[t.categoryId],
                                ),
                              ),
                            );
                            if (result == true) _performSearch();
                          },
                          onEdit: () async {
                            final result = await Navigator.push(
                              context,
                              AppPageRoute(
                                builder: (_) => AddExpenseScreen(
                                  initialType: t.type,
                                  existingTransaction: t,
                                ),
                              ),
                            );
                            if (result == true) _performSearch();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
