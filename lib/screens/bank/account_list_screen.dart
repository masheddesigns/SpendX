import 'dart:math' as math;
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
import '../../shared/widgets/error_state_widget.dart';
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
import '../../services/cross_channel_monitoring_service.dart';
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
  if (RegExp(r'^loan_[a-z0-9_-]+$', caseSensitive: false).hasMatch(trimmed)) {
    return 'Loan Account';
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
  int _selectedTabIndex = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _selectedTabIndex);
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
    _pageController.dispose();
    if (_busListener != null) {
      DataChangeBus.instance.removeListener(_busListener!);
    }
    super.dispose();
  }

  Future<void> _handleRefresh() async {
    await CrossChannelMonitoringService.instance.runCycle(reason: 'pull_to_refresh');
    await LiveSmsService.instance.syncUpcomingObligationsFromInbox();
    ref.invalidate(accountsProvider);
    ref.invalidate(creditCardsProvider);
    ref.invalidate(loansProvider);
    ref.invalidate(app_data.netWorthSummaryProvider);
    app_data.invalidateAllFinancialProviders(ref);
  }

  void _onTabSelected(int index) {
    if (_selectedTabIndex != index) {
      HapticService.instance.selection();
      setState(() => _selectedTabIndex = index);
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountsProvider);
    final cardsAsync = ref.watch(creditCardsProvider);
    final loansAsync = ref.watch(loansProvider);

    // Only display full-screen skeleton loader on the very first cold load
    // when absolutely no cached or pre-existing data is available yet.
    final hasExistingData = accountsAsync.hasValue ||
        cardsAsync.hasValue ||
        loansAsync.hasValue;
    final isColdLoading = !hasExistingData &&
        (accountsAsync.isLoading ||
            cardsAsync.isLoading ||
            loansAsync.isLoading);

    if (isColdLoading) {
      return const Center(child: SpendXLoadingState(count: 5, itemHeight: 70));
    }

    if (!accountsAsync.hasValue && accountsAsync.hasError) {
      return Center(
        child: ErrorStateWidget(
          error: accountsAsync.error!,
          onRetry: () => ref.invalidate(accountsProvider),
        ),
      );
    }
    if (!cardsAsync.hasValue && cardsAsync.hasError) {
      return Center(
        child: ErrorStateWidget(
          error: cardsAsync.error!,
          onRetry: () => ref.invalidate(creditCardsProvider),
        ),
      );
    }
    if (!loansAsync.hasValue && loansAsync.hasError) {
      return Center(
        child: ErrorStateWidget(
          error: loansAsync.error!,
          onRetry: () => ref.invalidate(loansProvider),
        ),
      );
    }

    final accounts = accountsAsync.value ?? [];
    final cards = cardsAsync.value ?? [];
    final loans = loansAsync.value ?? [];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Animated Segmented Tab Bar ──
        _AnimatedSegmentedTabBar(
          selectedIndex: _selectedTabIndex,
          onTabSelected: _onTabSelected,
          tabs: const ['Overview', 'Banks', 'Cards', 'Loans'],
        ),

        // ── Animated Page View for Tabs ──
        Expanded(
          child: PageView(
            key: const PageStorageKey('accounts_tabs_page_view'),
            controller: _pageController,
            onPageChanged: (index) {
              if (_selectedTabIndex != index) {
                HapticService.instance.selection();
                setState(() => _selectedTabIndex = index);
              }
            },
            children: [
              _KeepAliveTab(
                child: _buildOverviewTab(
                  context,
                  ref,
                  accounts,
                  cards,
                  loans,
                  isDark,
                ),
              ),
              _KeepAliveTab(
                child: _buildBanksTab(context, ref, accounts, isDark),
              ),
              _KeepAliveTab(
                child: _buildCardsTab(context, ref, cards, isDark),
              ),
              _KeepAliveTab(
                child: _buildLoansTab(context, ref, loans, isDark),
              ),
            ],
          ),
        ),
      ],
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
          actions: MediaQuery.sizeOf(context).width < 400
              ? [
                  PopupMenuButton<String>(
                    tooltip: 'Account actions',
                    icon: const Icon(Icons.add_rounded),
                    onSelected: (action) {
                      if (action == 'add') {
                        _openAddAccount(context, ref);
                      } else {
                        _consolidateAccounts(context, ref);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'add', child: Text('Add account')),
                      PopupMenuItem(
                        value: 'consolidate',
                        child: Text('Consolidate & deduplicate'),
                      ),
                    ],
                  ),
                ]
              : [
                  IconButton(
                    icon: const Icon(Icons.auto_fix_high_rounded),
                    tooltip: 'Consolidate & Deduplicate',
                    onPressed: () => _consolidateAccounts(context, ref),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded),
                    tooltip: 'Add Account',
                    onPressed: () => _openAddAccount(context, ref),
                  ),
                ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth > 800) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: content,
                ),
              );
            }
            return content;
          },
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 800) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: content,
            ),
          );
        }
        return content;
      },
    );
  }

  // ── Tab 0: Overview ──────────────────────────────────────────
  Widget _buildOverviewTab(
    BuildContext context,
    WidgetRef ref,
    List<BankAccount> accounts,
    List<CreditCard> cards,
    List<Loan> loans,
    bool isDark,
  ) {
    return RefreshIndicator(
      onRefresh: _handleRefresh,
      color: AppTheme.primaryBlue,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Hero Net Worth Card ──
          SliverToBoxAdapter(
            child: _HeroNetWorthCard(
              accounts: accounts,
              cards: cards,
              loans: loans,
              isDark: isDark,
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          // ── Assets vs Liabilities Card ──
          SliverToBoxAdapter(
            child: _AssetsLiabilitiesCard(
              accounts: accounts,
              cards: cards,
              loans: loans,
              isDark: isDark,
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 14)),

          // ── Quick Controls Hub ──
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

          // ── Onboarding State if Completely Empty ──
          if (accounts.isEmpty && cards.isEmpty && loans.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: _EmptyStateCard(
                  isDark: isDark,
                  onAddAccount: () => _openAddAccount(context, ref),
                  onAddCard: () => _openAddCreditCard(context, ref),
                ),
              ),
            ),

          // ── Your Accounts Section ──
          if (accounts.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SpendXSectionHeader(
                title: 'Your Accounts',
                count: accounts.length,
                actionLabel: '+ Add',
                onAction: () => _openAddAccount(context, ref),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: List.generate(accounts.length, (index) {
                    final acc = accounts[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == accounts.length - 1 ? 0 : 10,
                      ),
                      child: _BankAccountCard(
                        account: acc,
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
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],

          // Clearance spacer
          SliverToBoxAdapter(
            child: SizedBox(
              height: (MediaQuery.paddingOf(context).bottom > 0
                      ? MediaQuery.paddingOf(context).bottom + 72.0
                      : 80.0) +
                  16.0,
            ),
          ),
        ],
      ),
    );
  }

  // ── Tab 1: Banks ─────────────────────────────────────────────
  Widget _buildBanksTab(
    BuildContext context,
    WidgetRef ref,
    List<BankAccount> accounts,
    bool isDark,
  ) {
    final positiveTotal = accounts
        .where((a) => a.isAsset && a.balance > 0)
        .fold<double>(0, (sum, a) => sum + a.balance);
    final overdraftTotal = accounts
        .where((a) => a.isAsset && a.balance < 0)
        .fold<double>(0, (sum, a) => sum + a.balance.abs());

    return RefreshIndicator(
      onRefresh: _handleRefresh,
      color: AppTheme.primaryBlue,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SpendXSectionHeader(
              title: 'Bank Accounts & Cash',
              count: accounts.length,
              actionLabel: '+ Add Account',
              onAction: () => _openAddAccount(context, ref),
            ),
          ),

          // Total liquid cash banner (dual metric if overdraft exists)
          if (overdraftTotal > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    border: Border.all(color: context.borderColor, width: 0.9),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                            : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.03),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'TOTAL LIQUID CASH',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Color(0xFF10B981),
                              ),
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                AppFormat.currency(positiveTotal),
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: context.textPrimary,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 0.8,
                        height: 32,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TOTAL OVERDRAFT',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '-${AppFormat.currency(overdraftTotal)}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: Theme.of(context).colorScheme.error,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    border: Border.all(color: context.borderColor, width: 0.9),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                            : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.03),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.account_balance_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TOTAL LIQUID CASH',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                AppFormat.currency(positiveTotal),
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: context.textPrimary,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
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

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          if (accounts.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: List.generate(accounts.length, (index) {
                    final acc = accounts[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == accounts.length - 1 ? 0 : 10,
                      ),
                      child: _BankAccountCard(
                        account: acc,
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
                      ),
                    );
                  }),
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: _EmptyStateCard(
                  isDark: isDark,
                  onAddAccount: () => _openAddAccount(context, ref),
                  onAddCard: () => _openAddCreditCard(context, ref),
                ),
              ),
            ),

          SliverToBoxAdapter(
            child: SizedBox(
              height: (MediaQuery.paddingOf(context).bottom > 0
                      ? MediaQuery.paddingOf(context).bottom + 72.0
                      : 80.0) +
                  16.0,
            ),
          ),
        ],
      ),
    );
  }

  // ── Tab 2: Cards ─────────────────────────────────────────────
  Widget _buildCardsTab(
    BuildContext context,
    WidgetRef ref,
    List<CreditCard> cards,
    bool isDark,
  ) {
    final totalLimit = cards.fold<double>(0, (sum, c) => sum + c.limitAmount);
    final totalOutstanding = cards.fold<double>(0, (sum, c) => sum + c.usedAmount);
    final availableCredit = (totalLimit - totalOutstanding).clamp(0.0, double.infinity);

    return RefreshIndicator(
      onRefresh: _handleRefresh,
      color: AppTheme.primaryBlue,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SpendXSectionHeader(
              title: 'Credit Cards',
              count: cards.isNotEmpty ? cards.length : null,
              actionLabel: '+ Add Card',
              onAction: () => _openAddCreditCard(context, ref),
            ),
          ),

          // Cards metrics summary
          if (cards.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    border: Border.all(color: context.borderColor, width: 0.9),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                            : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.03),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TOTAL OUTSTANDING',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              AppFormat.currency(totalOutstanding),
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: context.textPrimary,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 0.8,
                        height: 32,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'AVAILABLE CREDIT',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Color(0xFF10B981),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              AppFormat.currency(availableCredit),
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: context.textPrimary,
                                fontFeatures: const [FontFeature.tabularFigures()],
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

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          if (cards.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: _EmptyCardPlaceholder(
                  isDark: isDark,
                  onAddCard: () => _openAddCreditCard(context, ref),
                ),
              ),
            ),

          SliverToBoxAdapter(
            child: SizedBox(
              height: (MediaQuery.paddingOf(context).bottom > 0
                      ? MediaQuery.paddingOf(context).bottom + 72.0
                      : 80.0) +
                  16.0,
            ),
          ),
        ],
      ),
    );
  }

  // ── Tab 3: Loans ─────────────────────────────────────────────
  Widget _buildLoansTab(
    BuildContext context,
    WidgetRef ref,
    List<Loan> loans,
    bool isDark,
  ) {
    final totalRemaining = loans.fold<double>(
      0,
      (sum, l) => sum + (l.total - l.paidAmount).clamp(0.0, double.infinity),
    );

    return RefreshIndicator(
      onRefresh: _handleRefresh,
      color: AppTheme.primaryBlue,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
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

          // Total outstanding debt banner
          if (loans.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    border: Border.all(color: context.borderColor, width: 0.9),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                            : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.03),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.account_balance_outlined,
                          color: Theme.of(context).colorScheme.error,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TOTAL OUTSTANDING LOANS',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              AppFormat.currency(totalRemaining),
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: context.textPrimary,
                                fontFeatures: const [FontFeature.tabularFigures()],
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

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  border: Border.all(
                    color: context.borderColor,
                    width: 0.9,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                          : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.03),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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

          SliverToBoxAdapter(
            child: SizedBox(
              height: (MediaQuery.paddingOf(context).bottom > 0
                      ? MediaQuery.paddingOf(context).bottom + 72.0
                      : 80.0) +
                  16.0,
            ),
          ),
        ],
      ),
    );
  }


  // ── Actions & Navigation Handlers ────────────────────────────

  Future<void> _consolidateAccounts(BuildContext context, WidgetRef ref) async {
    HapticService.instance.medium();
    final count = await EntityConsolidationService.instance.consolidate();
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
  }

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
                    color: context.borderColor,
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
                    color: context.borderColor,
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

