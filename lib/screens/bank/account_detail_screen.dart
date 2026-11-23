import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart' show cardsProvider;
import '../../features/accounts/providers/account_providers.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../models/bank_account.dart';
import '../../models/category.dart';
import '../../models/transaction.dart';
import '../../services/data_change_bus.dart';
import '../../services/haptic_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/glass/spendx_scaffold.dart';
import '../../utils/app_format.dart';
import '../../widgets/category_icon_picker.dart';
import '../transaction_detail_screen.dart';
import 'account_list_screen.dart' show resolveAccountDisplayName;
import 'add_bank_account_screen.dart';
import '../../services/live_sms_service.dart';
import '../../shared/widgets/glass/spendx_transaction_tile.dart' show cleanTransactionDisplayTitle;

/// SpendX Account Details & Transaction Ledger Screen.
///
/// Implements SpendX Visual Language Rulebook:
/// - Hero Balance Horizon for Bank & Liquid Cash accounts
/// - Real-time chronological transaction stream with date waypoints
/// - Running balances computed after each transaction
/// - High-clarity inflow (↙) vs outflow (↗) semantic differentiation
/// - Full interactive search & SpendX vocabulary filtering (Spent, Received, Moved)
/// - One-tap deep dive into UnifiedTransactionDetailScreen
class AccountDetailScreen extends ConsumerStatefulWidget {
  final BankAccount account;

  const AccountDetailScreen({
    super.key,
    required this.account,
  });

  @override
  ConsumerState<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends ConsumerState<AccountDetailScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  String _selectedFilter = 'all'; // 'all', 'spent', 'received', 'moved'
  String _searchQuery = '';
  VoidCallback? _busListener;

  @override
  void initState() {
    super.initState();
    _busListener = () {
      if (mounted) setState(() {});
    };
    DataChangeBus.instance.addListener(_busListener!);
  }

  @override
  void dispose() {
    if (_busListener != null) {
      DataChangeBus.instance.removeListener(_busListener!);
    }
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openEditAccount(BuildContext context, BankAccount acc) async {
    HapticService.instance.tap();
    final result = await Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => AddBankAccountScreen(existing: acc),
      ),
    );
    if (result == true && mounted) {
      ref.invalidate(accountsProvider);
      ref.invalidate(transactionsProvider);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accountsAsync = ref.watch(accountsProvider);
    final allTxnsAsync = ref.watch(transactionsProvider);
    final categoryMapAsync = ref.watch(transactionCategoryMapProvider);
    final cardsAsync = ref.watch(cardsProvider);

    // Keep live account reactive
    final currentAccount = accountsAsync.valueOrNull?.where((a) => a.id == widget.account.id).firstOrNull ?? widget.account;

    final accountsMap = <String, String>{
      for (final a in (accountsAsync.valueOrNull ?? []))
        a.id: resolveAccountDisplayName(a.name),
      for (final c in (cardsAsync.valueOrNull ?? []))
        c.id: resolveAccountDisplayName(c.name.isNotEmpty ? c.name : '${c.bank} Card'),
    };

    final allTxns = allTxnsAsync.valueOrNull ?? [];
    final categoriesMap = categoryMapAsync.valueOrNull ?? {};

    // 1. Filter transactions belonging exclusively to this account
    final accountTxns = allTxns.where((t) {
      return t.accountId == currentAccount.id || t.relatedEntityId == currentAccount.id;
    }).toList();

    // Sort descending by date (newest first)
    accountTxns.sort((a, b) => b.date.compareTo(a.date));

    // 2. Compute Running Balances starting from current balance
    final Map<String, double> runningBalances = {};
    double rolling = currentAccount.balance;
    for (final t in accountTxns) {
      runningBalances[t.id] = rolling;
      // Revert the transaction's effect to find balance before this transaction
      final bool isInflow = (t.isIncomeType && t.accountId == currentAccount.id) ||
          (t.isTransferType && t.relatedEntityId == currentAccount.id);
      final bool isOutflow = (t.isExpenseType && t.accountId == currentAccount.id) ||
          (t.isTransferType && t.accountId == currentAccount.id) ||
          (t.type == 'credit_payment' && t.accountId == currentAccount.id);

      if (isInflow) {
        rolling -= t.amount;
      } else if (isOutflow) {
        rolling += t.amount;
      }
    }

    // 3. Compute Totals for Header
    double totalInflow = 0;
    double totalOutflow = 0;
    for (final t in accountTxns) {
      final bool isInflow = (t.isIncomeType && t.accountId == currentAccount.id) ||
          (t.isTransferType && t.relatedEntityId == currentAccount.id);
      final bool isOutflow = (t.isExpenseType && t.accountId == currentAccount.id) ||
          (t.isTransferType && t.accountId == currentAccount.id) ||
          (t.type == 'credit_payment' && t.accountId == currentAccount.id);

      if (isInflow) totalInflow += t.amount;
      if (isOutflow) totalOutflow += t.amount;
    }

    // 4. Apply View Filters + Search
    final filteredTxns = accountTxns.where((t) {
      final bool isInflow = (t.isIncomeType && t.accountId == currentAccount.id) ||
          (t.isTransferType && t.relatedEntityId == currentAccount.id);
      final bool isOutflow = (t.isExpenseType && t.accountId == currentAccount.id) ||
          (t.isTransferType && t.accountId == currentAccount.id) ||
          (t.type == 'credit_payment' && t.accountId == currentAccount.id);

      final matchesType = switch (_selectedFilter) {
        'spent' => isOutflow && !t.isTransferType && t.type != 'credit_payment',
        'received' => isInflow && !t.isTransferType,
        'moved' => t.isTransferType || t.type == 'credit_payment',
        _ => true,
      };
      if (!matchesType) return false;

      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final noteMatch = t.notes.toLowerCase().contains(q);
        final cat = categoriesMap[t.categoryId];
        final catMatch = cat != null && cat.name.toLowerCase().contains(q);
        final toMatch = accountsMap[t.relatedEntityId]?.toLowerCase().contains(q) ?? false;
        final fromMatch = accountsMap[t.accountId]?.toLowerCase().contains(q) ?? false;
        final amountMatch = t.amount.toString().contains(q);
        if (!noteMatch && !catMatch && !toMatch && !fromMatch && !amountMatch) {
          return false;
        }
      }
      return true;
    }).toList();

