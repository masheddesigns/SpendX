import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/transaction.dart';
import '../../models/category.dart';
import '../../data/providers.dart';
import '../../data/repositories/transaction_repo.dart';
import '../../theme/app_theme.dart';
import '../transaction_detail_screen.dart';
import 'package:provider/provider.dart';
import '../../services/settings_service.dart';
import 'package:intl/intl.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/glass/spendx_scaffold.dart';
import '../../shared/widgets/glass/spendx_glass_surface.dart';
import '../../shared/widgets/glass/spendx_states.dart';
import '../../shared/widgets/glass/spendx_transaction_tile.dart';

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

    final all = await TransactionRepo().getAll();
    final q = query.toLowerCase();
    final fetched = all.where((t) {
      final matchesQuery =
          q.isEmpty || t.notes.toLowerCase().contains(q);
      final matchesType = _selectedType == null || t.type == _selectedType;
      final matchesCategory =
          _selectedCategoryId == null || t.categoryId == _selectedCategoryId;
      final matchesStart =
          _startDate == null || !t.date.isBefore(_startDate!);
      final matchesEnd = _endDate == null ||
          t.date.isBefore(
            _endDate!.add(const Duration(days: 1)),
          );
      return matchesQuery &&
          matchesType &&
          matchesCategory &&
          matchesStart &&
          matchesEnd;
    }).toList();

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

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: 'Search & Filter',
        actions: [
          IconButton(
            icon: Icon(
              Icons.refresh_rounded,
              color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
            tooltip: 'Reset Filters',
            onPressed: _resetFilters,
          ),
        ],
      ),
      body: Column(
        children: [
          // Search & Filter Panel
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              borderRadius: BorderRadius.circular(AppRadius.l),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _searchController,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      fontSize: 15,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search notes, tags, descriptions...',
                      hintStyle: TextStyle(
                        color: isDark ? const Color(0x7094A3B8) : const Color(0x8064748B),
                        fontSize: 14,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: AppTheme.primaryBlue,
                        size: 20,
                      ),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: Icon(
                                Icons.clear_rounded,
                                size: 18,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                              ),
                              onPressed: () {
                                _searchController.clear();
                                _performSearch();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: isDark ? const Color(0x1AFFFFFF) : const Color(0x66FFFFFF),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark ? const Color(0x28FFFFFF) : const Color(0x18000000),
                          width: 0.75,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: isDark ? const Color(0x28FFFFFF) : const Color(0x18000000),
                          width: 0.75,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: AppTheme.primaryBlue,
                          width: 1.25,
                        ),
                      ),
                    ),
                    onSubmitted: (_) => _performSearch(),
                  ),
                  const SizedBox(height: 12),

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
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _selectDateRange,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: (_startDate != null)
                                  ? AppTheme.primaryBlue.withValues(alpha: isDark ? 0.20 : 0.15)
                                  : (isDark ? const Color(0x14FFFFFF) : const Color(0x40FFFFFF)),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: (_startDate != null)
                                    ? AppTheme.primaryBlue.withValues(alpha: isDark ? 0.60 : 0.45)
                                    : (isDark ? const Color(0x24FFFFFF) : const Color(0x18000000)),
                                width: 0.75,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.calendar_month_rounded,
                                  size: 15,
                                  color: (_startDate != null)
                                      ? AppTheme.primaryBlue
                                      : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _startDate == null
                                      ? 'Date Range'
                                      : '${DateFormat('dd/MM').format(_startDate!)} - ${DateFormat('dd/MM').format(_endDate ?? _startDate!)}',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: (_startDate != null)
                                        ? (isDark ? Colors.white : const Color(0xFF0F172A))
                                        : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

            // Results
            Expanded(
              child: _isLoading
                  ? const SpendXLoadingState(count: 4, itemHeight: 64)
                  : _results.isEmpty
                      ? const SpendXEmptyState(
                          icon: Icons.search_off_rounded,
                          title: 'No transactions found',
                          subtitle: 'Try adjusting your search terms or filter range.',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                          itemCount: _results.length,
                          itemBuilder: (context, index) {
                            final t = _results[index];
                            return SpendXTransactionTile(
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
                            );
                          },
                        ),
            ),
          ],
        ),
    );
  }
}
