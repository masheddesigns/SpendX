import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/home_providers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../models/transaction.dart' as spx;
import '../../../widgets/transaction_tile.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../screens/home/transactions_screen.dart';

class TransactionsPreview extends ConsumerStatefulWidget {
  const TransactionsPreview({super.key});

  @override
  ConsumerState<TransactionsPreview> createState() => _TransactionsPreviewState();
}

class _TransactionsPreviewState extends ConsumerState<TransactionsPreview> {
  final GlobalKey<SliverAnimatedListState> _listKey = GlobalKey<SliverAnimatedListState>();
  List<spx.Transaction> _listItems = [];

  @override
  Widget build(BuildContext context) {
    final transactions = ref.watch(homeTransactionsProvider);
    final categoriesMap = ref.watch(dashboardCategoryMapProvider);

    // Sync state for animations
    ref.listen<List<spx.Transaction>>(homeTransactionsProvider, (prev, next) {
      final oldItems = _listItems;
      final nextItems = List<spx.Transaction>.from(next);
      final oldIds = oldItems.map((t) => t.id).toList();
      final newIds = nextItems.map((t) => t.id).toList();
      _listItems = nextItems;

      if (oldItems.length < next.length) {
        final insertedIndex = newIds.indexWhere((id) => !oldIds.contains(id));
        if (insertedIndex >= 0) {
          _listKey.currentState?.insertItem(
            insertedIndex,
            duration: const Duration(milliseconds: 400),
          );
        }
      } else if (oldItems.length > next.length) {
        final removedIndex = oldIds.indexWhere((id) => !newIds.contains(id));
        if (removedIndex >= 0 && removedIndex < oldItems.length) {
          final removedItem = oldItems[removedIndex];
          _listKey.currentState?.removeItem(
            removedIndex,
            (context, animation) => _buildItem(
              context,
              removedItem,
              categoriesMap,
              animation,
            ),
            duration: const Duration(milliseconds: 300),
          );
        }
      }
    });

    if (transactions.isEmpty) {
      return _buildEmptyState(context);
    }

    if (_listItems.isEmpty) _listItems = List.from(transactions);

    return _SliverAnimatedTransactionList(
      listKey: _listKey,
      items: _listItems,
      categoriesMap: categoriesMap,
    );
  }

  Widget _buildItem(BuildContext context, spx.Transaction t, Map<String, dynamic> categoriesMap, Animation<double> animation) {
    return SizeTransition(
      sizeFactor: animation,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.m,
          vertical: AppSpacing.xs,
        ),
        child: TransactionTile(
          transaction: t,
          category: categoriesMap[t.categoryId],
          onTap: () {},
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.m,
          vertical: AppSpacing.xxl,
        ),
        child: EmptyStateWidget(
          icon: Icons.account_balance_wallet_outlined,
          title: "No transactions yet",
          description: "Start adding transactions to track your spending.",
          ctaLabel: "+ Add Transaction",
          onCtaTap: () {},
        ),
      ),
    );
  }
}

class _SliverAnimatedTransactionList extends StatelessWidget {
  final GlobalKey<SliverAnimatedListState> listKey;
  final List<spx.Transaction> items;
  final Map<String, dynamic> categoriesMap;

  const _SliverAnimatedTransactionList({
    required this.listKey,
    required this.items,
    required this.categoriesMap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.xl, AppSpacing.m, AppSpacing.m),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Recent Transactions', style: AppTextStyles.titleMedium.copyWith(color: cs.onSurface)),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TransactionListScreen(isFullScreen: true)),
                    );
                  },
                  child: const Text('See All'),
                ),
              ],
            ),
          ),
        ),
        SliverAnimatedList(
          key: listKey,
          initialItemCount: items.length,
          itemBuilder: (context, index, animation) {
            final t = items[index];
            return SizeTransition(
              sizeFactor: animation,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m, vertical: AppSpacing.xs),
                child: TransactionTile(
                  transaction: t,
                  category: categoriesMap[t.categoryId],
                  onTap: () {},
                ),
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

// Helper to wrap multiple slivers if needed, or just return them sequentially
class MultiSliver extends StatelessWidget {
  final List<Widget> children;
  const MultiSliver({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(slivers: children);
  }
}
