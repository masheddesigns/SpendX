import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../screens/expense/add_expense_screen.dart';
import '../../../screens/home/transactions_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../../../widgets/transaction_tile.dart';
import '../../../theme/app_theme.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../wrapped/widgets/wrapped_story_bubbles.dart';
import '../widgets/summary_section.dart';
import '../widgets/system_status_strip.dart';
import '../widgets/inline_review_strip.dart';

/// Home tab — clean dashboard with breathing room.
///
/// Layout:
///   Wrapped (conditional)
///   ↓ 24px
///   Summary (dominant)
///   ↓ 12px
///   Status (thin, secondary)
///   ↓ 12px
///   Review (conditional)
///   ↓ 24px
///   Transactions
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
    final categoriesMap = categoryMapAsync.valueOrNull ?? {};
    final recentTxns = paginatedState.items.take(10).toList();
    final isLoading = paginatedState.items.isEmpty && paginatedState.hasMore;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(transactionsProvider);
        ref.invalidate(transactionCategoryMapProvider);
        await ref.read(paginatedTransactionsProvider.notifier).refresh();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Wrapped Story Bubbles ────────────────────────
          const SliverToBoxAdapter(child: WrappedStoryBubbles()),

          // ── Financial Summary (dominant) ─────────────────
          const SliverToBoxAdapter(child: SummarySection()),

          // ── Breathing space ─────────────────────────────
          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // ── System Status (single priority, thin) ───────
          const SliverToBoxAdapter(child: SystemStatusStrip()),

          // ── Breathing space ─────────────────────────────
          const SliverToBoxAdapter(child: SizedBox(height: 4)),

          // ── Inline Review (conditional) ──────────────────
          const SliverToBoxAdapter(child: InlineReviewStrip()),

          // ── Section break before transactions ───────────
          const SliverToBoxAdapter(child: SizedBox(height: 16)),

          // ── Recent Transactions header ────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  Text(
                    'Recent Transactions',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      AppPageRoute(
                        builder: (_) =>
                            const TransactionListScreen(isFullScreen: true),
                      ),
                    ),
                    child: const Text('View All'),
                  ),
                ],
              ),
            ),
          ),

          // ── Skeleton loader (while loading) ──────────────
          if (isLoading)
            const SliverToBoxAdapter(child: SkeletonLoader.transactions()),

          // ── Empty state ──────────────────────────────────
          if (!isLoading && recentTxns.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 48,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No transactions yet',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Tap + to add your first one',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Transaction List ──────────────────────────────
          if (!isLoading && recentTxns.isNotEmpty)
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final t = recentTxns[index];
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.listHorizontalPadding,
                    vertical: AppSpacing.cardGap / 2,
                  ),
                  child: TransactionTile(
                    transaction: t,
                    category: categoriesMap[t.categoryId],
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
                  ),
                );
              }, childCount: recentTxns.length),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }
}
