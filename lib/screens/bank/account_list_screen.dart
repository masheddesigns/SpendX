import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/providers.dart' as app_data;
import '../../features/accounts/providers/account_providers.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/loan.dart';
import '../../services/haptic_service.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/app_tap_scale.dart';
import '../../shared/widgets/spendx_glass.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../credit_card/add_credit_card_screen.dart';
import '../credit_card/pay_credit_card_screen.dart';
import '../credit_card_screen.dart';
import '../lending/lending_screen.dart';
import '../loans/loans_screen.dart';
import '../net_worth_screen.dart';
import 'account_detail_screen.dart';
import 'add_bank_account_screen.dart';
import '../../services/entity_consolidation_service.dart';
import '../../services/data_change_bus.dart';
import '../../services/live_sms_service.dart';
import '../../shared/widgets/custom_snackbar.dart';

/// Cleanly maps raw database keys or prefix artifacts (e.g. `Asset acc_bank_default`)
/// to clear, user-facing account labels without mutating underlying database rows
/// or altering any user-entered account names.
String resolveAccountDisplayName(String rawName) {
  final trimmed = rawName.trim();
  if (trimmed == 'acc_bank_default' || trimmed == 'Asset acc_bank_default') {
    return 'Primary Operating Account';
  }
  if (trimmed == 'acc_cash_default' || trimmed == 'Asset acc_cash_default') {
    return 'Cash';
  }
  if (trimmed == 'sys_suspense_transfer' ||
      trimmed.startsWith('sys_suspense') ||
      trimmed.startsWith('sys_')) {
    return 'Unlinked Account';
  }
  // Match only auto-generated system keys like "Asset acc_123" or "acc_123"
  final generatedKeyPattern = RegExp(r'^(?:Asset\s+)?acc_([a-zA-Z0-9_\-]+)$');
  final match = generatedKeyPattern.firstMatch(trimmed);
  if (match != null) {
    final sub = match.group(1)!;
    if (sub.isNotEmpty) {
      if (sub == 'cash_default') return 'Cash';
      if (sub == 'bank_default') return 'Primary Operating Account';
      return '${sub[0].toUpperCase()}${sub.substring(1)} Account';
    }
    return 'Operating Account';
  }
  return rawName;
}

/// SpendX Balance Sheet & Financial Instruments Surface (Accounts Screen).
///
/// Implements SpendX Visual Language Rulebook:
/// - Replaces generic white cards with clear instrument differentiation
/// - Solvency Horizon Card: Net Worth, Assets (never green if negative), Liabilities
/// - Restrained Action Hub: + Account, + Card, Peer Lending
/// - What You Own: High-clarity Bank Account ledger rows with type pills & overdraft badges
/// - What You Owe: Visual Credit Card instruments with utilization runway & payment countdown
/// - Obligations: Consolidated Peer Lending & Bank Loan amortization progress tracks
/// - Preserves 100% canonical double-entry accounting invariants & providers
class AccountListScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;

  const AccountListScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<AccountListScreen> createState() => _AccountListScreenState();
}

class _AccountListScreenState extends ConsumerState<AccountListScreen> {
  VoidCallback? _busListener;

  @override
  void initState() {
    super.initState();
    _busListener = () {
      if (mounted) {
        ref.invalidate(accountsProvider);
        ref.invalidate(creditCardsProvider);
        ref.invalidate(loansProvider);
        ref.invalidate(app_data.cardsProvider);
        ref.invalidate(app_data.netWorthSummaryProvider);
      }
    };
    DataChangeBus.instance.addListener(_busListener!);
  }

