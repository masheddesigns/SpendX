import '../../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart' as app_data;
import '../../features/accounts/providers/account_providers.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../credit_card/add_credit_card_screen.dart';
import '../loans/loans_screen.dart';
import '../../shared/widgets/empty_state_widget.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import 'add_bank_account_screen.dart';

class AccountListScreen extends ConsumerWidget {
  final bool isEmbedded;

  const AccountListScreen({super.key, this.isEmbedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final cardsAsync = ref.watch(creditCardsProvider);
    final loansAsync = ref.watch(loansProvider);

    return accountsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('Error: $error')),
      data: (accounts) => cardsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (cards) => loansAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Error: $error')),
          data: (loans) {
          if (accounts.isEmpty && cards.isEmpty) {
            return EmptyStateWidget(
              icon: Icons.account_balance_wallet_outlined,
              title: 'No accounts yet',
              description:
                  'Add your first account or credit card to start tracking balances.',
              ctaLabel: '+ Add Account',
              onCtaTap: () => _openAddAccount(context, ref),
            );
          }

          final content = RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(accountsProvider);
              ref.invalidate(creditCardsProvider);
            },
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.m),
              children: [
                _NetWorthSummary(
                  accounts: accounts,
                  cards: cards,
                  loans: loans,
                ),
                const SizedBox(height: AppSpacing.m),

                // ── Monthly Flow Row ──────────────────────────
                const _MonthlyFlowRow(),
                const SizedBox(height: AppSpacing.m),

                // ── Quick Add Row (compact) ────────────────────
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () { HapticService.instance.tap(); _openAddAccount(context, ref); },
                        icon: const Icon(Icons.account_balance_rounded, size: 16),
                        label: const Text('Account', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () { HapticService.instance.tap(); _openAddCreditCard(context, ref); },
                        icon: const Icon(Icons.credit_card_rounded, size: 16),
                        label: const Text('Card', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const LoansScreen())),
                        icon: const Icon(Icons.account_balance_outlined, size: 16),
                        label: const Text('Loan', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),

                // ── Bank Accounts ──────────────────────────────
                if (accounts.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sectionGap),
                  Text('Bank Accounts',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.sectionHeaderGap),
                  ...accounts.map(
                    (account) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.cardGap),
                      child: _AccountCard(
                        account: account,
                        onTap: () => _openEditAccount(context, ref, account),
                        onConvertToCard: () => _convertAccountToCard(context, ref, account),
                        onDelete: () => _deleteAccount(context, ref, account),
                      ),
                    ),
                  ),
                ],

                // ── Credit Cards ───────────────────────────────
                if (cards.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sectionGap),
                  Text('Credit Cards',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.sectionHeaderGap),
                  ...cards.map(
                    (card) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.cardGap),
                      child: _CreditCardItem(
                        card: card,
                        onTap: () => _openEditCreditCard(context, ref, card),
                        onConvertToAccount: () => _convertCardToAccount(context, ref, card),
                        onDelete: () => _deleteCard(context, ref, card),
                      ),
                    ),
                  ),
                ],
                if (loans.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sectionGap),
                  Row(
                    children: [
                      Text('Loans',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const LoansScreen())),
                        child: const Text('View All'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sectionHeaderGap),
                  ...loans.map((loan) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.cardGap),
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: CircleAvatar(
                              radius: 18,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .error
                                  .withValues(alpha: 0.12),
                              child: Icon(Icons.account_balance_rounded,
                                  color:
                                      Theme.of(context).colorScheme.error,
                                  size: 20),
                            ),
                            title: Text(loan.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(
                                '${AppFormat.currency(loan.paidAmount)} / ${AppFormat.currency(loan.total)}'
                                '\nStarted ${loan.startDate.day}/${loan.startDate.month}/${loan.startDate.year}'),
                            isThreeLine: true,
                            trailing: Text(
                                AppFormat.currency(
                                    (loan.total - loan.paidAmount)
                                        .clamp(0, double.infinity)),
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error,
                                    fontWeight: FontWeight.w600)),
                            onTap: () => Navigator.push(context,
                                MaterialPageRoute(
                                    builder: (_) => const LoansScreen())),
                          ),
                        ),
                      )),
                ],
              ],
            ),
          );

          if (isEmbedded) {
            return content;
          }

          return Scaffold(
            appBar: AppBar(title: const Text('Accounts')),
            body: SafeArea(child: content),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () { HapticService.instance.tap(); _openAddAccount(context, ref); },
              icon: const Icon(Icons.add),
              label: const Text('Add Account'),
            ),
          );
        },
      ),
      ),
    );
  }

  Future<void> _openAddAccount(BuildContext context, WidgetRef ref) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddBankAccountScreen()),
    );
    if (result == true) {
      ref.invalidate(accountsProvider);
    }
  }

  Future<void> _openEditAccount(
    BuildContext context,
    WidgetRef ref,
    BankAccount account,
  ) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddBankAccountScreen(existing: account)),
    );
    if (result == true) {
      ref.invalidate(accountsProvider);
    }
  }

  Future<void> _openAddCreditCard(BuildContext context, WidgetRef ref) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddCreditCardScreen()),
    );
    if (result == true) {
      ref.invalidate(creditCardsProvider);
    }
  }

  Future<void> _openEditCreditCard(
    BuildContext context,
    WidgetRef ref,
    CreditCard card,
  ) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddCreditCardScreen(existingCard: card),
      ),
    );
    if (result == true) {
      ref.invalidate(creditCardsProvider);
      return;
    }
    if (result == CreditCardFormAction.deleted) {
      await ref.read(app_data.cardsProvider.notifier).remove(card.id);
      ref.invalidate(creditCardsProvider);
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
          'Convert "${account.name}" from a bank account to a credit card? '
          'You can edit the card details after conversion.',
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
    if (!context.mounted) return;

    // Open the new card for editing
    final cards = await repo.getCards();
    final newCard = cards.where((c) => c.id == newCardId).firstOrNull;
    if (newCard != null && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AddCreditCardScreen(existingCard: newCard),
        ),
      );
      ref.invalidate(creditCardsProvider);
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
          'Convert "${card.name}" from a credit card to a bank account? '
          'You can edit the account details after conversion.',
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
    if (!context.mounted) return;

    // Open the new account for editing
    final newAccount = await repo.getById(newAccountId);
    if (newAccount != null && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AddBankAccountScreen(existing: newAccount),
        ),
      );
      ref.invalidate(accountsProvider);
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
    }
  }

}

