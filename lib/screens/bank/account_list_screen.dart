import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart' as app_data;
import '../../features/accounts/providers/account_providers.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../services/haptic_service.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/spendx_glass.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import '../credit_card/add_credit_card_screen.dart';
import '../loans/loans_screen.dart';
import '../net_worth_screen.dart';
import 'add_bank_account_screen.dart';

/// SpendX 2.0 Financial Position Surface (Accounts Screen).
///
/// Implements Section 5 of C15-B:
/// - Financial Position Hero (Material 2 — Elevated Glass): Net worth, total assets, liabilities
/// - Restrained interactive glass quick actions (+ Account, + Card, Loans)
/// - Bank Accounts grouped Liquid Glass container with high-density instrument rows
/// - Credit Cards grouped Liquid Glass container with outstanding vs limit context
/// - Loans & Liabilities summary
/// - Strictly consumes existing canonical providers with zero UI-side financial recalculations
class AccountListScreen extends ConsumerWidget {
  final bool isEmbedded;

  const AccountListScreen({super.key, this.isEmbedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final cardsAsync = ref.watch(creditCardsProvider);
    final loansAsync = ref.watch(loansProvider);

    if (accountsAsync.isLoading || cardsAsync.isLoading || loansAsync.isLoading) {
      return const Center(
        child: SpendXLoadingState(count: 5, itemHeight: 70),
      );
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

    if (accounts.isEmpty && cards.isEmpty && loans.isEmpty) {
      return SpendXEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: 'No accounts yet',
        subtitle:
            'Add your bank accounts and credit cards to establish your financial position.',
        actionLabel: '+ Add Account',
        onAction: () => _openAddAccount(context, ref),
      );
    }

    Widget content = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(accountsProvider);
        ref.invalidate(creditCardsProvider);
        ref.invalidate(loansProvider);
        ref.invalidate(app_data.netWorthSummaryProvider);
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Financial Position Hero (Elevated Glass) ──────
          SliverToBoxAdapter(
            child: _NetPositionHero(
              accounts: accounts,
              cards: cards,
              loans: loans,
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 6)),

          // ── Quick Controls (Interactive Glass) ───────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SpendXGlassButton(
                      height: 40,
                      accentColor: AppTheme.primaryBlue,
                      icon: Icons.account_balance_rounded,
                      onPressed: () => _openAddAccount(context, ref),
                      child: const Text('Account'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SpendXGlassButton(
                      height: 40,
                      accentColor: AppTheme.semanticExpense,
                      icon: Icons.credit_card_rounded,
                      onPressed: () => _openAddCreditCard(context, ref),
                      child: const Text('Card'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SpendXGlassButton(
                      height: 40,
                      accentColor: AppTheme.semanticTransfer,
                      icon: Icons.account_balance_outlined,
                      onPressed: () => Navigator.push(
                        context,
                        AppPageRoute(builder: (_) => const LoansScreen()),
                      ),
                      child: const Text('Loan'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // ── Bank Accounts Section ────────────────────────
          if (accounts.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: SpendXSectionHeader(
                title: 'Bank Accounts',
                count: accounts.length,
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SpendXGlassSurface(
                  level: SpendXGlassLevel.base,
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: List.generate(accounts.length, (index) {
                      final acc = accounts[index];
                      final isLast = index == accounts.length - 1;
                      return _BankAccountRow(
                        account: acc,
                        showDivider: !isLast,
                        onTap: () => _openEditAccount(context, ref, acc),
                        onConvertToCard: () =>
                            _convertAccountToCard(context, ref, acc),
                        onDelete: () => _deleteAccount(context, ref, acc),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ],

          // ── Credit Cards Section ─────────────────────────
          if (cards.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(
              child: SpendXSectionHeader(
                title: 'Credit Cards',
                count: cards.length,
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SpendXGlassSurface(
                  level: SpendXGlassLevel.base,
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: List.generate(cards.length, (index) {
                      final card = cards[index];
                      final isLast = index == cards.length - 1;
                      return _CreditCardRow(
                        card: card,
                        showDivider: !isLast,
                        onTap: () => _openEditCreditCard(context, ref, card),
                        onConvertToAccount: () =>
                            _convertCardToAccount(context, ref, card),
                        onDelete: () => _deleteCard(context, ref, card),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ],

          // ── Loans & Liabilities Section ───────────────────
          if (loans.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(
              child: SpendXSectionHeader(
                title: 'Active Loans',
                count: loans.length,
                actionLabel: 'Manage',
                onAction: () => Navigator.push(
                  context,
                  AppPageRoute(builder: (_) => const LoansScreen()),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SpendXGlassSurface(
                  level: SpendXGlassLevel.base,
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: List.generate(loans.length, (index) {
                      final loan = loans[index];
                      final isLast = index == loans.length - 1;
                      final remaining =
                          ((loan.total as num) - (loan.paidAmount as num))
                              .toDouble()
                              .clamp(0.0, double.infinity);
                      return _LoanRow(
                        loan: loan,
                        remaining: remaining,
                        showDivider: !isLast,
                        onTap: () => Navigator.push(
                          context,
                          AppPageRoute(builder: (_) => const LoansScreen()),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ],

          // Generous bottom clearance above floating glass navigation bar
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );

    if (!isEmbedded) {
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
              icon: const Icon(Icons.add_rounded),
              onPressed: () => _openAddAccount(context, ref),
            ),
          ],
        ),
        body: content,
      );
    }

    return content;
  }

  // ── Actions ──────────────────────────────────────────────────

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
      AppPageRoute(
        builder: (_) => AddBankAccountScreen(existing: account),
      ),
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
      AppPageRoute(
        builder: (_) => AddCreditCardScreen(existingCard: card),
      ),
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
          'Convert "${account.name}" from a bank account to a credit card? You can edit the card details after conversion.',
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account?'),
        content: Text('Delete "${account.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
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
            child: const Text('Delete'),
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

// ── Financial Position Hero ─────────────────────────────────────

class _NetPositionHero extends ConsumerWidget {
  final List<BankAccount> accounts;
  final List<CreditCard> cards;
  final List<dynamic> loans;

  const _NetPositionHero({
    required this.accounts,
    required this.cards,
    required this.loans,
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
      assets = accounts
          .where((a) => a.isAsset)
          .fold<double>(0, (sum, a) => sum + a.balance);
      final accountLiabilities = accounts
          .where((a) => !a.isAsset)
          .fold<double>(0, (sum, a) => sum + a.balance.abs());
      final cardOutstanding =
          cards.fold<double>(0, (sum, c) => sum + c.usedAmount);
      final loanOutstanding = loans.fold<double>(
        0,
        (sum, loan) =>
            sum +
            ((loan.total as num) - (loan.paidAmount as num))
                .toDouble()
                .clamp(0, double.infinity),
      );
      liabilities = accountLiabilities + cardOutstanding + loanOutstanding;
      netWorth = assets - liabilities;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SpendXGlassCard(
      level: SpendXGlassLevel.elevated,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(20),
      onTap: () => Navigator.push(
        context,
        AppPageRoute(builder: (_) => const NetWorthScreen()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Label + Details Action
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'NET POSITION',
                style: AppTextStyles.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: isDark
                      ? const Color(0xFFCBD5E1)
                      : const Color(0xFF475569),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Breakdown',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: AppTheme.primaryBlue,
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Net Worth Display
          SpendXFinancialAmount(
            amount: netWorth,
            semanticType: netWorth >= 0
                ? FinancialSemanticType.neutral
                : FinancialSemanticType.shortfall,
            size: FinancialAmountSize.hero,
            showSign: false,
          ),

          const SizedBox(height: 4),

          Text(
            'Combined balance across liquid assets & liabilities',
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
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
                      ? Colors.white.withValues(alpha: 0.15)
                      : Colors.black.withValues(alpha: 0.10),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Assets',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '+${AppFormat.currency(assets)}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.semanticIncome,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 0.5,
                height: 28,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.08),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Liabilities',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '-${AppFormat.currency(liabilities)}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.semanticExpense,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Bank Account Row Item ───────────────────────────────────────

class _BankAccountRow extends StatelessWidget {
  final BankAccount account;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onConvertToCard;
  final VoidCallback onDelete;

  const _BankAccountRow({
    required this.account,
    required this.showDivider,
    required this.onTap,
    required this.onConvertToCard,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAsset = account.isAsset;
    final balanceColor = isAsset
        ? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary)
        : AppTheme.semanticExpense;

    final iconData = _iconForAccount(account.icon);
    final typeLabel = account.accountType.isNotEmpty
        ? account.accountType.toUpperCase()
        : 'BANK';

    return InkWell(
      onTap: onTap,
      splashColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                // Account Icon Pill
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue
                        .withValues(alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(
                      color: AppTheme.primaryBlue
                          .withValues(alpha: isDark ? 0.28 : 0.18),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    iconData,
                    size: 19,
                    color: AppTheme.primaryBlue,
                  ),
                ),
                const SizedBox(width: 12),

                // Name and Type
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            typeLabel,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppTheme.darkTextSecondary
                                  : AppTheme.lightTextSecondary,
                              letterSpacing: 0.3,
                            ),
                          ),
                          if (account.last4 != null && account.last4!.isNotEmpty) ...[
                            const SizedBox(width: 5),
                            Text(
                              '•',
                              style: TextStyle(
                                fontSize: 10,
                                color: isDark
                                    ? AppTheme.darkTextMuted
                                    : AppTheme.lightTextMuted,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '••${account.last4}',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? AppTheme.darkTextMuted
                                    : AppTheme.lightTextMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                // Exact Balance
                Text(
                  AppFormat.currency(account.balance),
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: balanceColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
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
                  : Colors.black.withValues(alpha: 0.06),
            ),
        ],
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

// ── Credit Card Row Item ────────────────────────────────────────

class _CreditCardRow extends StatelessWidget {
  final CreditCard card;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onConvertToAccount;
  final VoidCallback onDelete;

  const _CreditCardRow({
    required this.card,
    required this.showDivider,
    required this.onTap,
    required this.onConvertToAccount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final outstandingColor =
        card.usedAmount > 0 ? AppTheme.semanticExpense : AppTheme.primaryBlue;

    return InkWell(
      onTap: onTap,
      splashColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                // Card Icon Pill
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: outstandingColor
                        .withValues(alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(
                      color: outstandingColor
                          .withValues(alpha: isDark ? 0.30 : 0.20),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    Icons.credit_card_rounded,
                    size: 19,
                    color: outstandingColor,
                  ),
                ),
                const SizedBox(width: 12),

                // Name & Metadata
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        card.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            card.bank.isNotEmpty ? card.bank : 'Credit Card',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? AppTheme.darkTextSecondary
                                  : AppTheme.lightTextSecondary,
                            ),
                          ),
                          if (card.last4.isNotEmpty) ...[
                            const SizedBox(width: 5),
                            Text(
                              '•',
                              style: TextStyle(
                                fontSize: 10,
                                color: isDark
                                    ? AppTheme.darkTextMuted
                                    : AppTheme.lightTextMuted,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '••${card.last4}',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? AppTheme.darkTextMuted
                                    : AppTheme.lightTextMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                // Outstanding Balance & Limit
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      AppFormat.currency(card.usedAmount),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: outstandingColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Limit ${AppFormat.currency(card.limitAmount)}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isDark
                            ? AppTheme.darkTextMuted
                            : AppTheme.lightTextMuted,
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
                  : Colors.black.withValues(alpha: 0.06),
            ),
        ],
      ),
    );
  }
}

// ── Loan Row Item ───────────────────────────────────────────────

class _LoanRow extends StatelessWidget {
  final dynamic loan;
  final double remaining;
  final bool showDivider;
  final VoidCallback onTap;

  const _LoanRow({
    required this.loan,
    required this.remaining,
    required this.showDivider,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final loanName = (loan.name ?? 'Loan') as String;

    return InkWell(
      onTap: onTap,
      splashColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.semanticTransfer
                        .withValues(alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(
                      color: AppTheme.semanticTransfer
                          .withValues(alpha: isDark ? 0.28 : 0.18),
                      width: 0.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.account_balance_outlined,
                    size: 19,
                    color: AppTheme.semanticTransfer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        loanName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Total: ${AppFormat.currency((loan.total as num).toDouble())}',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      AppFormat.currency(remaining),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.semanticExpense,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Outstanding',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isDark
                            ? AppTheme.darkTextMuted
                            : AppTheme.lightTextMuted,
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
                  : Colors.black.withValues(alpha: 0.06),
            ),
        ],
      ),
    );
  }
}
