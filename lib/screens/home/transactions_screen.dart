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
  String _searchQuery = '';

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
          for (final a in (accountsAsync.valueOrNull ?? []))
            a.id: resolveAccountDisplayName(a.name),
          for (final c in (cardsAsync.valueOrNull ?? []))
            c.id: resolveAccountDisplayName(c.name.isNotEmpty ? c.name : '${c.bank} Card'),
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
            'moved' => t.isTransferType,
            _ => true,
          };
          if (!matchesType) return false;

          if (_searchQuery.isNotEmpty) {
            final q = _searchQuery.toLowerCase();
            final noteMatch = t.notes.toLowerCase().contains(q);
            final cat = categoriesMap[t.categoryId];
            final catMatch = cat != null && cat.name.toLowerCase().contains(q);
            final accMatch = accountsMap[t.accountId]?.toLowerCase().contains(q) ?? false;
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

        Widget content = RefreshIndicator(
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
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF1E2230) : const Color(0xFFF0ECE4),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE4DDD0),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFD97706),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Outflow · ${AppFormat.currency(visibleSpent)}',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF44403C),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (visibleReceived > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0x1E16A34A) : const Color(0xFFDCFCE7),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isDark ? const Color(0x3516A34A) : const Color(0xFFBBF7D0),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            '+${AppFormat.currency(visibleReceived)}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                              color: isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D),
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        '${filteredTxns.length} records',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
                          color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isDark ? Colors.black.withValues(alpha: 0.18) : const Color(0x061C1917),
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
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                onChanged: (val) => setState(() => _searchQuery = val.trim()),
                                style: TextStyle(
                                  fontSize: 13.5,
                                  color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Search notes, categories, accounts...',
                                  hintStyle: TextStyle(
                                    fontSize: 13,
                                    color: isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E),
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            if (_searchQuery.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.close_rounded, size: 18),
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
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
                                AppPageRoute(builder: (_) => const SearchFilterScreen()),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // SpendX Vocabulary Filter Chips (Spent, Received, Moved)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(
                          children: [
                            _buildFilterChip(
                              label: 'All',
                              isSelected: _selectedFilter == 'all',
                              onTap: () => setState(() => _selectedFilter = 'all'),
                              isDark: isDark,
                            ),
                            const SizedBox(width: 6),
                            _buildFilterChip(
                              label: 'Spent ↗',
                              isSelected: _selectedFilter == 'spent',
                              onTap: () => setState(() => _selectedFilter = 'spent'),
                              isDark: isDark,
                              activeColor: const Color(0xFFE11D48),
                            ),
                            const SizedBox(width: 6),
                            _buildFilterChip(
                              label: 'Received ↙',
                              isSelected: _selectedFilter == 'received',
                              onTap: () => setState(() => _selectedFilter = 'received'),
                              isDark: isDark,
                              activeColor: const Color(0xFF16A34A),
                            ),
                            const SizedBox(width: 6),
                            _buildFilterChip(
                              label: 'Moved ⇄',
                              isSelected: _selectedFilter == 'moved',
                              onTap: () => setState(() => _selectedFilter = 'moved'),
                              isDark: isDark,
                              activeColor: const Color(0xFF0284C7),
                            ),
                          ],
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

              // ── Mindful Empty State ────────────────────────
              if (!isInitialLoading && filteredTxns.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
                          width: 0.8,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDark ? const Color(0x254F46E5) : const Color(0xFFEEF2FF),
                            ),
                            child: Icon(
                              _searchQuery.isNotEmpty
                                  ? Icons.search_off_rounded
                                  : Icons.receipt_long_outlined,
                              size: 24,
                              color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'No matching transactions'
                                : _selectedFilter == 'spent'
                                    ? 'No spending recorded'
                                    : _selectedFilter == 'received'
                                        ? 'No income recorded'
                                        : _selectedFilter == 'moved'
                                            ? 'No transfers recorded'
                                            : 'No transactions yet',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'Try searching by a different merchant or note.'
                                : _selectedFilter == 'spent'
                                    ? 'Your money stayed completely untouched in this period.'
                                    : 'Recorded transactions will flow continuously down this ledger.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 18),
                          GestureDetector(
                            onTap: _onAddTransaction,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF4F46E5) : const Color(0xFF1C1917),
                                borderRadius: BorderRadius.circular(100),
                              ),
                              child: const Text(
                                '+ Log activity',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
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
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
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
    final effectiveActiveBg = activeColor != null
        ? activeColor.withValues(alpha: isDark ? 0.25 : 0.15)
        : (isDark ? const Color(0xFF334155) : const Color(0xFF1C1917));
    final effectiveActiveText = activeColor ?? (isDark ? Colors.white : Colors.white);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? effectiveActiveBg
              : (isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF)),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: isSelected
                ? (activeColor ?? (isDark ? Colors.white.withValues(alpha: 0.3) : const Color(0xFF1C1917)))
                : (isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8)),
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
                : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
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
              color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
              border: Border.all(
                color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.25)
                      : const Color(0x081C1917),
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
                                  : (isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            dateHeader,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              color: isToday
                                  ? AppTheme.primaryBlue
                                  : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
                            ),
                          ),
                          const Spacer(),
                          if (daySpend > 0)
                            Text(
                              '${AppFormat.currency(daySpend)} spent',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                              ),
                            )
                          else if (dayInflow > 0)
                            Text(
                              '+${AppFormat.currency(dayInflow)} received',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF16A34A),
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Transaction rows for this date
                    ...List.generate(txnsInGroup.length, (index) {
                      final t = txnsInGroup[index];
                      final isLast = index == txnsInGroup.length - 1;
                      final fromName = accountsMap[t.accountId];
                      final toName = accountsMap[t.relatedEntityId];
                      final flowLabel = (t.isTransferType && toName != null)
                          ? (fromName != null ? '$fromName → $toName' : '→ $toName')
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
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : const Color(0xFFF0ECE4),
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
