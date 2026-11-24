import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart' show cardsProvider;
import '../../features/accounts/providers/account_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../models/transaction.dart';
import '../../services/data_change_bus.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../shared/widgets/error_state_widget.dart';
import '../../shared/widgets/loading_state_widget.dart';
import '../../shared/widgets/spendx_glass.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../bank/account_list_screen.dart' show resolveAccountDisplayName;
import '../expense/add_expense_screen.dart';
import '../transaction_detail_screen.dart';
import 'search_filter_screen.dart';

/// SpendX Mindful Transaction Ledger (Activity Screen).
///
/// Implements SpendX Visual Language Rulebook:
/// - Cardless chronological journey stream (no 10-card fragmentation)
/// - Unified chronological ledger container with quiet date waypoints
/// - Real-time inline search + deep filter modal trigger
/// - SpendX vocabulary: Spent (↗), Received (↙), Moved (⇄)
/// - Day-level spend awareness without mental arithmetic
/// - Correct semantic classification for credit card purchases & payments
/// - Preserves 100% canonical double-entry accounting invariants
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
  final _searchController = TextEditingController();
  String _selectedFilter = 'all'; // 'all', 'spent', 'received', 'moved'
  String _movedSubFilter = 'all'; // 'all', 'repayment', 'self', 'deposits'
  String _searchQuery = '';

  bool _matchesMovedSubFilter(Transaction t, String subFilter) {
    if (subFilter == 'all') return true;
    final isCc =
        t.type == 'credit_payment' ||
        t.source.contains('credit') ||
        t.notes.toLowerCase().contains('credit card') ||
        t.notes.toLowerCase().contains('card payment');
    if (subFilter == 'repayment') return isCc;

    final isDep =
        t.notes.toLowerCase().contains('fd') ||
        t.notes.toLowerCase().contains('deposit') ||
        t.notes.toLowerCase().contains('rd') ||
        t.notes.toLowerCase().contains('groww') ||
        t.notes.toLowerCase().contains('mutual fund') ||
        t.notes.toLowerCase().contains('investment');
    if (subFilter == 'deposits') return isDep;

    if (subFilter == 'self') return !isCc && !isDep;
    return true;
  }

  void _onDataChanged() {
    if (mounted) {
      ref.read(paginatedTransactionsProvider.notifier).refresh();
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    DataChangeBus.instance.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    DataChangeBus.instance.removeListener(_onDataChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final paginatedState = ref.watch(paginatedTransactionsProvider);
    final categoryMapAsync = ref.watch(transactionCategoryMapProvider);
    final accountsAsync = ref.watch(accountsProvider);
    final cardsAsync = ref.watch(cardsProvider);

    return categoryMapAsync.when(
      loading: () =>
          const Center(child: LoadingStateWidget(message: 'Loading transactions...')),
      error: (err, _) => Center(
        child: ErrorStateWidget(
          message: err.toString(),
          onRetry: () => ref.invalidate(transactionCategoryMapProvider),
        ),
      ),
      data: (categoriesMap) {
        final accountsMap = <String, String>{
          for (final a in (accountsAsync.valueOrNull ?? []))
            a.id: resolveAccountDisplayName(a.name),
          for (final c in (cardsAsync.valueOrNull ?? []))
            c.id: resolveAccountDisplayName(
              c.name.isNotEmpty ? c.name : '${c.bank} Card',
            ),
        };

        // Source transactions (either filter IDs or paginated feed)
        List<Transaction> sourceTxns;
        if (widget.filterIds != null) {
          final allTxns = ref.watch(transactionsProvider).valueOrNull ?? [];
          final filterSet = widget.filterIds!.toSet();
          sourceTxns = allTxns.where((t) => filterSet.contains(t.id)).toList();
        } else {
          sourceTxns = paginatedState.items;
        }

        // Apply SpendX vocabulary filter (spent, received, moved) + text search
        final filteredTxns = sourceTxns.where((t) {
          final matchesType = switch (_selectedFilter) {
            'spent' => t.isExpenseType,
            'received' => t.isIncomeType,
            'moved' =>
              t.isTransferType && _matchesMovedSubFilter(t, _movedSubFilter),
            _ => true,
          };
          if (!matchesType) return false;

          if (_searchQuery.isNotEmpty) {
            final q = _searchQuery.toLowerCase();
            final noteMatch = t.notes.toLowerCase().contains(q);
            final cat = categoriesMap[t.categoryId];
            final catMatch = cat != null && cat.name.toLowerCase().contains(q);
            final accMatch =
                accountsMap[t.accountId]?.toLowerCase().contains(q) ?? false;
            final amountMatch = t.amount.toString().contains(q);
            if (!noteMatch && !catMatch && !accMatch && !amountMatch) {
              return false;
            }
          }
          return true;
        }).toList();

        final isInitialLoading =
            paginatedState.items.isEmpty && paginatedState.hasMore;

        // Calculate flow totals for the visible stream
        double visibleSpent = 0;
        double visibleReceived = 0;
        for (final t in filteredTxns) {
          if (t.isExpenseType) visibleSpent += t.amount;
          if (t.isIncomeType) visibleReceived += t.amount;
        }

        Widget content = LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 768;
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isTablet ? 768 : double.infinity,
                ),
                child: RefreshIndicator(
                  onRefresh: _onRefresh,
                  color: AppTheme.primaryBlue,
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      // ── Header Metric Pill (Quiet Awareness) ───────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainer,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: context.borderColor,
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.tertiary,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Outflow · ${AppFormat.currency(visibleSpent)}',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.2,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (visibleReceived > 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondaryContainer,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .secondary
                                          .withValues(alpha: 0.35),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    '+${AppFormat.currency(visibleReceived)}',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.2,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSecondaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${filteredTxns.length} records',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Search & Filter Controls ───────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    children: [
                      // Inline Search Input Bar
                      Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: context.borderColor,
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isDark
                                  ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.18)
                                  : Theme.of(context).colorScheme.shadow
                                        .withValues(alpha: 0.024),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 12),
                            Icon(
                              Icons.search_rounded,
                              size: 19,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                onChanged: (val) =>
                                    setState(() => _searchQuery = val.trim()),
                                style: TextStyle(
                                  fontSize: 13.5,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                                decoration: InputDecoration(
                                  hintText:
                                      'Search notes, categories, accounts...',
                                  hintStyle: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            if (_searchQuery.isNotEmpty)
                              IconButton(
                                tooltip: 'Close',
                                icon: const Icon(Icons.close_rounded, size: 18),
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              ),
                            // Filter tune trigger button
                            IconButton(
                              icon: const Icon(Icons.tune_rounded, size: 18),
                              tooltip: 'Deep Filters',
                              color: AppTheme.primaryBlue,
                              onPressed: () => Navigator.push(
                                context,
                                AppPageRoute(
                                  builder: (_) => const SearchFilterScreen(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // SpendX Vocabulary Filter Chips (Spent, Received, Moved)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _buildFilterChip(
                            label: 'All',
                            isSelected: _selectedFilter == 'all',
                            onTap: () =>
                                setState(() => _selectedFilter = 'all'),
                            isDark: isDark,
                          ),
                          _buildFilterChip(
                            label: 'Spent ↗',
                            isSelected: _selectedFilter == 'spent',
                            onTap: () =>
                                setState(() => _selectedFilter = 'spent'),
                            isDark: isDark,
                            activeColor: Theme.of(context).colorScheme.error,
                          ),
                          _buildFilterChip(
                            label: 'Received ↙',
                            isSelected: _selectedFilter == 'received',
                            onTap: () =>
                                setState(() => _selectedFilter = 'received'),
                            isDark: isDark,
                            activeColor: Theme.of(
                              context,
                            ).colorScheme.secondary,
                          ),
                          _buildFilterChip(
                            label: 'Moved ⇄',
                            isSelected: _selectedFilter == 'moved',
                            onTap: () =>
                                setState(() => _selectedFilter = 'moved'),
                            isDark: isDark,
                            activeColor: Theme.of(context).colorScheme.primary,
                          ),
                        ],
                      ),
                      if (_selectedFilter == 'moved') ...[
                        const SizedBox(height: 10),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            children: [
                              _buildSubFilterChip(
                                label: 'All Moved',
                                isSelected: _movedSubFilter == 'all',
                                onTap: () =>
                                    setState(() => _movedSubFilter = 'all'),
                                isDark: isDark,
                              ),
                              const SizedBox(width: 6),
                              _buildSubFilterChip(
                                label: 'Card Repayments',
                                icon: Icons.credit_card_rounded,
                                isSelected: _movedSubFilter == 'repayment',
                                onTap: () => setState(
                                  () => _movedSubFilter = 'repayment',
                                ),
                                isDark: isDark,
                                activeColor: Theme.of(
                                  context,
                                ).colorScheme.secondary,
                              ),
                              const SizedBox(width: 6),
                              _buildSubFilterChip(
                                label: 'Self-Transfers',
                                icon: Icons.sync_alt_rounded,
                                isSelected: _movedSubFilter == 'self',
                                onTap: () =>
                                    setState(() => _movedSubFilter = 'self'),
                                isDark: isDark,
                                activeColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              _buildSubFilterChip(
                                label: 'Deposits & Investments',
                                icon: Icons.trending_up_rounded,
                                isSelected: _movedSubFilter == 'deposits',
                                onTap: () => setState(
                                  () => _movedSubFilter = 'deposits',
                                ),
                                isDark: isDark,
                                activeColor: Theme.of(
                                  context,
                                ).colorScheme.tertiary,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ── Moved Net-Worth Reassurance Banner ────────
              if (_selectedFilter == 'moved' && !isInitialLoading)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.35),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                            ),
                            child: Icon(
                              Icons.sync_alt_rounded,
                              size: 16,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Total Moved: ${AppFormat.currency(sourceTxns.where((t) => t.isTransferType).fold<double>(0.0, (sum, t) => sum + t.amount))} • 0 Net Worth Impact',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  'Funds moved between your accounts or settled towards cards. Net worth is unchanged.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // ── Loading Skeleton ───────────────────────────
              if (isInitialLoading)
                const SliverToBoxAdapter(
                  child: SpendXLoadingState(count: 6, itemHeight: 64),
                ),

              // ── Mindful Empty State ────────────────────────
              if (!isInitialLoading && filteredTxns.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 20,
                    ),
                    child: EmptyStateWidget(
                      icon: Icons.receipt_long_outlined,
                      title: _searchQuery.isNotEmpty
                          ? 'No matching transactions'
                          : _selectedFilter == 'spent'
                          ? 'No spending recorded'
                          : _selectedFilter == 'received'
                          ? 'No income recorded'
                          : _selectedFilter == 'moved'
                          ? 'No transfers recorded'
                          : 'No transactions yet',
                      description: _searchQuery.isNotEmpty
                          ? 'Try searching by a different merchant or note.'
                          : _selectedFilter == 'spent'
                          ? 'Your money stayed completely untouched in this period.'
                          : 'Recorded transactions will flow continuously down this ledger.',
                      ctaLabel: '+ Log activity',
                      onCtaTap: _onAddTransaction,
                    ),
                  ),
                ),

              // ── Unified Cardless Ledger Stream ─────────────
              if (!isInitialLoading && filteredTxns.isNotEmpty)
                ..._buildUnifiedLedgerSlivers(
                  filteredTxns,
                  categoriesMap,
                  accountsMap,
                  isDark,
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

              // Generous bottom clearance above navigation shell
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          ),
        ),
      ),
    );
  },
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
                  color: context.textPrimary,
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

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required bool isDark,
    Color? activeColor,
  }) {
    final cs = Theme.of(context).colorScheme;
    final effectiveActiveBg = activeColor != null
        ? activeColor.withValues(alpha: isDark ? 0.25 : 0.15)
        : cs.primary;
    final effectiveActiveText = activeColor ?? cs.onPrimary;

    return Semantics(
      button: true,
      selected: isSelected,
      label: '$label filter',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Align(
            alignment: Alignment.center,
            widthFactor: 1,
            heightFactor: 1,
            child: AnimatedContainer(
              duration: context.motionDuration(const Duration(milliseconds: 180)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? effectiveActiveBg
                    : (Theme.of(context).colorScheme.surfaceContainer),
                borderRadius: BorderRadius.circular(100),
                border: Border.all(
                  color: isSelected
                      ? (activeColor ??
                            (isDark
                                ? cs.onSurface.withValues(alpha: 0.3)
                                : cs.primary))
                      : context.borderColor,
                  width: isSelected ? 1.0 : 0.8,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected
                      ? effectiveActiveText
                      : (Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required bool isDark,
    Color? activeColor,
    IconData? icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    final effectiveActiveBg = activeColor != null
        ? activeColor.withValues(alpha: isDark ? 0.28 : 0.16)
        : cs.primary;
    final effectiveActiveText = activeColor ?? cs.onPrimary;

    return Semantics(
      button: true,
      selected: isSelected,
      label: '$label sub-filter',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: AnimatedContainer(
              duration: context.motionDuration(const Duration(milliseconds: 180)),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? effectiveActiveBg
                    : context.onSurfaceOverlay(
                        lightOpacity: 0.04,
                        darkOpacity: 0.10,
                      ),
                borderRadius: BorderRadius.circular(100),
                border: Border.all(
                  color: isSelected
                      ? (activeColor ??
                            (isDark
                                ? cs.onSurface.withValues(alpha: 0.3)
                                : cs.primary))
                      : context.borderColor,
                  width: isSelected ? 1.0 : 0.6,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 13,
                      color: isSelected
                          ? effectiveActiveText
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected
                          ? effectiveActiveText
                          : (Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Groups transactions into a unified, continuous cardless ledger stream.
  List<Widget> _buildUnifiedLedgerSlivers(
    List<Transaction> transactions,
    Map<String, dynamic> categoriesMap,
    Map<String, String> accountsMap,
    bool isDark,
  ) {
    // Group transactions by calendar date
    final Map<String, List<Transaction>> grouped = {};
    for (final t in transactions) {
      final key = _formatDateHeader(t.date);
      grouped.putIfAbsent(key, () => []).add(t);
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: Theme.of(context).colorScheme.surfaceContainer,
              border: Border.all(
                color: context.borderColor,
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                      : Theme.of(
                          context,
                        ).colorScheme.shadow.withValues(alpha: 0.03),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: grouped.entries.map((group) {
                final dateHeader = group.key;
                final txnsInGroup = group.value;
                final isToday = dateHeader.contains('TODAY');

                // Calculate day spend
                double daySpend = 0;
                double dayInflow = 0;
                for (final t in txnsInGroup) {
                  if (t.isExpenseType) daySpend += t.amount;
                  if (t.isIncomeType) dayInflow += t.amount;
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Quiet Date Waypoint Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                      child: Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isToday
                                  ? AppTheme.primaryBlue
                                  : (Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              dateHeader,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: isToday
                                    ? AppTheme.primaryBlue
                                    : (Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (daySpend > 0)
                            Text(
                              '${AppFormat.currency(daySpend)} spent',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            )
                          else if (dayInflow > 0)
                            Text(
                              '+${AppFormat.currency(dayInflow)} received',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).colorScheme.secondary,
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Transaction rows for this date
                    ...List.generate(txnsInGroup.length, (index) {
                      final t = txnsInGroup[index];
                      final isLast = index == txnsInGroup.length - 1;
                      final fromName =
                          accountsMap[t.accountId] ??
                          (t.accountId != null && t.accountId!.isNotEmpty
                              ? resolveAccountDisplayName(t.accountId!)
                              : null);
                      final toName =
                          accountsMap[t.relatedEntityId] ??
                          (t.relatedEntityId != null &&
                                  t.relatedEntityId!.isNotEmpty
                              ? resolveAccountDisplayName(t.relatedEntityId!)
                              : null);
                      final flowLabel = (t.isTransferType && toName != null)
                          ? (fromName != null
                                ? '$fromName → $toName'
                                : '→ $toName')
                          : (fromName ?? '');
                      return SpendXTransactionTile(
                        transaction: t,
                        category: categoriesMap[t.categoryId],
                        accountName: flowLabel,
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

                    // Subtle separator between different calendar dates
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Divider(
                        height: 12,
                        thickness: 0.5,
                        color: context.borderColor,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    ];
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
