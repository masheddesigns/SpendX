import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spend_x/widgets/transaction_tile.dart';
import 'package:spend_x/screens/expense/add_expense_screen.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../transaction_detail_screen.dart';
import '../../theme/app_theme.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../shared/widgets/skeleton_loader.dart';
import '../../shared/widgets/error_state_widget.dart';
import 'search_filter_screen.dart';
import '../../shared/widgets/app_page_route.dart';

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
  }

  Future<void> _onAddTransaction() async {
    final result = await Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => const AddExpenseScreen(initialType: 'expense'),
      ),
    );
    if (result == true) {
      ref.read(paginatedTransactionsProvider.notifier).refresh();
      ref.invalidate(transactionsProvider); // for analytics
    }
  }

  @override
  Widget build(BuildContext context) {
    final paginatedState = ref.watch(paginatedTransactionsProvider);
    final categoryMapAsync = ref.watch(transactionCategoryMapProvider);

    return categoryMapAsync.when(
      loading: () => const Scaffold(body: SkeletonLoader.transactions()),
      error: (err, _) => Scaffold(
        body: ErrorStateWidget(
          error: err,
          onRetry: () => ref.invalidate(transactionCategoryMapProvider),
        ),
      ),
      data: (categoriesMap) {
        // Filter by IDs if provided (audit fix flow)
        List transactions;
        if (widget.filterIds != null) {
          // Use full transaction list for filtered views
          final allTxns = ref.watch(transactionsProvider).valueOrNull ?? [];
          final filterSet = widget.filterIds!.toSet();
          transactions = allTxns.where((t) => filterSet.contains(t.id)).toList();
        } else {
          transactions = paginatedState.items;
        }

        if (transactions.isEmpty && !paginatedState.hasMore) {
          return EmptyStateWidget(
            icon: Icons.account_balance_wallet_outlined,
            title: "No transactions yet",
            description: "Start adding transactions to track your spending.",
            ctaLabel: "+ Add Transaction",
            onCtaTap: _onAddTransaction,
          );
        }

        final content = RefreshIndicator(
          onRefresh: _onRefresh,
          child: ListView.separated(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.listHorizontalPadding,
              vertical: AppSpacing.listHorizontalPadding,
            ),
            itemCount: transactions.length + (paginatedState.hasMore ? 1 : 0),
            separatorBuilder: (_, _) => SizedBox(height: AppSpacing.cardGap),
            itemBuilder: (context, index) {
              // Loading indicator at the end
              if (index >= transactions.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                      child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                );
              }

              final t = transactions[index];
              return TransactionTile(
                transaction: t,
                category: categoriesMap[t.categoryId],
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
                  if (result == true) _onRefresh();
                },
                onDelete: () async {
                  await ref.read(deleteTransactionProvider)(t.id);
                  _onRefresh();
                },
              );
            },
          ),
        );

        if (widget.isFullScreen) {
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.title ?? 'All Transactions'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.search_rounded),
                  tooltip: 'Search & Filter',
                  onPressed: () => Navigator.push(
                    context,
                    AppPageRoute(
                        builder: (_) => const SearchFilterScreen()),
                  ),
                ),
              ],
            ),
            floatingActionButtonLocation:
                FloatingActionButtonLocation.centerFloat,
            floatingActionButton: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
              child: PrimaryButton(
                label: 'Add Transaction',
                onPressed: _onAddTransaction,
              ),
            ),
            body: SafeArea(child: content),
          );
        }
        return content;
      },
    );
  }
}