// ── Animated Segmented Tab Bar ─────────────────────────────────

class _AnimatedSegmentedTabBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final List<String> tabs;

  const _AnimatedSegmentedTabBar({
    required this.selectedIndex,
    required this.onTabSelected,
    required this.tabs,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? const Color(0xFF1E2235)
        : const Color(0xFFEFF2F8);
    final indicatorColor = const Color(0xFF5A4FE3);

    return Container(
      height: 46,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05),
          width: 0.8,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / tabs.length;
          return Stack(
            children: [
              // Sliding Animated Pill Indicator
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: selectedIndex * tabWidth,
                top: 0,
                bottom: 0,
                width: tabWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: indicatorColor.withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              // Tab Labels
              Row(
                children: List.generate(tabs.length, (index) {
                  final isSelected = index == selectedIndex;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onTabSelected(index),
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: isSelected
                                ? Colors.white
                                : (isDark
                                    ? Colors.white70
                                    : const Color(0xFF55607A)),
                          ),
                          child: Text(
                            tabs[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ── Hero Net Worth Card (Redesign Mockup) ───────────────────────

class _HeroNetWorthCard extends ConsumerStatefulWidget {
  final List<BankAccount> accounts;
  final List<CreditCard> cards;
  final List<Loan> loans;
  final bool isDark;

  const _HeroNetWorthCard({
    required this.accounts,
    required this.cards,
    required this.loans,
    required this.isDark,
  });

  @override
  ConsumerState<_HeroNetWorthCard> createState() => _HeroNetWorthCardState();
}

class _HeroNetWorthCardState extends ConsumerState<_HeroNetWorthCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(app_data.netWorthSummaryProvider);
    final double netWorth;

    if (summaryAsync.hasValue) {
      netWorth = summaryAsync.value!.netWorth;
    } else {
      final positiveAssets = widget.accounts
          .where((a) => a.isAsset && a.balance > 0)
          .fold<double>(0, (sum, a) => sum + a.balance);
      final accountOverdrafts = widget.accounts
          .where((a) => a.isAsset && a.balance < 0)
          .fold<double>(0, (sum, a) => sum + a.balance.abs());
      final accountLiabilities = widget.accounts
          .where((a) => !a.isAsset)
          .fold<double>(0, (sum, a) => sum + a.balance.abs());
      final cardOutstanding = widget.cards.fold<double>(
        0,
        (sum, c) => sum + c.usedAmount,
      );
      final loanOutstanding = widget.loans.fold<double>(
        0,
        (sum, loan) =>
            sum + (loan.total - loan.paidAmount).clamp(0, double.infinity),
      );
      final assets = positiveAssets;
      final liabilities =
          accountLiabilities +
          accountOverdrafts +
          cardOutstanding +
          loanOutstanding;
      netWorth = assets - liabilities;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF4338CA),
            Color(0xFF5B4CF2),
            Color(0xFF7C3AED),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4F46E5).withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: Semantics(
          button: true,
          label: 'View Net Worth summary',
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () {
              HapticService.instance.tap();
              Navigator.push(
                context,
                AppPageRoute(builder: (_) => const NetWorthScreen()),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  // Animated Wave Lines moving up and down continuously
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _waveController,
                      builder: (context, _) {
                        return CustomPaint(
                          painter: _WaveDecorationPainter(
                            progress: _waveController.value,
                          ),
                        );
                      },
                    ),
                  ),
                  // Content
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Top row: Trend Icon capsule + (Net Worth label & Amount column) + Chevron
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: const Icon(
                                Icons.trending_up,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Net Worth',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.2,
                                      color: Colors.white.withValues(alpha: 0.9),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      AppFormat.currency(netWorth),
                                      maxLines: 1,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.5,
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
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 22,
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                          ],
                        ),

                        const SizedBox(height: 18),

                        // Bottom Pill: ↗ 0% vs last month
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 5.5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.25),
                                width: 0.8,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.trending_up,
                                  size: 14,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  '0% vs last month',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
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
      ),
    );
  }
}

// ── Custom Wave Decoration Painter (Animated Up & Down) ─────────

class _WaveDecorationPainter extends CustomPainter {
  final double progress;

  const _WaveDecorationPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    final paint2 = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round;

    final phase1 = progress * 2 * math.pi;
    final phase2 = phase1 + (math.pi / 2.5);

    // Harmonic vertical oscillations for crests and troughs (moving up and down)
    final dy1A = math.sin(phase1) * 9.0;
    final dy1B = math.cos(phase1) * 10.0;
    final dy1C = math.sin(phase1 + 1.3) * 8.0;

    final path1 = Path();
    path1.moveTo(0, size.height * 0.72 + dy1A);
    path1.cubicTo(
      size.width * 0.25,
      size.height * 0.62 + dy1B,
      size.width * 0.45,
      size.height * 0.82 - dy1A,
      size.width * 0.70,
      size.height * 0.68 + dy1C,
    );
    path1.cubicTo(
      size.width * 0.85,
      size.height * 0.60 - dy1B,
      size.width * 0.95,
      size.height * 0.75 + dy1A,
      size.width,
      size.height * 0.70 - dy1C,
    );
    canvas.drawPath(path1, paint1);

    final dy2A = math.sin(phase2) * 8.0;
    final dy2B = math.cos(phase2) * 9.5;
    final dy2C = math.sin(phase2 + 1.5) * 7.5;

    final path2 = Path();
    path2.moveTo(0, size.height * 0.82 - dy2A);
    path2.cubicTo(
      size.width * 0.30,
      size.height * 0.72 + dy2B,
      size.width * 0.50,
      size.height * 0.90 - dy2C,
      size.width * 0.75,
      size.height * 0.78 + dy2A,
    );
    path2.cubicTo(
      size.width * 0.88,
      size.height * 0.70 - dy2B,
      size.width * 0.96,
      size.height * 0.84 + dy2C,
      size.width,
      size.height * 0.80 - dy2A,
    );
    canvas.drawPath(path2, paint2);
  }

  @override
  bool shouldRepaint(covariant _WaveDecorationPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

// ── Assets vs Liabilities Card (Redesign Mockup) ────────────────

class _AssetsLiabilitiesCard extends ConsumerWidget {
  final List<BankAccount> accounts;
  final List<CreditCard> cards;
  final List<Loan> loans;
  final bool isDark;

  const _AssetsLiabilitiesCard({
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

    if (summaryAsync.hasValue) {
      assets = summaryAsync.value!.assets;
      liabilities = summaryAsync.value!.liabilities;
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
    }

    final safeAssets = assets > 0 ? assets : 0.0;
    final safeLiabilities = liabilities.abs();
    final total = safeAssets + safeLiabilities;
    final assetRatio = total > 0 ? (safeAssets / total).clamp(0.0, 1.0) : 0.0;
    final liabilityRatio = total > 0 ? (safeLiabilities / total).clamp(0.0, 1.0) : 0.0;
    final isSolvent = safeAssets >= safeLiabilities;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Assets vs Liabilities',
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
              InkWell(
                onTap: () {
                  HapticService.instance.tap();
                  Navigator.push(
                    context,
                    AppPageRoute(builder: (_) => const NetWorthScreen()),
                  );
                },
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Details',
                        style: TextStyle(
                          fontSize: 13,
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
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Theme.of(context).colorScheme.surfaceContainer,
            border: Border.all(
              color: context.borderColor,
              width: 0.9,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                    : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.03),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                HapticService.instance.tap();
                Navigator.push(
                  context,
                  AppPageRoute(builder: (_) => const NetWorthScreen()),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Solvency Status Header inside card
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'BALANCE RATIO',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isSolvent
                                ? const Color(0xFF10B981).withValues(alpha: 0.12)
                                : const Color(0xFFEF4444).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: isSolvent
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFFEF4444),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                isSolvent ? 'Solvent' : 'Debt Exceeds Assets',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: isSolvent
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFFEF4444),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // Metrics Split Row
                    Row(
                      children: [
                        // Assets Column
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF10B981),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    'ASSETS',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.7,
                                      color: Color(0xFF10B981),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  AppFormat.currency(safeAssets),
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: context.textPrimary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${(assetRatio * 100).toStringAsFixed(0)}% of balance sheet',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Vertical Separator
                        Container(
                          width: 1,
                          height: 48,
                          margin: const EdgeInsets.symmetric(horizontal: 14),
                          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
                        ),

                        // Liabilities Column
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFEF4444),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    'LIABILITIES',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.7,
                                      color: Color(0xFFEF4444),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  AppFormat.currency(safeLiabilities),
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: context.textPrimary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${(liabilityRatio * 100).toStringAsFixed(0)}% of balance sheet',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Proportional Dual-Tone Ratio Runway Bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        height: 7,
                        child: Row(
                          children: [
                            if (assetRatio > 0)
                              Expanded(
                                flex: (assetRatio * 1000).toInt().clamp(1, 1000),
                                child: Container(color: const Color(0xFF10B981)),
                              ),
                            if (assetRatio > 0 && liabilityRatio > 0)
                              const SizedBox(width: 2),
                            if (liabilityRatio > 0)
                              Expanded(
                                flex: (liabilityRatio * 1000).toInt().clamp(1, 1000),
                                child: Container(color: const Color(0xFFEF4444)),
                              ),
                            if (total == 0)
                              Expanded(
                                child: Container(
                                  color: Theme.of(context).colorScheme.outlineVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

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
    final actions = <Widget>[
      _ActionPillButton(
        icon: Icons.account_balance_rounded,
        iconColor: Theme.of(context).colorScheme.primary,
        label: '+ Account',
        isDark: isDark,
        onTap: onAddAccount,
      ),
      _ActionPillButton(
        icon: Icons.credit_card_rounded,
        iconColor: Theme.of(context).colorScheme.error,
        label: '+ Card',
        isDark: isDark,
        onTap: onAddCard,
      ),
      _ActionPillButton(
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
      _ActionPillButton(
        icon: Icons.handshake_outlined,
        iconColor: Theme.of(context).colorScheme.tertiary,
        label: 'Lending',
        isDark: isDark,
        onTap: onOpenLending,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth < 520 ? 2 : 4;
          const spacing = 8.0;
          final itemWidth =
              (constraints.maxWidth - spacing * (columns - 1)) / columns;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final action in actions)
                SizedBox(width: itemWidth, child: action),
            ],
          );
        },
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
        child: Semantics(
          button: true,
          label: label,
          child: Tooltip(
            message: label,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  border: Border.all(
                    color: context.borderColor,
                    width: 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.15)
                          : Theme.of(
                              context,
                            ).colorScheme.shadow.withValues(alpha: 0.024),
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
          ),
        ),
      ),
    );
  }
}

// ── Bank Account Financial Instrument Card ───────────────────────

class _BankAccountCard extends StatelessWidget {
  final BankAccount account;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onOptionsTap;

  const _BankAccountCard({
    required this.account,
    required this.isDark,
    required this.onTap,
    required this.onOptionsTap,
  });

  @override
  Widget build(BuildContext context) {
    final isNegative = account.balance < 0;
    final isZero = account.balance == 0;
    final iconData = _iconForAccount(account.icon);
    final displayName = resolveAccountDisplayName(account.name);
    final typeLabel = account.accountType.isNotEmpty
        ? account.accountType.replaceAll('_', ' ').toUpperCase()
        : 'BANK';

    final Color statusColor = isNegative
        ? Theme.of(context).colorScheme.error
        : (isZero
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : const Color(0xFF10B981));

    final String statusText = isNegative
        ? 'Overdrawn'
        : (isZero ? 'Zero balance' : 'Available');

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border.all(
          color: isNegative
              ? Theme.of(context).colorScheme.error.withValues(alpha: isDark ? 0.35 : 0.25)
              : context.borderColor,
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Theme.of(context).colorScheme.shadow.withValues(alpha: 0.25)
                : Theme.of(context).colorScheme.shadow.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: Semantics(
          button: true,
          label: '$displayName, $typeLabel account, balance ${AppFormat.currency(account.balance)}',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            splashColor: context.onSurfaceOverlay(
              lightOpacity: 0.04,
              darkOpacity: 0.06,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  // Icon container
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isNegative
                          ? Theme.of(context).colorScheme.error.withValues(alpha: isDark ? 0.18 : 0.10)
                          : Theme.of(context).colorScheme.primary.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isNegative
                            ? Theme.of(context).colorScheme.error.withValues(alpha: isDark ? 0.35 : 0.2)
                            : Theme.of(context).colorScheme.primary.withValues(alpha: isDark ? 0.3 : 0.18),
                        width: 0.8,
                      ),
                    ),
                    child: Icon(
                      iconData,
                      size: 22,
                      color: isNegative
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),

                  const SizedBox(width: 14),

                  // Middle: Name, Type Pill & Masked Number
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
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                typeLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            if (account.last4 != null && account.last4!.isNotEmpty)
                              Text(
                                '•••• ${account.last4}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 10),

                  // Right: Balance & Status
                  Flexible(
                    flex: 0,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 135),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              AppFormat.currency(account.balance),
                              maxLines: 1,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: isNegative
                                    ? Theme.of(context).colorScheme.error
                                    : context.textPrimary,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            statusText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(width: 4),

                  // Context Options 3-dots
                  Semantics(
                    button: true,
                    label: 'Account options for ${account.name}',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticService.instance.tap();
                        onOptionsTap();
                      },
                      child: Container(
                        width: 32,
                        height: 44,
                        alignment: Alignment.center,
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
          ),
        ),
      ),
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

    final daysUntilDue = card.nextDueDate.difference(DateTime.now()).inDays;
    final dueText = daysUntilDue <= 0
        ? 'Due today'
        : (daysUntilDue == 1 ? 'Due tomorrow' : 'Due in $daysUntilDue days');

    // Resolve card connected color from palette
    final rawColorHex = (card.color.isNotEmpty && card.color != '#6366F1')
        ? card.color
        : CreditCardColors.colorForCard('${card.bank}_${card.name}_${card.last4}');
    final baseColor = CreditCardColors.parseHex(rawColorHex);

    final topColor = isDark
        ? Color.lerp(baseColor, const Color(0xFF1E1B4B), 0.35)!
        : baseColor;
    final bottomColor = isDark
        ? Color.lerp(baseColor, const Color(0xFF0F172A), 0.65)!
        : Color.lerp(baseColor, Colors.black, 0.30)!;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [topColor, bottomColor],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.16),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: baseColor.withValues(alpha: isDark ? 0.35 : 0.22),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Row 1: Chip & Bank Name (Left) + Brand Badge & Options Menu (Right) ──
                Row(
                  children: [
                    // Metallic Chip
                    Container(
                      width: 30,
                      height: 22,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFFDF7A), Color(0xFFD4AF37)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Container(
                          width: 22,
                          height: 14,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: const Color(0xFF997A15),
                              width: 0.6,
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        (card.bank.isNotEmpty ? card.bank : 'CREDIT CARD').toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: Colors.white.withValues(alpha: 0.88),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
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
                        child: Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.more_vert_rounded,
                            size: 20,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // ── Row 2: Card Name (Left) + Masked Last 4 Digits (Right) ──
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        card.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '•••• ${card.last4.isNotEmpty ? card.last4 : '••••'}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                        color: Colors.white.withValues(alpha: 0.85),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // ── Row 3: Financial Balance Overview (Strict Baseline Alignment) ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Left Column: Outstanding Balance
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            card.usedAmount < -0.05
                                ? 'CREDIT BALANCE'
                                : 'OUTSTANDING',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                          const SizedBox(height: 3),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              card.usedAmount < -0.05
                                  ? '+${AppFormat.currency(card.usedAmount.abs())}'
                                  : AppFormat.currency(card.usedAmount.clamp(0.0, double.infinity)),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(width: 16),

                    // Right Column: Available Limit
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'AVAILABLE LIMIT',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                          const SizedBox(height: 3),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              card.limitAmount > 0
                                  ? AppFormat.currency(card.availableLimit)
                                  : 'Not set',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Colors.white.withValues(alpha: 0.95),
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // ── Row 4: Utilization Runway Track ──
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 5,
                    color: Colors.white.withValues(alpha: 0.2),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final progress = (utilization / 100).clamp(0.0, 1.0);
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: constraints.maxWidth * progress,
                            decoration: BoxDecoration(
                              color: isHighUtilization
                                  ? const Color(0xFFEF4444)
                                  : (isMidUtilization
                                      ? const Color(0xFFF59E0B)
                                      : const Color(0xFF10B981)),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // ── Row 5: Footer Actions & Due Status (Fixed Height & Anchored Placement) ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Left: Due Date Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.calendar_today_rounded,
                            size: 11,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            dueText,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.95),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(width: 12),

                    // Right: Pay Action OR Paid Badge
                    if (card.usedAmount > 0.05 && onPayTap != null)
                      Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 2,
                        shadowColor: Colors.black.withValues(alpha: 0.3),
                        child: InkWell(
                          onTap: onPayTap,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6.5),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Pay Bill',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: baseColor,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 13,
                                  color: baseColor,
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFF10B981).withValues(alpha: 0.5),
                            width: 0.8,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              size: 12,
                              color: Color(0xFF34D399),
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Paid',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF34D399),
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

    return Semantics(
      button: true,
      label: 'Loan ${loan.name}, remaining ${AppFormat.currency(remaining)}, $paidPct% paid',
      child: InkWell(
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
                          color: context.borderColor,
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
              color: context.borderColor,
            ),
        ],
      ),
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
        Semantics(
          button: true,
          label: '$title, $subtitle',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
          ),
        ),
        if (showDivider)
          Container(
            margin: const EdgeInsets.only(left: 68, right: 16),
            height: 0.5,
            color: context.borderColor,
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
          color: context.borderColor,
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
          color: context.borderColor,
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
              Expanded(
                child: Text(
                  'Establish Your Balance Sheet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
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