class _NetWorthSummary extends StatelessWidget {
  final List<BankAccount> accounts;
  final List<CreditCard> cards;
  final List<dynamic> loans;

  const _NetWorthSummary({
    required this.accounts,
    required this.cards,
    required this.loans,
  });

  @override
  Widget build(BuildContext context) {
    final assets = accounts
        .where((a) => a.isAsset)
        .fold<double>(0, (sum, a) => sum + a.balance);
    final accountLiabilities = accounts
        .where((a) => !a.isAsset)
        .fold<double>(0, (sum, a) => sum + a.balance.abs());
    final cardOutstanding = cards.fold<double>(
      0,
      (sum, c) => sum + c.usedAmount,
    );
    final loanOutstanding = loans.fold<double>(
      0,
      (sum, loan) => sum + ((loan.total as num) - (loan.paidAmount as num)).toDouble().clamp(0, double.infinity),
    );
    final liabilities = accountLiabilities + cardOutstanding + loanOutstanding;
    final netWorth = assets - liabilities;

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isPositive = netWorth >= 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1D2E) : const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? cs.primary.withValues(alpha: 0.2)
              : cs.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Net Worth',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            AppFormat.currency(netWorth),
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: isPositive ? cs.primary : cs.error,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0D2818)
                        : const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Assets',
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 11)),
                      const SizedBox(height: 4),
                      Text(AppFormat.currency(assets),
                          style: TextStyle(
                              color: isDark
                                  ? const Color(0xFF4CAF50)
                                  : const Color(0xFF2E7D32),
                              fontWeight: FontWeight.w700,
                              fontSize: 15)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF2D1215)
                        : const Color(0xFFFCE4EC),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Liabilities',
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 11)),
                      const SizedBox(height: 4),
                      Text(AppFormat.currency(liabilities),
                          style: TextStyle(
                              color: isDark
                                  ? const Color(0xFFEF5350)
                                  : const Color(0xFFC62828),
                              fontWeight: FontWeight.w700,
                              fontSize: 15)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

// _BucketChip and _BucketData removed — data shown on home page instead

class _AccountCard extends StatelessWidget {
  final BankAccount account;
  final VoidCallback? onTap;
  final VoidCallback? onConvertToCard;
  final VoidCallback? onDelete;

  const _AccountCard({
    required this.account,
    this.onTap,
    this.onConvertToCard,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final amountColor = account.balance >= 0
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    final needsReview = _needsReview(account.name);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: AppSpacing.cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: amountColor.withValues(alpha: 0.12),
                    child: Icon(_iconForAccount(account.icon), color: amountColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(account.name, style: Theme.of(context).textTheme.titleSmall),
                        Text(
                          account.bank.isEmpty ? account.accountType : account.bank,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    AppFormat.currency(account.balance),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: amountColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (needsReview) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 14,
                      color: Theme.of(context).colorScheme.tertiary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Imported — is this a bank account or credit card?',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _ReviewActionChip(
                      icon: Icons.edit_outlined,
                      label: 'Edit',
                      onTap: onTap,
                    ),
                    const SizedBox(width: 8),
                    _ReviewActionChip(
                      icon: Icons.credit_card_rounded,
                      label: 'Convert to Card',
                      onTap: onConvertToCard,
                    ),
                    const SizedBox(width: 8),
                    _ReviewActionChip(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      onTap: onDelete,
                      isDestructive: true,
                    ),
                  ],
                ),
              ],
            ],
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
      case 'account_balance_wallet':
        return Icons.account_balance_wallet_rounded;
      default:
        return Icons.account_balance_rounded;
    }
  }

  bool _needsReview(String name) {
    final lower = name.toLowerCase();
    final hasLast4 = RegExp(r'\b\d{4}\b').hasMatch(lower);
    return (lower.contains('account') || lower.contains('imported')) && !hasLast4;
  }
}

