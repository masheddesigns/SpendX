import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/providers.dart' as app_data;
import '../models/credit_card.dart';
import '../models/credit_transaction.dart';
import '../models/credit_emi.dart';
import '../services/credit_intelligence_service.dart';
import '../shared/theme/app_theme.dart';
import '../shared/widgets/empty_state_widget.dart';
import '../shared/widgets/skeleton_loader.dart';
import '../shared/widgets/error_state_widget.dart';
import '../shared/widgets/undo_snackbar_listener.dart';
import '../utils/app_format.dart';
import 'credit_card/add_credit_card_screen.dart';
import 'credit_card/add_credit_transaction_screen.dart';
import 'credit_card/pay_credit_card_screen.dart';
import 'credit_card/credit_emi_detail_screen.dart';
import '../utils/text_formatter.dart';
import '../features/liabilities/providers/liabilities_providers.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/app_tap_scale.dart';

class CreditCardScreen extends ConsumerStatefulWidget {
  const CreditCardScreen({super.key});

  @override
  ConsumerState<CreditCardScreen> createState() => _CreditCardScreenState();
}

class _CreditCardScreenState extends ConsumerState<CreditCardScreen> {
  int _selectedCardIndex = 0;

  void _invalidateAll() {
    ref.invalidate(creditCardsProvider);
    ref.invalidate(liabilitiesSummaryProvider);
    // Families will be invalidated by key or automatically if they depend on creditCardsProvider
  }

