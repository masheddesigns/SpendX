import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../screens/expense/add_expense_screen.dart';
import '../../../screens/home/transactions_screen.dart';
import '../../../screens/review/review_queue_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/spendx_glass.dart';
import '../../accounts/providers/account_providers.dart';
import '../../review_queue/providers/review_providers.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../wrapped/widgets/wrapped_story_bubbles.dart';
import '../widgets/quick_actions_row.dart';
import '../widgets/safe_to_spend_card.dart';

/// Decision-First Home Dashboard with Layered Liquid Glass Materials.
///
/// Implements Sections 7 & 8 of C15-A-R1:
/// - Recomposed around layered depth rather than disjoint cards
/// - Environmental background shines through translucent layers
/// - Safe-to-Spend Hero as elevated decision surface
/// - Floating interactive Quick Actions
/// - Grouped Translucent Transaction Container with single blur surface
/// - Direct canvas typography for headers and metadata
class HomeDashboard extends ConsumerStatefulWidget {
  const HomeDashboard({super.key});

  @override
  ConsumerState<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends ConsumerState<HomeDashboard> {
  @override
  Widget build(BuildContext context) {
    final paginatedState = ref.watch(paginatedTransactionsProvider);
    final categoryMapAsync = ref.watch(transactionCategoryMapProvider);
    final accountsAsync = ref.watch(accountsProvider);
    final reviewCountAsync = ref.watch(reviewQueueCountProvider);

    final categoriesMap = categoryMapAsync.valueOrNull ?? {};
    final accountsMap = {
      for (final a in (accountsAsync.valueOrNull ?? [])) a.id: a.name,
    };

    final recentTxns = paginatedState.items.take(8).toList();
    final isLoading = paginatedState.items.isEmpty && paginatedState.hasMore;
    final pendingReviewCount = reviewCountAsync.valueOrNull ?? 0;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(transactionsProvider);
        ref.invalidate(transactionCategoryMapProvider);
        ref.invalidate(reviewQueueCountProvider);
        await ref.read(paginatedTransactionsProvider.notifier).refresh();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Compact Wrapped Story Bubbles (Canvas Direct) ──
          const SliverToBoxAdapter(child: WrappedStoryBubbles()),

          // ── Primary Decision Hero: Safe-to-Spend ─────────
          const SliverToBoxAdapter(child: SafeToSpendCard()),

          // ── Staged Review Banner (Conditional) ───────────
          if (pendingReviewCount > 0)
            SliverToBoxAdapter(
              child: SpendXReviewBanner(
                count: pendingReviewCount,
                onTap: () => Navigator.push(
                  context,
                  AppPageRoute(builder: (_) => const ReviewQueueScreen()),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 6)),

          // ── Floating Quick Actions Row ───────────────────
          const SliverToBoxAdapter(child: QuickActionsRow()),

          const SliverToBoxAdapter(child: SizedBox(height: 14)),

          // ── Recent Activity Section Header (Canvas Direct)
          SliverToBoxAdapter(
            child: SpendXSectionHeader(
              title: 'Recent Activity',
              actionLabel: recentTxns.isNotEmpty ? 'View All' : null,
              onAction: () => Navigator.push(
                context,
                AppPageRoute(
                  builder: (_) => const TransactionListScreen(isFullScreen: true),
                ),
              ),
            ),
          ),

          // ── Shimmer Skeleton Loader ──────────────────────
          if (isLoading)
            const SliverToBoxAdapter(
              child: SpendXLoadingState(count: 4, itemHeight: 64),
            ),

          // ── Clean Empty State ─────────────────────────────
          if (!isLoading && recentTxns.isEmpty)
            SliverToBoxAdapter(
              child: SpendXEmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No transactions yet',
                subtitle: 'Tap Expense or Income above to start tracking your finances.',
                actionLabel: 'Add Expense',
                onAction: () => Navigator.push(
                  context,
                  AppPageRoute(
                    builder: (_) => const AddExpenseScreen(initialType: 'expense'),
                  ),
                ),
              ),
            ),

          // ── Grouped Liquid Glass Transaction Container ───
          if (!isLoading && recentTxns.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SpendXGlassSurface(
                  level: SpendXGlassLevel.base,
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: List.generate(recentTxns.length, (index) {
                      final t = recentTxns[index];
                      final isLast = index == recentTxns.length - 1;
                      return SpendXTransactionTile(
                        transaction: t,
                        category: categoriesMap[t.categoryId],
                        accountName: accountsMap[t.accountId],
                        showDivider: !isLast,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => AddExpenseScreen(
                                initialType: t.type,
                                existingTransaction: t,
                              ),
                            ),
                          );
                          await ref
                              .read(paginatedTransactionsProvider.notifier)
                              .refresh();
                        },
                      );
                    }),
                  ),
                ),
              ),
            ),

          // Generous bottom clearance above floating glass navigation bar
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }
}