// _AccountActionsRow removed — replaced with inline FilledButton.tonalIcon row

class _CreditCardItem extends StatelessWidget {
  final CreditCard card;
  final VoidCallback? onTap;
  final VoidCallback? onConvertToAccount;
  final VoidCallback? onDelete;

  const _CreditCardItem({
    required this.card,
    this.onTap,
    this.onConvertToAccount,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final outstandingColor = card.usedAmount > 0
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    final needsReview = _needsReview(card);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: AppSpacing.cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: outstandingColor.withValues(alpha: 0.12),
                    child: Icon(Icons.credit_card_rounded, color: outstandingColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(card.name, style: Theme.of(context).textTheme.titleSmall),
                        Text(
                          '${card.bank.isEmpty ? 'Credit Card' : card.bank} • ${card.last4}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        AppFormat.currency(card.usedAmount),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: outstandingColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Limit ${AppFormat.currency(card.limitAmount)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
              if (needsReview) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 14,
                      color: Theme.of(context).colorScheme.tertiary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Imported — is this a credit card or bank account?',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _ReviewActionChip(
                      icon: Icons.edit_outlined,
                      label: 'Edit',
                      onTap: onTap,
                    ),
                    const SizedBox(width: 8),
                    _ReviewActionChip(
                      icon: Icons.account_balance_rounded,
                      label: 'Convert to Account',
                      onTap: onConvertToAccount,
                    ),
                    const SizedBox(width: 8),
                    _ReviewActionChip(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      onTap: onDelete,
                      isDestructive: true,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool _needsReview(CreditCard card) {
    final lower = card.name.toLowerCase();
    return (card.last4 == '0000' || !RegExp(r'^\d{4}$').hasMatch(card.last4)) &&
        lower.contains('credit card');
  }
}

class _ReviewActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool isDestructive;

  const _ReviewActionChip({
    required this.icon,
    required this.label,
    this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.m),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.m),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Monthly Flow Row (connects transactions → accounts) ─────────────────

class _MonthlyFlowRow extends ConsumerWidget {
  const _MonthlyFlowRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(app_data.analyticsSummaryProvider);
    final cs = Theme.of(context).colorScheme;
    final income = summary.monthlyIncome;
    final expense = summary.monthlyExpense;
    final net = income - expense;

    return Row(
      children: [
        Expanded(child: _FlowChip('Income', AppFormat.currency(income), Colors.green)),
        const SizedBox(width: 8),
        Expanded(child: _FlowChip('Expense', AppFormat.currency(expense), cs.error)),
        const SizedBox(width: 8),
        Expanded(child: _FlowChip('Net', '${net >= 0 ? "+" : ""}${AppFormat.currency(net)}',
            net >= 0 ? Colors.blue : cs.error)),
      ],
    );
  }
}

class _FlowChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _FlowChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