    final isOverdrawn = currentAccount.balance < 0;
    final displayName = resolveAccountDisplayName(currentAccount.name);

    return SpendXScaffold(
      extendBody: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          displayName,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit Account',
            onPressed: () => _openEditAccount(context, currentAccount),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await LiveSmsService.instance.syncUpcomingObligationsFromInbox();
          ref.invalidate(accountsProvider);
          ref.invalidate(transactionsProvider);
          await Future.delayed(const Duration(milliseconds: 300));
        },
        color: AppTheme.primaryBlue,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ── Account Hero Card ─────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: isDark
                          ? [
                              const Color(0xFF1E2230),
                              const Color(0xFF131620),
                            ]
                          : [
                              const Color(0xFFFFFFFF),
                              const Color(0xFFFBF8F3),
                            ],
                    ),
                    border: Border.all(
                      color: isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFECE5D8),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isDark ? Colors.black.withValues(alpha: 0.3) : const Color(0x0C1C1917),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Subtitle & Pills
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDark ? const Color(0x254F46E5) : const Color(0xFFEEF2FF),
                            ),
                            child: Icon(
                              _iconForAccount(currentAccount),
                              size: 20,
                              color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayName,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${currentAccount.bank.isNotEmpty ? '${currentAccount.bank} • ' : ''}${currentAccount.accountType.replaceAll('_', ' ').toUpperCase()}${currentAccount.last4 != null ? ' (..${currentAccount.last4})' : ''}',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: isOverdrawn
                                  ? const Color(0xFFE11D48).withValues(alpha: isDark ? 0.22 : 0.12)
                                  : const Color(0xFF16A34A).withValues(alpha: isDark ? 0.22 : 0.12),
                            ),
                            child: Text(
                              isOverdrawn ? 'OVERDRAWN' : 'ACTIVE',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: isOverdrawn ? const Color(0xFFF43F5E) : const Color(0xFF16A34A),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Balance Horizon
                      Text(
                        'CURRENT BALANCE',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppFormat.currency(currentAccount.balance),
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          color: isOverdrawn
                              ? const Color(0xFFF43F5E)
                              : (isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A)),
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Inflow vs Outflow Horizon Stats
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: isDark ? const Color(0xFF151926) : const Color(0xFFF4F0E8),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.arrow_downward_rounded,
                                    size: 16,
                                    color: Color(0xFF16A34A),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'INFLOW',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.5,
                                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                                          ),
                                        ),
                                        Text(
                                          '+${AppFormat.currency(totalInflow)}',
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF16A34A),
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: isDark ? const Color(0xFF151926) : const Color(0xFFF4F0E8),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.arrow_upward_rounded,
                                    size: 16,
                                    color: Color(0xFFE11D48),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'OUTFLOW',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.5,
                                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                                          ),
                                        ),
                                        Text(
                                          '-${AppFormat.currency(totalOutflow)}',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: isDark ? const Color(0xFFFDA4AF) : const Color(0xFFE11D48),
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Inline Search & Filter Strip ─────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: [
                    // Search Bar
                    Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
                          width: 0.8,
                        ),
                      ),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (val) => setState(() => _searchQuery = val.trim()),
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white : const Color(0xFF1C1917),
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search in this account...',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E),
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 19,
                            color: isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E),
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                tooltip: 'Clear search',
                                  icon: const Icon(Icons.clear_rounded, size: 16),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Filter Chips (All, Spent, Received, Moved)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        children: [
                          _buildFilterChip(
                            label: 'All (${accountTxns.length})',
                            isSelected: _selectedFilter == 'all',
                            onTap: () => setState(() => _selectedFilter = 'all'),
                            isDark: isDark,
                          ),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                            label: 'Spent ↗',
                            isSelected: _selectedFilter == 'spent',
                            onTap: () => setState(() => _selectedFilter = 'spent'),
                            isDark: isDark,
                            activeColor: const Color(0xFFE11D48),
                          ),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                            label: 'Received ↙',
                            isSelected: _selectedFilter == 'received',
                            onTap: () => setState(() => _selectedFilter = 'received'),
                            isDark: isDark,
                            activeColor: const Color(0xFF16A34A),
                          ),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                            label: 'Moved ⇄',
                            isSelected: _selectedFilter == 'moved',
                            onTap: () => setState(() => _selectedFilter = 'moved'),
                            isDark: isDark,
                            activeColor: const Color(0xFF0284C7),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 10)),

            // ── Empty State ──────────────────────────────────
            if (filteredTxns.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
                        width: 0.8,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 40,
                          color: isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _searchQuery.isNotEmpty ? 'No matching transactions' : 'No transactions recorded yet',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Transactions impacting this account will stream here chronologically with running balances.',
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

            // ── Grouped Chronological Stream ─────────────────
            if (filteredTxns.isNotEmpty)
              ..._buildGroupedLedgerSlivers(
                filteredTxns,
                currentAccount,
                runningBalances,
                categoriesMap,
                accountsMap,
                isDark,
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required bool isDark,
    Color? activeColor,
  }) {
    final effectiveActiveBg = activeColor != null
        ? activeColor.withValues(alpha: isDark ? 0.28 : 0.16)
        : (isDark ? const Color(0xFF4F46E5) : const Color(0xFF1C1917));
    final effectiveActiveText = activeColor ?? (isDark ? Colors.white : Colors.white);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? effectiveActiveBg : (isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF)),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: isSelected
                ? (activeColor ?? (isDark ? Colors.white.withValues(alpha: 0.3) : const Color(0xFF1C1917)))
                : (isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8)),
            width: isSelected ? 1.0 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? effectiveActiveText : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupedLedgerSlivers(
    List<Transaction> transactions,
    BankAccount currentAccount,
    Map<String, double> runningBalances,
    Map<String, dynamic> categoriesMap,
    Map<String, String> accountsMap,
    bool isDark,
  ) {
    // Group transactions by calendar date
    final Map<String, List<Transaction>> grouped = {};
    for (final t in transactions) {
      final key = _formatDateHeader(t.date);
      grouped.putIfAbsent(key, () => []).add(t);
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: isDark ? const Color(0xFF161922) : const Color(0xFFFFFFFF),
              border: Border.all(
                color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE5D8),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark ? Colors.black.withValues(alpha: 0.25) : const Color(0x081C1917),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: grouped.entries.map((group) {
                final dateHeader = group.key;
                final txnsInGroup = group.value;
                final isToday = dateHeader.contains('TODAY');

                double daySpend = 0;
                double dayInflow = 0;
                for (final t in txnsInGroup) {
                  final bool isInflow = (t.isIncomeType && t.accountId == currentAccount.id) ||
                      (t.isTransferType && t.relatedEntityId == currentAccount.id);
                  if (isInflow) dayInflow += t.amount;
                  final bool isOutflow = (t.isExpenseType && t.accountId == currentAccount.id) ||
                      (t.isTransferType && t.accountId == currentAccount.id) ||
                      (t.type == 'credit_payment' && t.accountId == currentAccount.id);
                  if (isOutflow) daySpend += t.amount;
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Quiet Date Waypoint Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isToday ? AppTheme.primaryBlue : (isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            dateHeader,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              color: isToday ? AppTheme.primaryBlue : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
                            ),
                          ),
                          const Spacer(),
                          if (daySpend > 0)
                            Text(
                              '${AppFormat.currency(daySpend)} spent',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                              ),
                            )
                          else if (dayInflow > 0)
                            Text(
                              '+${AppFormat.currency(dayInflow)} received',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF16A34A),
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Transaction rows for this date
                    ...List.generate(txnsInGroup.length, (index) {
                      final t = txnsInGroup[index];
                      final isLast = index == txnsInGroup.length - 1;
                      final balAfter = runningBalances[t.id];

                      final bool isInflow = (t.isIncomeType && t.accountId == currentAccount.id) ||
                          (t.isTransferType && t.relatedEntityId == currentAccount.id);

                      final fromName = accountsMap[t.accountId] ?? (t.accountId != null ? resolveAccountDisplayName(t.accountId!) : '');
                      final toName = accountsMap[t.relatedEntityId] ?? (t.relatedEntityId != null ? resolveAccountDisplayName(t.relatedEntityId!) : '');

                      final String flowSub;
                      if (t.isTransferType || t.type == 'credit_payment') {
                        flowSub = t.accountId == currentAccount.id ? 'To: $toName' : 'From: $fromName';
                      } else {
                        flowSub = DateFormat('d MMM, hh:mm a').format(t.date);
                      }

                      final cat = categoriesMap[t.categoryId] as Category?;
                      final iconData = cat != null
                          ? CategoryIconPicker.iconForKey(cat.icon)
                          : (t.isTransferType ? Icons.swap_horiz_rounded : Icons.receipt_long_rounded);

                      return InkWell(
                        onTap: () async {
                          HapticService.instance.tap();
                          await Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => UnifiedTransactionDetailScreen(
                                transaction: t,
                                category: cat,
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: !isLast
                                  ? BorderSide(
                                      color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF0ECE4),
                                      width: 0.8,
                                    )
                                  : BorderSide.none,
                            ),
                          ),
                          child: Row(
                            children: [
                              // Category / Transfer Icon
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isInflow
                                      ? const Color(0xFF16A34A).withValues(alpha: isDark ? 0.20 : 0.12)
                                      : (isDark ? const Color(0xFF1E2230) : const Color(0xFFF1EDE6)),
                                ),
                                child: Icon(
                                  iconData,
                                  size: 19,
                                  color: isInflow
                                      ? const Color(0xFF16A34A)
                                      : (isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5)),
                                ),
                              ),
                              const SizedBox(width: 12),

                              // Description & Date / Flow
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      cleanTransactionDisplayTitle(
                                        t.notes,
                                        categoryName: cat?.name,
                                        isCcPayment: t.type == 'credit_payment',
                                        isTransfer: t.isTransferType,
                                        isIncome: t.isIncomeType,
                                      ),
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 3),
                                    Row(
                                      children: [
                                        Text(
                                          flowSub,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                                          ),
                                        ),
                                        if (t.isTransferType || t.type == 'credit_payment') ...[
                                          const SizedBox(width: 6),
                                          Text(
                                            '• ${DateFormat('hh:mm a').format(t.date)}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: isDark ? const Color(0xFF64748B) : const Color(0xFFA8A29E),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),

                              // Amount & Running Balance
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  () {
                                    final forex = AppFormat.extractForexFormatted(t.notes, t.rawPayload);
                                    final amtDisplay = forex != null
                                        ? (isInflow ? '+$forex' : '-$forex')
                                        : (isInflow ? '+${AppFormat.currency(t.amount)}' : '-${AppFormat.currency(t.amount)}');
                                    return Text(
                                      amtDisplay,
                                      style: TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w700,
                                        color: isInflow
                                            ? const Color(0xFF16A34A)
                                            : (isDark ? const Color(0xFFF1F5F9) : const Color(0xFF1C1917)),
                                      ),
                                    );
                                  }(),
                                  if (balAfter != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Bal: ${AppFormat.currency(balAfter)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: balAfter < 0
                                            ? const Color(0xFFF43F5E)
                                            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C)),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Divider(
                        height: 12,
                        thickness: 0.5,
                        color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF0ECE4),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    ];
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);

    final diffDays = today.difference(target).inDays;
    if (diffDays == 0) return 'TODAY';
    if (diffDays == 1) return 'YESTERDAY';

    if (date.year == now.year) {
      return DateFormat('EEEE, d MMMM').format(date).toUpperCase();
    }
    return DateFormat('d MMMM yyyy').format(date).toUpperCase();
  }

  IconData _iconForAccount(BankAccount acc) {
    if (acc.accountType == 'cash' || acc.id == 'acc_cash_default') {
      return Icons.payments_rounded;
    }
    if (acc.accountType == 'wallet') {
      return Icons.account_balance_wallet_rounded;
    }
    return Icons.account_balance_rounded;
  }
}