  @override
  Widget build(BuildContext context) {
    final cardsAsync = ref.watch(creditCardsProvider);

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is CreditCard,
      onUndone: (_) => _invalidateAll(),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Credit Cards')),
      body: cardsAsync.when(
        loading: () => const SkeletonLoader.transactions(),
        error: (err, _) => ErrorStateWidget(
          error: err,
          onRetry: () => ref.invalidate(creditCardsProvider),
        ),
        data: (cards) {
          if (cards.isEmpty) {
            return EmptyStateWidget(
              icon: Icons.credit_card_off_rounded,
              title: 'No credit cards yet',
              description:
                  'Add your credit cards to track outstandings, EMIs, and spending intelligence.',
              ctaLabel: 'Add Credit Card',
              onCtaTap: _navigateToAddCard,
            );
          }

          if (_selectedCardIndex >= cards.length) {
            _selectedCardIndex = 0;
          }

          final selectedCard = cards[_selectedCardIndex];
          final outstandingAsync = ref.watch(
            creditOutstandingProvider(selectedCard.id),
          );
          final recentTxnsAsync = ref.watch(
            creditRecentTransactionsProvider(selectedCard.id),
          );
          final activeEmisAsync = ref.watch(
            creditActiveEmisProvider(selectedCard.id),
          );
          final intelligenceAsync = ref.watch(
            creditIntelligenceProvider(selectedCard),
          );

          return RefreshIndicator(
            onRefresh: () async {
              _invalidateAll();
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.listHorizontalPadding),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildCardSelector(cards),
                        AppSpacing.sectionSpacer,
                        outstandingAsync.when(
                          data: (outstanding) => _buildSummaryCard(
                            selectedCard,
                            outstanding,
                            intelligenceAsync.valueOrNull,
                          ),
                          loading: () => const SkeletonLoader.summary(),
                          error: (err, _) => Text('$err'),
                        ),
                        AppSpacing.sectionSpacer,
                        _buildActionGrid(selectedCard),
                        AppSpacing.sectionSpacer,
                        _buildIntelligenceSection(
                          intelligenceAsync.valueOrNull,
                        ),
                        AppSpacing.sectionSpacer,
                        _buildEMIsSection(activeEmisAsync.valueOrNull ?? []),
                        AppSpacing.sectionSpacer,
                        _buildRecentTransactionsHeader(selectedCard),
                      ],
                    ),
                  ),
                ),
                recentTxnsAsync.when(
                  data: (txns) => _buildRecentTransactionsList(txns),
                  loading: () => const SliverToBoxAdapter(
                    child: SkeletonLoader.transactions(),
                  ),
                  error: (err, _) => SliverToBoxAdapter(
                    child: Text('$err'),
                  ),
                ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
              ],
            ),
          );
        },
      ),
      floatingActionButton: cardsAsync.valueOrNull?.isEmpty ?? true
          ? FloatingActionButton.extended(
              onPressed: _navigateToAddCard,
              icon: const Icon(Icons.add),
              label: const Text('Add Card'),
            )
          : null,
    );
  }


  Widget _buildCardSelector(List<CreditCard> cards) {
    return SizedBox(
      height: 160,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length + 1,
        itemBuilder: (context, index) {
          if (index == cards.length) {
            return _buildAddCardButton();
          }

          final card = cards[index];
          final isSelected = _selectedCardIndex == index;

          return AppTapScale(
            onTap: () => setState(() => _selectedCardIndex = index),
            child: Container(
              width: 280,
              margin: const EdgeInsets.only(right: AppSpacing.md),
              padding: AppSpacing.cardPadding,
              decoration: BoxDecoration(
                gradient: isSelected
                    ? LinearGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary,
                          Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.7),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: isSelected
                    ? null
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
                border: isSelected
                    ? null
                    : Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                        width: 1,
                      ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        card.bank,
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white70
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Icon(
                        Icons.credit_card_rounded,
                        color: isSelected
                            ? Colors.white70
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    card.name,
                    style: TextStyle(
                      color: isSelected
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '•••• •••• •••• ${card.last4}',
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white.withValues(alpha: 0.8)
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 14,
                          letterSpacing: 1.2,
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (isSelected)
                        IconButton(
                          icon: const Icon(
                            Icons.edit_rounded,
                            color: Colors.white70,
                            size: 18,
                          ),
                          onPressed: () => _navigateToEditCard(card),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAddCardButton() {
    return AppTapScale(
      onTap: _navigateToAddCard,
      child: Container(
        width: 100,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            style: BorderStyle.solid,
          ),
        ),
        child: const Icon(Icons.add_rounded, size: 32),
      ),
    );
  }

  Widget _buildSummaryCard(
    CreditCard card,
    double outstanding,
    CreditIntelligenceData? intel,
  ) {
    final cs = Theme.of(context).colorScheme;
    final hasLimit = card.creditLimit > 0;
    final usagePercent = hasLimit
        ? (outstanding / card.creditLimit).clamp(0.0, 1.0)
        : 0.0;
    final isUsageHigh = hasLimit && usagePercent > 0.3;

    return Container(
      padding: AppSpacing.cardPadding,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Outstanding',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppFormat.currency(outstanding),
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: outstanding > 0 ? cs.error : cs.onSurface,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    hasLimit ? 'Usage' : 'Limit',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  hasLimit
                      ? Text(
                          '${(usagePercent * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isUsageHigh ? cs.error : cs.primary,
                          ),
                        )
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Not set',
                            style: TextStyle(
                              color: Color(0xFFF59E0B),
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                ],
              ),
            ],
          ),
          if (hasLimit) ...[
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: usagePercent,
                minHeight: 8,
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isUsageHigh ? cs.error : cs.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Limit: ${AppFormat.currency(card.creditLimit)}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                Text(
                  'Available: ${AppFormat.currency(card.creditLimit - outstanding)}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ],
          if (!hasLimit) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _navigateToEditCard(card),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 14,
                      color: const Color(0xFFF59E0B)),
                  const SizedBox(width: 6),
                  Text(
                    'Set your credit limit to track usage',
                    style: TextStyle(
                      color: const Color(0xFFF59E0B),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right_rounded, size: 16,
                      color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ],
          if (intel != null && intel.upcomingDueDays != null) ...[
            const Divider(height: 32),
            Row(
              children: [
                Icon(
                  Icons.event_note_rounded,
                  size: 20,
                  color: (intel.upcomingDueDays ?? 0) <= 5
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    (intel.upcomingDueDays ?? 0) <= 0
                        ? 'Due Today!'
                        : 'Due in ${intel.upcomingDueDays} days',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: (intel.upcomingDueDays ?? 0) <= 5
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _navigateToPayments(card),
                  child: const Text('Pay Now'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionGrid(CreditCard card) {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            'Add Expense',
            Icons.shopping_bag_outlined,
            Theme.of(context).colorScheme.primary,
            () => _navigateToAddTransaction(card),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: _buildActionButton(
            'Pay Card',
            Icons.account_balance_wallet_outlined,
            Theme.of(context).colorScheme.secondary,
            () => _navigateToPayments(card),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(fontWeight: FontWeight.w600, color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntelligenceSection(CreditIntelligenceData? intel) {
    if (intel == null) return const SizedBox.shrink();

    // Only build chips that have data — hide entire section if empty
    final chips = <Widget>[];
    if (intel.unbilledAmount > 0) {
      chips.add(_buildIntelChip(
        'Unbilled: ${AppFormat.currency(intel.unbilledAmount)}',
        Icons.history_rounded,
        Colors.orange,
      ));
    }
    if (intel.isOverlimit) {
      chips.add(_buildIntelChip(
        'Overlimit!',
        Icons.warning_rounded,
        Theme.of(context).colorScheme.error,
      ));
    }
    // Add advice chips
    for (final advice in intel.advice.take(2)) {
      chips.add(_buildIntelChip(
        advice,
        Icons.lightbulb_outline_rounded,
        Theme.of(context).colorScheme.primary,
      ));
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Insights',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: chips,
        ),
      ],
    );
  }

  Widget _buildIntelChip(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEMIsSection(List<CreditEMI> emis) {
    if (emis.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Active EMIs',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              '${emis.length} Total',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        ...emis.map((emi) => _buildEMICard(emi)),
      ],
    );
  }

  Widget _buildEMICard(CreditEMI emi) {
    final progress = (emi.totalMonths - emi.remainingMonths) / emi.totalMonths;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            AppPageRoute(
              builder: (context) => CreditEmiDetailScreen(emi: emi),
            ),
          ).then((_) => _invalidateAll());
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: AppSpacing.cardPadding,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          emi.notes ?? 'EMI Purchase',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '${AppFormat.currency(emi.installmentAmount)} / month',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${emi.remainingMonths} left',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentTransactionsHeader(CreditCard card) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Recent Activity',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        TextButton(
          onPressed: () {
            // Navigate to all transactions filtered by this card
          },
          child: const Text('See All'),
        ),
      ],
    );
  }

  Widget _buildRecentTransactionsList(List<CreditTransaction> txns) {
    if (txns.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('No transactions yet'),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final tx = txns[index];
        final isCredit = tx.type == 'credit';

        return ListTile(
          onTap: () async {
            // Convert CreditTransaction to LedgerTransaction for detail screen if needed
            // or navigate to TransactionDetailScreen if it's a regular transaction
          },
          leading: CircleAvatar(
            backgroundColor: isCredit
                ? Colors.green.withValues(alpha: 0.1)
                : Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
            child: Icon(
              isCredit
                  ? Icons.arrow_downward_rounded
                  : Icons.shopping_cart_outlined,
              color: isCredit
                  ? Colors.green
                  : Theme.of(context).colorScheme.error,
              size: 20,
            ),
          ),
          title: Text(
            tx.note?.isNotEmpty == true
                ? tx.note!
                : TextFormatter.toSmartTitleCase(tx.category),
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(DateFormat('dd MMM, hh:mm a').format(tx.date)),
          trailing: Text(
            '${isCredit ? "+" : "-"}${AppFormat.currency(tx.amount)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isCredit
                  ? Colors.green
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        );
      }, childCount: txns.length),
    );
  }

  // --- Navigation Helpers ---

  void _navigateToAddCard() {
    Navigator.push(
      context,
      AppPageRoute(builder: (context) => const AddCreditCardScreen()),
    ).then((result) {
      if (result == true) _invalidateAll();
    });
  }

  void _navigateToEditCard(CreditCard card) {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (context) => AddCreditCardScreen(existingCard: card),
      ),
    ).then((result) async {
      if (result == true) {
        _invalidateAll();
        return;
      }

      if (result == CreditCardFormAction.deleted) {
        await ref.read(app_data.cardsProvider.notifier).remove(card.id);
        _invalidateAll();
      }
    });
  }

  void _navigateToAddTransaction(CreditCard card) {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (context) => AddCreditTransactionScreen(card: card),
      ),
    ).then((result) {
      if (result == true) _invalidateAll();
    });
  }

  void _navigateToPayments(CreditCard card) {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (context) => PayCreditCardScreen(
          card: card,
          outstanding:
              ref.read(creditOutstandingProvider(card.id)).valueOrNull ??
              card.outstanding,
        ),
      ),
    ).then((result) {
      if (result == true) _invalidateAll();
    });
  }
}