  @override
  void dispose() {
    if (_busListener != null) {
      DataChangeBus.instance.removeListener(_busListener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    final cardsAsync = ref.watch(creditCardsProvider);
    final loansAsync = ref.watch(loansProvider);

    if (accountsAsync.isLoading ||
        cardsAsync.isLoading ||
        loansAsync.isLoading) {
      return const Center(child: SpendXLoadingState(count: 5, itemHeight: 70));
    }

    if (accountsAsync.hasError) {
      return Center(
        child: SpendXErrorState(
          message: accountsAsync.error.toString(),
          onRetry: () => ref.invalidate(accountsProvider),
        ),
      );
    }
    if (cardsAsync.hasError) {
      return Center(
        child: SpendXErrorState(
          message: cardsAsync.error.toString(),
          onRetry: () => ref.invalidate(creditCardsProvider),
        ),
      );
    }
    if (loansAsync.hasError) {
      return Center(
        child: SpendXErrorState(
          message: loansAsync.error.toString(),
          onRetry: () => ref.invalidate(loansProvider),
        ),
      );
    }

    final accounts = accountsAsync.value ?? [];
    final cards = cardsAsync.value ?? [];
    final loans = loansAsync.value ?? [];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget content = RefreshIndicator(
      onRefresh: () async {
        await EntityConsolidationService.instance.consolidate();
        await LiveSmsService.instance.syncUpcomingObligationsFromInbox();
        ref.invalidate(accountsProvider);
        ref.invalidate(creditCardsProvider);
        ref.invalidate(loansProvider);
        ref.invalidate(app_data.netWorthSummaryProvider);
        app_data.invalidateAllFinancialProviders(ref);
      },
      color: AppTheme.primaryBlue,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Subtitle / Balance Sheet Horizon Orientation ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Your financial balance sheet',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Financial Position Hero (Solvency Horizon) ────
          SliverToBoxAdapter(
            child: _NetPositionHorizonCard(
              accounts: accounts,
              cards: cards,
              loans: loans,
              isDark: isDark,
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          // ── Action Hub (Restrained Quick Controls) ────────
          SliverToBoxAdapter(
            child: _AccountsActionHub(
              isDark: isDark,
              onAddAccount: () => _openAddAccount(context, ref),
              onAddCard: () => _openAddCreditCard(context, ref),
              onOpenLending: () => Navigator.push(
                context,
                AppPageRoute(builder: (_) => const LendingScreen()),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // ── Onboarding State if Completely Empty ──────────
          if (accounts.isEmpty && cards.isEmpty && loans.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: _EmptyStateCard(
                  isDark: isDark,
                  onAddAccount: () => _openAddAccount(context, ref),
                  onAddCard: () => _openAddCreditCard(context, ref),
                ),
              ),
            ),

          // ── Section 1: What You Own (Bank Accounts & Liquid Cash)
          if (accounts.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SpendXSectionHeader(
                title: 'Bank Accounts & Liquid Cash',
                count: accounts.length,
                actionLabel: '+ Add',
                onAction: () => _openAddAccount(context, ref),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Theme.of(context).colorScheme.outline,
                      width: 0.9,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Colors.black.withValues(alpha: 0.25)
                            : Theme.of(
                                context,
                              ).colorScheme.shadow.withValues(alpha: 0.03),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: List.generate(accounts.length, (index) {
                      final acc = accounts[index];
                      final isLast = index == accounts.length - 1;
                      return _BankAccountRow(
                        account: acc,
                        showDivider: !isLast,
                        isDark: isDark,
                        onTap: () {
                          HapticService.instance.tap();
                          Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => AccountDetailScreen(account: acc),
                            ),
                          );
                        },
                        onOptionsTap: () =>
                            _showAccountOptionsSheet(context, ref, acc),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ],

          // ── Section 2: What You Owe (Revolving Credit Cards)
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: SpendXSectionHeader(
              title: 'Credit Cards',
              count: cards.isNotEmpty ? cards.length : null,
              actionLabel: '+ Add Card',
              onAction: () => _openAddCreditCard(context, ref),
            ),
          ),
          if (cards.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: List.generate(cards.length, (index) {
                    final card = cards[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == cards.length - 1 ? 0 : 12,
                      ),
                      child: _CreditCardInstrument(
                        card: card,
                        isDark: isDark,
                        onTap: () {
                          HapticService.instance.tap();
                          Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) =>
                                  CreditCardScreen(initialCardId: card.id),
                            ),
                          );
                        },
                        onPayTap: () {
                          HapticService.instance.tap();
                          Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => PayCreditCardScreen(
                                card: card,
                                outstanding: card.outstanding,
                              ),
                            ),
                          );
                        },
                        onOptionsTap: () =>
                            _showCardOptionsSheet(context, ref, card),
                      ),
                    );
                  }),
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: _EmptyCardPlaceholder(
                  isDark: isDark,
                  onAddCard: () => _openAddCreditCard(context, ref),
                ),
              ),
            ),

          // ── Section 3: Obligations (Loans & Lending) ───────
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: SpendXSectionHeader(
              title: 'Loans & Obligations',
              actionLabel: loans.isNotEmpty ? 'Manage All' : null,
              onAction: () => Navigator.push(
                context,
                AppPageRoute(builder: (_) => const LoansScreen()),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Theme.of(context).colorScheme.outline,
                    width: 0.9,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.25)
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
                  children: [
                    // 1. Peer Lending & Borrowing Link
                    _NavigationLinkRow(
                      icon: Icons.handshake_outlined,
                      iconColor: Theme.of(context).colorScheme.primary,
                      title: 'Lending & Borrowing',
                      subtitle:
                          'Track money you lent to others & personal debts',
                      showDivider: loans.isNotEmpty,
                      isDark: isDark,
                      onTap: () => Navigator.push(
                        context,
                        AppPageRoute(builder: (_) => const LendingScreen()),
                      ),
                    ),

                    // 2. Active Bank Loans & EMIs
                    if (loans.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Row(
                          children: [
                            Text(
                              'BANK LOANS & EMIS',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${loans.length} active',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...List.generate(loans.length, (index) {
                        final loan = loans[index];
                        final isLast = index == loans.length - 1;
                        final remaining = (loan.total - loan.paidAmount).clamp(
                          0.0,
                          double.infinity,
                        );
                        return _LoanAmortizationRow(
                          loan: loan,
                          remaining: remaining,
                          showDivider: !isLast,
                          isDark: isDark,
                          onTap: () => Navigator.push(
                            context,
                            AppPageRoute(builder: (_) => const LoansScreen()),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // Tuned bottom clearance matching navigation bar & safe area insets
          SliverToBoxAdapter(
            child: SizedBox(
              height:
                  (MediaQuery.paddingOf(context).bottom > 0
                      ? MediaQuery.paddingOf(context).bottom + 72.0
                      : 80.0) +
                  16.0,
            ),
          ),
        ],
      ),
    );

    if (!widget.isEmbedded) {
      return SpendXScaffold(
        extendBody: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            'Accounts',
            style: AppTextStyles.heading.copyWith(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.auto_fix_high_rounded),
              tooltip: 'Consolidate & Deduplicate',
              onPressed: () async {
                HapticService.instance.medium();
                final count = await EntityConsolidationService.instance
                    .consolidate();
                ref.invalidate(accountsProvider);
                ref.invalidate(creditCardsProvider);
                ref.invalidate(loansProvider);
                ref.invalidate(app_data.netWorthSummaryProvider);
                app_data.invalidateAllFinancialProviders(ref);
                if (context.mounted) {
                  CustomSnackBar.show(
                    context,
                    message: count > 0
                        ? 'Cleaned & consolidated $count duplicate items.'
                        : 'All accounts and cards are clean and synced.',
                  );
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: 'Add Account',
              onPressed: () => _openAddAccount(context, ref),
            ),
          ],
        ),
        body: content,
      );
    }

    return content;
  }

  // ── Actions & Navigation Handlers ────────────────────────────

  Future<void> _openAddAccount(BuildContext context, WidgetRef ref) async {
    HapticService.instance.tap();
    final result = await Navigator.push(
      context,
      AppPageRoute(builder: (_) => const AddBankAccountScreen()),
    );
    if (result == true) {
      ref.invalidate(accountsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }

  Future<void> _openEditAccount(
    BuildContext context,
    WidgetRef ref,
    BankAccount account,
  ) async {
    final result = await Navigator.push(
      context,
      AppPageRoute(builder: (_) => AddBankAccountScreen(existing: account)),
    );
    if (result == true) {
      ref.invalidate(accountsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }

  Future<void> _openAddCreditCard(BuildContext context, WidgetRef ref) async {
    HapticService.instance.tap();
    final result = await Navigator.push(
      context,
      AppPageRoute(builder: (_) => const AddCreditCardScreen()),
    );
    if (result == true) {
      ref.invalidate(creditCardsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }

  Future<void> _openEditCreditCard(
    BuildContext context,
    WidgetRef ref,
    CreditCard card,
  ) async {
    final result = await Navigator.push(
      context,
      AppPageRoute(builder: (_) => AddCreditCardScreen(existingCard: card)),
    );
    if (result == true) {
      ref.invalidate(creditCardsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
      return;
    }
    if (result == CreditCardFormAction.deleted) {
      await ref.read(app_data.cardsProvider.notifier).remove(card.id);
      ref.invalidate(creditCardsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }

  void _showAccountOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    BankAccount account,
  ) {
    HapticService.instance.tap();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                resolveAccountDisplayName(account.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${account.bank.isNotEmpty ? '${account.bank} • ' : ''}${account.accountType.replaceAll('_', ' ').toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.receipt_long_rounded),
                title: const Text('View Account Activity'),
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  HapticService.instance.tap();
                  Navigator.push(
                    context,
                    AppPageRoute(
                      builder: (_) => AccountDetailScreen(account: account),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit Account'),
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  _openEditAccount(context, ref, account);
                },
              ),
              ListTile(
                leading: const Icon(Icons.credit_card_rounded),
                title: const Text('Convert to Credit Card'),
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  _convertAccountToCard(context, ref, account);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppTheme.semanticExpense,
                ),
                title: const Text(
                  'Delete Account',
                  style: TextStyle(color: AppTheme.semanticExpense),
                ),
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteAccount(context, ref, account);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCardOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    CreditCard card,
  ) {
    HapticService.instance.tap();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                card.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${card.bank} • •••• ${card.last4}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Icon(
                  Icons.payment_rounded,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                title: const Text(
                  'Pay Card / Record Repayment',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                contentPadding: EdgeInsets.zero,
                onTap: () async {
                  Navigator.pop(ctx);
                  final res = await Navigator.push(
                    context,
                    AppPageRoute(
                      builder: (_) => PayCreditCardScreen(
                        card: card,
                        outstanding:
                            ref
                                .read(creditOutstandingProvider(card.id))
                                .valueOrNull ??
                            card.outstanding,
                      ),
                    ),
                  );
                  if (res == true) {
                    ref.invalidate(creditCardsProvider);
                    ref.invalidate(accountsProvider);
                    ref.invalidate(liabilitiesSummaryProvider);
                    app_data.invalidateAllFinancialProviders(ref);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.credit_card_rounded),
                title: const Text('Card Details & Activity'),
                contentPadding: EdgeInsets.zero,
                onTap: () async {
                  Navigator.pop(ctx);
                  await Navigator.push(
                    context,
                    AppPageRoute(
                      builder: (_) => CreditCardScreen(initialCardId: card.id),
                    ),
                  );
                  ref.invalidate(creditCardsProvider);
                  ref.invalidate(accountsProvider);
                  ref.invalidate(liabilitiesSummaryProvider);
                  app_data.invalidateAllFinancialProviders(ref);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit Card'),
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  _openEditCreditCard(context, ref, card);
                },
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_outlined),
                title: const Text('Convert to Bank Account'),
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  _convertCardToAccount(context, ref, card);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppTheme.semanticExpense,
                ),
                title: const Text(
                  'Delete Card',
                  style: TextStyle(color: AppTheme.semanticExpense),
                ),
                contentPadding: EdgeInsets.zero,
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteCard(context, ref, card);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _convertAccountToCard(
    BuildContext context,
    WidgetRef ref,
    BankAccount account,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convert to Credit Card?'),
        content: Text(
          'Convert "${resolveAccountDisplayName(account.name)}" from a bank account to a credit card? You can edit the card details after conversion.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Convert'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final repo = ref.read(accountRepoProvider);
    final newCardId = await repo.convertAccountToCard(account);
    ref.invalidate(accountsProvider);
    ref.invalidate(creditCardsProvider);
    ref.invalidate(app_data.netWorthSummaryProvider);
    if (!context.mounted) return;

    final cards = await repo.getCards();
    final newCard = cards.where((c) => c.id == newCardId).firstOrNull;
    if (newCard != null && context.mounted) {
      await Navigator.push(
        context,
        AppPageRoute(
          builder: (_) => AddCreditCardScreen(existingCard: newCard),
        ),
      );
      ref.invalidate(creditCardsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }

  Future<void> _convertCardToAccount(
    BuildContext context,
    WidgetRef ref,
    CreditCard card,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convert to Bank Account?'),
        content: Text(
          'Convert "${card.name}" from a credit card to a bank account?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Convert'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final repo = ref.read(accountRepoProvider);
    final newAccountId = await repo.convertCardToAccount(card);
    ref.invalidate(accountsProvider);
    ref.invalidate(creditCardsProvider);
    ref.invalidate(app_data.netWorthSummaryProvider);
    if (!context.mounted) return;

    final accounts = await repo.getAccounts();
    final newAccount = accounts.where((a) => a.id == newAccountId).firstOrNull;
    if (newAccount != null && context.mounted) {
      await Navigator.push(
        context,
        AppPageRoute(
          builder: (_) => AddBankAccountScreen(existing: newAccount),
        ),
      );
      ref.invalidate(accountsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }

  Future<void> _deleteAccount(
    BuildContext context,
    WidgetRef ref,
    BankAccount account,
  ) async {
    final displayName = resolveAccountDisplayName(account.name);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account?'),
        content: Text('Delete "$displayName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppTheme.semanticExpense),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(accountsProvider.notifier).remove(account.id);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }

  Future<void> _deleteCard(
    BuildContext context,
    WidgetRef ref,
    CreditCard card,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Card?'),
        content: Text('Delete "${card.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppTheme.semanticExpense),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(app_data.cardsProvider.notifier).remove(card.id);
      ref.invalidate(creditCardsProvider);
      ref.invalidate(app_data.netWorthSummaryProvider);
    }
  }
}

// ── Financial Position Horizon (Solvency Hero) ─────────────────

class _NetPositionHorizonCard extends ConsumerWidget {
  final List<BankAccount> accounts;
  final List<CreditCard> cards;
  final List<Loan> loans;
  final bool isDark;

  const _NetPositionHorizonCard({
    required this.accounts,
    required this.cards,
    required this.loans,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(app_data.netWorthSummaryProvider);
    final double assets;
    final double liabilities;
    final double netWorth;

    if (summaryAsync.hasValue) {
      assets = summaryAsync.value!.assets;
      liabilities = summaryAsync.value!.liabilities;
      netWorth = summaryAsync.value!.netWorth;
    } else {
      final positiveAssets = accounts
          .where((a) => a.isAsset && a.balance > 0)
          .fold<double>(0, (sum, a) => sum + a.balance);
      final accountOverdrafts = accounts
          .where((a) => a.isAsset && a.balance < 0)
          .fold<double>(0, (sum, a) => sum + a.balance.abs());
      final accountLiabilities = accounts
          .where((a) => !a.isAsset)
          .fold<double>(0, (sum, a) => sum + a.balance.abs());
      final cardOutstanding = cards.fold<double>(
        0,
        (sum, c) => sum + c.usedAmount,
      );
      final loanOutstanding = loans.fold<double>(
        0,
        (sum, loan) =>
            sum + (loan.total - loan.paidAmount).clamp(0, double.infinity),
      );
      assets = positiveAssets;
      liabilities =
          accountLiabilities +
          accountOverdrafts +
          cardOutstanding +
          loanOutstanding;
      netWorth = assets - liabilities;
    }

    final isSolvent = netWorth >= 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Theme.of(context).colorScheme.outline,
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.28)
                : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            HapticService.instance.tap();
            Navigator.push(
              context,
              AppPageRoute(builder: (_) => const NetWorthScreen()),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Row: Solvency Status Badge + Breakdown Action
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isSolvent
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: isSolvent
                              ? Theme.of(context).colorScheme.secondary
                              : Theme.of(context).colorScheme.error,
                          width: 0.6,
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
                              color: isSolvent
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isSolvent ? 'SOLVENT' : 'NEGATIVE NET WORTH',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              color: isSolvent
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.onSecondaryContainer
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Breakdown',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // Net Position Header Label
                Text(
                  'NET POSITION',
                  style: AppTextStyles.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 4),

                // Hero Amount
                SpendXFinancialAmount(
                  amount: netWorth,
                  semanticType: isSolvent
                      ? FinancialSemanticType.neutral
                      : FinancialSemanticType.shortfall,
                  size: FinancialAmountSize.hero,
                  showSign: false,
                ),

                const SizedBox(height: 4),

                Text(
                  'Combined balance across liquid assets & active liabilities',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 18),

                // Hairline Divider
                Container(
                  height: 0.5,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        isDark
                            ? Colors.white.withValues(alpha: 0.12)
                            : Colors.black.withValues(alpha: 0.08),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // Assets & Liabilities Split Strip
                Row(
                  children: [
                    // Assets Column (Emerald when positive, Neutral when zero - NEVER NEGATIVE)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Total Assets',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            assets <= 0
                                ? AppFormat.currency(0)
                                : '+${AppFormat.currency(assets)}',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(context).colorScheme.secondary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    Container(
                      width: 0.6,
                      height: 30,
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.12)
                          : Colors.black.withValues(alpha: 0.08),
                    ),
                    const SizedBox(width: 16),

                    // Liabilities Column
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Total Liabilities',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            AppFormat.currency(liabilities.abs()),
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.error,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Restrained Quick Action Hub ─────────────────────────────────

class _AccountsActionHub extends StatelessWidget {
  final bool isDark;
  final VoidCallback onAddAccount;
  final VoidCallback onAddCard;
  final VoidCallback onOpenLending;

  const _AccountsActionHub({
    required this.isDark,
    required this.onAddAccount,
    required this.onAddCard,
    required this.onOpenLending,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: _ActionPillButton(
              icon: Icons.account_balance_rounded,
              iconColor: Theme.of(context).colorScheme.primary,
              label: '+ Account',
              isDark: isDark,
              onTap: onAddAccount,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionPillButton(
              icon: Icons.credit_card_rounded,
              iconColor: Theme.of(context).colorScheme.error,
              label: '+ Card',
              isDark: isDark,
              onTap: onAddCard,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionPillButton(
              icon: Icons.trending_up_rounded,
              iconColor: Theme.of(context).colorScheme.secondary,
              label: '+ Invest',
              isDark: isDark,
              onTap: () async {
                await Navigator.push(
                  context,
                  AppPageRoute(
                    builder: (_) =>
                        const AddBankAccountScreen(initialType: 'mutual_fund'),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionPillButton(
              icon: Icons.handshake_outlined,
              iconColor: Theme.of(context).colorScheme.tertiary,
              label: 'Lending',
              isDark: isDark,
              onTap: onOpenLending,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionPillButton extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final bool isDark;
  final VoidCallback onTap;

  const _ActionPillButton({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticService.instance.tap();
          onTap();
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: Theme.of(context).colorScheme.surfaceContainer,
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Theme.of(context).colorScheme.outline,
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.15)
                    : const Color(0x061C1917),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Bank Account Ledger Row Item ────────────────────────────────

class _BankAccountRow extends StatelessWidget {
  final BankAccount account;
  final bool showDivider;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onOptionsTap;

  const _BankAccountRow({
    required this.account,
    required this.showDivider,
    required this.isDark,
    required this.onTap,
    required this.onOptionsTap,
  });

  @override
  Widget build(BuildContext context) {
    final isNegative = account.balance < 0;
    final balanceColor = isNegative
        ? (Theme.of(context).colorScheme.tertiary)
        : (context.textPrimary);

    final iconData = _iconForAccount(account.icon);
    final displayName = resolveAccountDisplayName(account.name);
    final typeLabel = account.accountType.isNotEmpty
        ? account.accountType.replaceAll('_', ' ').toUpperCase()
        : 'BANK';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(14),
                  splashColor: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.03),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            // Account Icon Pill
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color:
                                    (isNegative
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.tertiary
                                            : Theme.of(
                                                context,
                                              ).colorScheme.primary)
                                        .withValues(
                                          alpha: isDark ? 0.16 : 0.10,
                                        ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color:
                                      (isNegative
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.tertiary
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.primary)
                                          .withValues(
                                            alpha: isDark ? 0.28 : 0.18,
                                          ),
                                  width: 0.6,
                                ),
                              ),
                              child: Icon(
                                iconData,
                                size: 20,
                                color: isNegative
                                    ? Theme.of(context).colorScheme.tertiary
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: context.textPrimary,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Wrap(
                                    spacing: 5,
                                    runSpacing: 2,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? Colors.white.withValues(
                                                  alpha: 0.06,
                                                )
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerHigh,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          typeLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.3,
                                            color: context.textSecondary,
                                          ),
                                        ),
                                      ),
                                      if (isNegative)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.tertiaryContainer,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            'OVERDRAWN',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.4,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onTertiaryContainer,
                                            ),
                                          ),
                                        ),
                                      if (account.last4 != null &&
                                          account.last4!.isNotEmpty)
                                        Text(
                                          '••${account.last4}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: context.textMuted,
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: SizedBox(
                              width: 140,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  AppFormat.currency(account.balance),
                                  maxLines: 1,
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700,
                                    color: balanceColor,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Context Options Button
              const SizedBox(width: 2),
              Semantics(
                button: true,
                label: 'Account options for ${account.name}',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticService.instance.tap();
                    onOptionsTap();
                  },
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (showDivider)
          Container(
            margin: const EdgeInsets.only(left: 68, right: 16),
            height: 0.5,
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Theme.of(context).colorScheme.outline,
          ),
      ],
    );
  }

  IconData _iconForAccount(String iconName) {
    switch (iconName) {
      case 'payments':
        return Icons.payments_rounded;
      case 'wallet':
        return Icons.account_balance_wallet_rounded;
      case 'trending_up':
        return Icons.trending_up_rounded;
      case 'pie_chart':
        return Icons.pie_chart_rounded;
      case 'savings':
        return Icons.savings_rounded;
      case 'lock':
        return Icons.lock_rounded;
      default:
        return Icons.account_balance_rounded;
    }
  }
}

// ── Credit Card Visual Instrument ───────────────────────────────

class _CreditCardInstrument extends StatelessWidget {
  final CreditCard card;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback? onPayTap;
  final VoidCallback onOptionsTap;

  const _CreditCardInstrument({
    required this.card,
    required this.isDark,
    required this.onTap,
    this.onPayTap,
    required this.onOptionsTap,
  });

  @override
  Widget build(BuildContext context) {
    final utilization = card.utilizationPct;
    final isHighUtilization = utilization > 70;
    final isMidUtilization = utilization > 30 && utilization <= 70;

    final utilizationColor = isHighUtilization
        ? Theme.of(context).colorScheme.error
        : (isMidUtilization
              ? Theme.of(context).colorScheme.tertiary
              : Theme.of(context).colorScheme.secondary);

    final daysUntilDue = card.nextDueDate.difference(DateTime.now()).inDays;
    final dueText = daysUntilDue <= 0
        ? 'Due today'
        : (daysUntilDue == 1 ? 'Due tomorrow' : 'Due in $daysUntilDue days');

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  AppTheme.creditCardSurfaceDarkTop,
                  AppTheme.creditCardSurfaceDarkBottom,
                ]
              : [
                  AppTheme.creditCardSurfaceLightTop,
                  AppTheme.creditCardSurfaceLightBottom,
                ],
        ),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Theme.of(context).colorScheme.outline,
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Row: Bank Name, Brand Chip, Options Menu
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 20,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).colorScheme.tertiary.withValues(alpha: 0.8),
                              width: 1.0,
                            ),
                            gradient: LinearGradient(
                              colors: [
                                Theme.of(
                                  context,
                                ).colorScheme.onTertiaryContainer,
                                Theme.of(context).colorScheme.tertiary,
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            (card.bank.isNotEmpty ? card.bank : 'CREDIT CARD')
                                .toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    children: [
                      _buildCardBrandBadge(context, card.cardType),
                      const SizedBox(width: 4),
                      Semantics(
                        button: true,
                        label: 'Card options for ${card.name}',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            HapticService.instance.tap();
                            onOptionsTap();
                          },
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: Icon(
                              Icons.more_vert_rounded,
                              size: 18,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // Interactive Card Body (Tapping opens edit screen)
              InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                splashColor: Colors.white.withValues(alpha: 0.05),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Card Name & Masked Digits
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              card.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          Text(
                            '•••• ${card.last4.isNotEmpty ? card.last4 : '••••'}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Financial Balance Overview: Outstanding vs Available
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  card.usedAmount < -0.05
                                      ? 'OVERPAID / CREDIT BALANCE'
                                      : 'OUTSTANDING BALANCE',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.8,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    card.usedAmount < -0.05
                                        ? '+${AppFormat.currency(card.usedAmount.abs())}'
                                        : AppFormat.currency(
                                            card.usedAmount.clamp(
                                              0.0,
                                              double.infinity,
                                            ),
                                          ),
                                    style: TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700,
                                      color: card.usedAmount > 0.05
                                          ? Theme.of(context).colorScheme.error
                                          : (card.usedAmount < -0.05
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.secondary
                                                : Colors.white),
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'AVAILABLE LIMIT',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.8,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    card.limitAmount > 0
                                        ? AppFormat.currency(
                                            card.availableLimit,
                                          )
                                        : 'Not set',
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // Milestone Utilization Runway Track
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          height: 5.5,
                          color: Colors.white.withValues(alpha: 0.12),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final progress = (utilization / 100).clamp(
                                0.0,
                                1.0,
                              );
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  width: constraints.maxWidth * progress,
                                  decoration: BoxDecoration(
                                    color: utilizationColor,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // Track Metadata & Milestone Due Diamond & Direct Pay Action
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    child: Text(
                      card.limitAmount > 0
                          ? '${utilization.toStringAsFixed(1)}% utilized of ${AppFormat.currency(card.limitAmount)}'
                          : 'No limit set',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: utilizationColor,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onTap,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '◇',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.tertiary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              dueText,
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (onPayTap != null && card.usedAmount > 0) ...[
                        const SizedBox(width: 8),
                        AppTapScale(
                          semanticLabel: 'Make a payment to ${card.name}',
                          onTap: onPayTap,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.secondary.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.6),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.payment_rounded,
                                  size: 11,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                ),
                                SizedBox(width: 3),
                                Text(
                                  'Pay',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardBrandBadge(BuildContext context, String cardType) {
    final type = cardType.toLowerCase();
    String brandText = 'CARD';
    Color brandColor = Colors.white70;

    if (type.contains('visa')) {
      brandText = 'VISA';
      brandColor = const Color(0xFF60A5FA);
    } else if (type.contains('master')) {
      brandText = 'MC';
      brandColor = const Color(0xFFFB923C);
    } else if (type.contains('rupay')) {
      brandText = 'RuPay';
      brandColor = Theme.of(context).colorScheme.secondary;
    } else if (type.contains('amex')) {
      brandText = 'AMEX';
      brandColor = Theme.of(context).colorScheme.primary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.6,
        ),
      ),
      child: Text(
        brandText,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: brandColor,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ── Bank Loan Amortization Row ──────────────────────────────────

class _LoanAmortizationRow extends StatelessWidget {
  final Loan loan;
  final double remaining;
  final bool showDivider;
  final bool isDark;
  final VoidCallback onTap;

  const _LoanAmortizationRow({
    required this.loan,
    required this.remaining,
    required this.showDivider,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final paidProgress = loan.total > 0
        ? (loan.paidAmount / loan.total).clamp(0.0, 1.0)
        : 0.0;
    final paidPct = (paidProgress * 100).toStringAsFixed(0);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiary
                            .withValues(alpha: isDark ? 0.16 : 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.tertiary
                              .withValues(alpha: isDark ? 0.28 : 0.18),
                          width: 0.6,
                        ),
                      ),
                      child: Icon(
                        Icons.account_balance_outlined,
                        size: 19,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loan.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${loan.bank.isNotEmpty ? '${loan.bank} • ' : ''}Total ${AppFormat.currency(loan.total)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        SizedBox(
                          width: 112,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              AppFormat.currency(remaining),
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.error,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Outstanding',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Amortization progress runway
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          height: 4.5,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : Theme.of(context).colorScheme.outline,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  width: constraints.maxWidth * paidProgress,
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondary,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$paidPct% amortized',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(context).colorScheme.secondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (showDivider)
            Container(
              margin: const EdgeInsets.only(left: 66, right: 16),
              height: 0.5,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Theme.of(context).colorScheme.outline,
            ),
        ],
      ),
    );
  }
}

// ── Generic Navigation Link Row ─────────────────────────────────

class _NavigationLinkRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool showDivider;
  final bool isDark;
  final VoidCallback onTap;

  const _NavigationLinkRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.showDivider = true,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: iconColor, size: 19),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (showDivider)
          Container(
            margin: const EdgeInsets.only(left: 68, right: 16),
            height: 0.5,
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Theme.of(context).colorScheme.outline,
          ),
      ],
    );
  }
}

// ── Empty States & Placeholders ─────────────────────────────────

class _EmptyCardPlaceholder extends StatelessWidget {
  final bool isDark;
  final VoidCallback onAddCard;

  const _EmptyCardPlaceholder({required this.isDark, required this.onAddCard});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Theme.of(context).colorScheme.outline,
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.error.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.credit_card_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No credit cards linked',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Track billing cycles, credit limits, and milestones',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SpendXGlassButton(
            height: 32,
            variant: SpendXGlassButtonVariant.tonal,
            accentColor: AppTheme.semanticExpense,
            onPressed: onAddCard,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

class _EmptyStateCard extends StatelessWidget {
  final bool isDark;
  final VoidCallback onAddAccount;
  final VoidCallback onAddCard;

  const _EmptyStateCard({
    required this.isDark,
    required this.onAddAccount,
    required this.onAddCard,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Theme.of(context).colorScheme.outline,
          width: 0.9,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 24,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                'Establish Your Balance Sheet',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: Semantics(
              image: true,
              label: 'Accounts illustration',
              child: SvgPicture.asset(
                'assets/illustrations/empty_accounts.svg',
                width: 128,
                height: 84,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect bank accounts, credit cards, or cash wallets to reflect your true net worth and automate statements.',
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SpendXGlassButton(
                  height: 38,
                  variant: SpendXGlassButtonVariant.tonal,
                  accentColor: AppTheme.primaryBlue,
                  onPressed: onAddAccount,
                  child: const Text('+ Bank Account'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SpendXGlassButton(
                  height: 38,
                  variant: SpendXGlassButtonVariant.tonal,
                  accentColor: AppTheme.semanticExpense,
                  onPressed: onAddCard,
                  child: const Text('+ Credit Card'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
