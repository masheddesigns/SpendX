import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../features/accounts/providers/account_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../models/transaction.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/spendx_glass.dart';
import '../../theme/app_theme.dart';
import '../expense/add_expense_screen.dart';
import '../transaction_detail_screen.dart';
import 'search_filter_screen.dart';

/// SpendX 2.0 Canonical Transaction Ledger (Activity Screen).
///
/// Implements Section 4 of C15-B:
/// - Financial timeline experience rather than disjoint cards
/// - Floating filter controls (All, Expenses, Income, Transfers)
/// - Transactions grouped by date into single-layer Liquid Glass surfaces
/// - High-density rows with category icon pills, clear typography, and tabular figures
/// - Pull-to-refresh and smooth pagination
/// - Retains 100% canonical ledger provider contracts
class TransactionListScreen extends ConsumerStatefulWidget {
  final bool isFullScreen;

  /// If set, only shows transactions with these IDs (audit fix flow).
  final List<String>? filterIds;

  /// Title override for filtered views.
  final String? title;

  const TransactionListScreen({
    super.key,
    this.isFullScreen = false,
    this.filterIds,
    this.title,
  });

  @override
  ConsumerState<TransactionListScreen> createState() =>
      _TransactionListScreenState();
}

class _TransactionListScreenState extends ConsumerState<TransactionListScreen> {
  final _scrollController = ScrollController();
  String _selectedFilter = 'all'; // 'all', 'expense', 'income', 'transfer'

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent * 0.8) {
      ref.read(paginatedTransactionsProvider.notifier).loadMore();
    }
  }

  Future<void> _onRefresh() async {
    await ref.read(paginatedTransactionsProvider.notifier).refresh();
    ref.invalidate(transactionCategoryMapProvider);
    ref.invalidate(accountsProvider);
  }

  Future<void> _onAddTransaction() async {
    final result = await Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => const AddExpenseScreen(initialType: 'expense'),
      ),
    );
    if (result == true) {
      await _onRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final paginatedState = ref.watch(paginatedTransactionsProvider);
    final categoryMapAsync = ref.watch(transactionCategoryMapProvider);
    final accountsAsync = ref.watch(accountsProvider);

    return categoryMapAsync.when(
      loading: () => const Center(
        child: SpendXLoadingState(count: 6, itemHeight: 64),
      ),
      error: (err, _) => Center(
        child: SpendXErrorState(
          message: err.toString(),
          onRetry: () => ref.invalidate(transactionCategoryMapProvider),
        ),
      ),
      data: (categoriesMap) {
        final accountsMap = <String, String>{
          for (final a in (accountsAsync.valueOrNull ?? [])) a.id: a.name,
        };

        // Filter by IDs if provided (audit fix flow)
        List<Transaction> sourceTxns;
        if (widget.filterIds != null) {
          final allTxns = ref.watch(transactionsProvider).valueOrNull ?? [];
          final filterSet = widget.filterIds!.toSet();
          sourceTxns = allTxns.where((t) => filterSet.contains(t.id)).toList();
        } else {
          sourceTxns = paginatedState.items;
        }

        // Apply active filter pill
        final filteredTxns = _selectedFilter == 'all'
            ? sourceTxns
            : sourceTxns.where((t) => t.type == _selectedFilter).toList();

        final isInitialLoading =
            paginatedState.items.isEmpty && paginatedState.hasMore;

        Widget content = RefreshIndicator(
          onRefresh: _onRefresh,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // ── Filter & Search Header ─────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            children: [
                              SpendXGlassChip(
                                label: 'All',
                                isSelected: _selectedFilter == 'all',
                                onTap: () =>
                                    setState(() => _selectedFilter = 'all'),
                              ),
                              const SizedBox(width: 6),
                              SpendXGlassChip(
                                label: 'Expenses',
                                isSelected: _selectedFilter == 'expense',
                                onTap: () =>
                                    setState(() => _selectedFilter = 'expense'),
                              ),
                              const SizedBox(width: 6),
                              SpendXGlassChip(
                                label: 'Income',
                                isSelected: _selectedFilter == 'income',
                                onTap: () =>
                                    setState(() => _selectedFilter = 'income'),
                              ),
                              const SizedBox(width: 6),
                              SpendXGlassChip(
                                label: 'Transfers',
                                isSelected: _selectedFilter == 'transfer',
                                onTap: () =>
                                    setState(() => _selectedFilter = 'transfer'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Search Trigger Button
                      GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          AppPageRoute(
                            builder: (_) => const SearchFilterScreen(),
                          ),
                        ),
                        child: SpendXGlassSurface(
                          level: SpendXGlassLevel.interactive,
                          width: 36,
                          height: 36,
                          borderRadius: BorderRadius.circular(AppRadius.full),
                          child: const Center(
                            child: Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: AppTheme.primaryBlue,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Loading Skeleton ───────────────────────────
              if (isInitialLoading)
                const SliverToBoxAdapter(
                  child: SpendXLoadingState(count: 6, itemHeight: 64),
                ),

              // ── Empty State ────────────────────────────────
              if (!isInitialLoading && filteredTxns.isEmpty)
                SliverToBoxAdapter(
                  child: SpendXEmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: _selectedFilter == 'all'
                        ? 'No transactions yet'
                        : 'No ${_selectedFilter}s found',
                    subtitle:
                        'Transactions recorded from manual entry, SMS, or recurring will appear here.',
                    actionLabel: '+ Add Transaction',
                    onAction: _onAddTransaction,
                  ),
                ),

              // ── Timeline Date Groups ───────────────────────
              if (!isInitialLoading && filteredTxns.isNotEmpty)
                ..._buildTimelineSlivers(
                  filteredTxns,
                  categoriesMap,
                  accountsMap,
                ),

              // ── Pagination Loading Spinner ─────────────────
              if (paginatedState.hasMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ),

              // Generous bottom clearance above floating navigation
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
        );

        if (widget.isFullScreen) {
          return SpendXScaffold(
            extendBody: true,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              title: Text(
                widget.title ?? 'Activity',
                style: AppTextStyles.heading.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.add_rounded),
                  tooltip: 'Add Transaction',
                  onPressed: _onAddTransaction,
                ),
              ],
            ),
            body: content,
          );
        }

        return content;
      },
    );
  }

  /// Groups transactions by calendar date and builds grouped Liquid Glass surfaces.
  List<Widget> _buildTimelineSlivers(
    List<Transaction> transactions,
    Map<String, dynamic> categoriesMap,
    Map<String, String> accountsMap,
  ) {
    // Group transactions by date string
    final Map<String, List<Transaction>> grouped = {};
    for (final t in transactions) {
      final key = _formatDateHeader(t.date);
      grouped.putIfAbsent(key, () => []).add(t);
    }

    final slivers = <Widget>[];

    for (final entry in grouped.entries) {
      final dateHeader = entry.key;
      final txns = entry.value;

      // Date Header (direct canvas typography)
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Text(
              dateHeader,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF94A3B8)
                    : const Color(0xFF64748B),
              ),
            ),
          ),
        ),
      );

      // Grouped Liquid Glass Container for this date
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              padding: EdgeInsets.zero,
              child: Column(
                children: List.generate(txns.length, (index) {
                  final t = txns[index];
                  final isLast = index == txns.length - 1;
                  return SpendXTransactionTile(
                    transaction: t,
                    category: categoriesMap[t.categoryId],
                    accountName: accountsMap[t.accountId],
                    showDivider: !isLast,
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        AppPageRoute(
                          builder: (_) => UnifiedTransactionDetailScreen(
                            transaction: t,
                            category: categoriesMap[t.categoryId],
                          ),
                        ),
                      );
                      if (result == true) _onRefresh();
                    },
                  );
                }),
              ),
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);

    final diffDays = today.difference(target).inDays;
    if (diffDays == 0) return 'TODAY';
    if (diffDays == 1) return 'YESTERDAY';

    if (date.year == now.year) {
      return DateFormat('EEEE, d MMMM').format(date).toUpperCase();
    }
    return DateFormat('d MMMM yyyy').format(date).toUpperCase();
  }
}
