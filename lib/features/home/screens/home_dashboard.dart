import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../models/transaction.dart';
import '../../../screens/bank/account_list_screen.dart' show resolveAccountDisplayName;
import '../../../screens/expense/add_expense_screen.dart';
import '../../../screens/home/transactions_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/glass/spendx_section_header.dart';
import '../../../shared/widgets/glass/spendx_states.dart';
import '../../../shared/widgets/glass/spendx_transaction_tile.dart';
import '../../../utils/app_format.dart';
import '../../accounts/providers/account_providers.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../widgets/category_spending_card.dart';
import '../widgets/dashboard_budgets_card.dart';
import '../widgets/dashboard_goals_card.dart';
import '../widgets/dashboard_greeting_header.dart';
import '../widgets/monthly_pulse_card.dart';
import '../widgets/quick_actions_row.dart';
import '../widgets/safe_to_spend_card.dart';

/// Playful & Mindful Home Dashboard: Refined SpendX companion experience.
///
/// Implements clear financial language, vector-based visual identity,
/// an immersive Safe-to-Spend scene, Monthly Journey path, and a quiet,
/// date-grouped transaction stream.
class HomeDashboard extends ConsumerStatefulWidget {
  const HomeDashboard({super.key});

  @override
  ConsumerState<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends ConsumerState<HomeDashboard> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final paginatedState = ref.watch(paginatedTransactionsProvider);
    final categoryMapAsync = ref.watch(transactionCategoryMapProvider);
    final accountsAsync = ref.watch(accountsProvider);

    final categoriesMap = categoryMapAsync.valueOrNull ?? {};
    final accountsMap = {
      for (final a in (accountsAsync.valueOrNull ?? []))
        a.id: resolveAccountDisplayName(a.name),
    };

    final recentTxns = paginatedState.items.take(8).toList();
    final isLoading = paginatedState.items.isEmpty && paginatedState.hasMore;

    // Group recent transactions by calendar day
    final Map<String, List<Transaction>> groupedTxns = {};
    for (final t in recentTxns) {
      final header = _formatDateHeader(t.date);
      groupedTxns.putIfAbsent(header, () => []).add(t);
    }

    return RefreshIndicator(
      color: const Color(0xFF4F46E5),
      onRefresh: () async {
        ref.invalidate(transactionsProvider);
        ref.invalidate(transactionCategoryMapProvider);
        await ref.read(paginatedTransactionsProvider.notifier).refresh();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Mindful Atmospheric Header ───────────────────
          const SliverToBoxAdapter(child: DashboardGreetingHeader()),

          const SliverToBoxAdapter(child: SizedBox(height: 4)),

          // ── The Continuous Financial Journey Landscape ──
          const SliverToBoxAdapter(child: SafeToSpendCard()),

          const SliverToBoxAdapter(child: SizedBox(height: 2)),

          // ── Action Hub & Canvas Tracking Rhythm (+ Log activity, Spent, Received, Moved, Your Rhythm) ─
          const SliverToBoxAdapter(child: QuickActionsRow()),

          const SliverToBoxAdapter(child: SizedBox(height: 6)),

          // ── Recent Activity Header ───────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
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
          ),

          // ── Shimmer Skeleton Loader ──────────────────────
          if (isLoading)
            const SliverToBoxAdapter(
              child: SpendXLoadingState(count: 4, itemHeight: 64),
            ),

          // ── Mindful Empty State ──────────────────────────
          if (!isLoading && recentTxns.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
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
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0x254F46E5) : const Color(0xFFEEF2FF),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.receipt_long_outlined,
                          size: 22,
                          color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No transactions yet',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Transactions you log will appear in this unified ledger.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Quiet, Date-Grouped Transaction Stream ─────────
          if (!isLoading && recentTxns.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : const Color(0xFFECE5D8),
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
                    children: groupedTxns.entries.map((group) {
                      final headerText = group.key;
                      final txnsInGroup = group.value;

                      // Calculate total spend in this group
                      double groupSpend = 0;
                      for (final t in txnsInGroup) {
                        if (t.type == 'expense') {
                          groupSpend += t.amount;
                        }
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Quiet day header
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                            child: Row(
                              children: [
                                Text(
                                  headerText,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                    color: isDark
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF78716C),
                                  ),
                                ),
                                const Spacer(),
                                if (groupSpend > 0)
                                  Text(
                                    '−${AppFormat.currency(groupSpend)}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: isDark
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF78716C),
                                    ),
                                  ),
                              ],
                            ),
                          ),

                          // Transaction tiles
                          ...List.generate(txnsInGroup.length, (index) {
                            final t = txnsInGroup[index];
                            final isLastInGroup = index == txnsInGroup.length - 1;
                            return SpendXTransactionTile(
                              transaction: t,
                              category: categoriesMap[t.categoryId],
                              accountName: accountsMap[t.accountId],
                              showDivider: !isLastInGroup,
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
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 16)),

          // ── Monthly Cashflow (Income vs Expenses) ─────────
          const SliverToBoxAdapter(child: MonthlyPulseCard()),

          // ── Top Categories Breakdown ─────────────────────
          const SliverToBoxAdapter(child: CategorySpendingCard()),

          // ── Budgets Overview ─────────────────────────────
          const SliverToBoxAdapter(child: DashboardBudgetsCard()),

          // ── Savings Goals Progress ───────────────────────
          const SliverToBoxAdapter(child: DashboardGoalsCard()),

          // Generous bottom clearance above floating navigation bar
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);

    final diffDays = today.difference(target).inDays;
    if (diffDays == 0) return 'TODAY';
    if (diffDays == 1) return 'YESTERDAY';

    if (date.year == now.year) {
      return DateFormat('d MMMM').format(date).toUpperCase();
    }
    return DateFormat('d MMM yyyy').format(date).toUpperCase();
  }
}
