import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import '../services/settings_service.dart';
import '../data/providers.dart';
import '../models/bank_account.dart';
import '../models/credit_card.dart';
import '../models/lending.dart';
import '../models/loan.dart';
import '../models/net_worth_snapshot_record.dart';
import '../utils/app_format.dart';
import '../utils/text_formatter.dart';
import '../shared/widgets/skeleton_loader.dart';
import '../shared/widgets/error_state_widget.dart';
import '../shared/widgets/undo_snackbar_listener.dart';
import '../features/liabilities/providers/liabilities_providers.dart'
    show lendingProvider;
import 'bank/add_bank_account_screen.dart';
import 'bank/account_detail_screen.dart';
import 'net_worth/net_worth_report_screen.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/glass/spendx_scaffold.dart';
import '../shared/widgets/glass/spendx_glass_surface.dart';
import '../shared/widgets/glass/spendx_glass_button.dart';
import '../shared/widgets/spendx_app_bar.dart';
import '../theme/app_theme.dart';
import 'bank/account_list_screen.dart' show resolveAccountDisplayName;
import 'expense/add_expense_screen.dart';

class NetWorthScreen extends ConsumerStatefulWidget {
  const NetWorthScreen({super.key});

  @override
  ConsumerState<NetWorthScreen> createState() => _NetWorthScreenState();
}

class _NetWorthScreenState extends ConsumerState<NetWorthScreen> {
  Future<void> _refreshData() async {
    await Future.wait<void>([
      ref.read(accountsProvider.notifier).refresh(),
      ref.read(cardsProvider.notifier).refresh(),
      ref.read(loansProvider.notifier).refresh(),
      ref.read(netWorthHistoryProvider.notifier).refresh(),
    ]);
  }

  Future<void> _captureSnapshot() async {
    DateTime selectedDate = DateTime.now();
    TimeOfDay selectedTime = TimeOfDay.now();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInnerState) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          title: const Text('Record Net Worth Snapshot'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Capture current net worth state with custom time.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                title: Text(DateFormat('dd MMM yyyy').format(selectedDate)),
                leading: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setInnerState(() => selectedDate = picked);
                  }
                },
              ),
              ListTile(
                title: Text(selectedTime.format(context)),
                leading: const Icon(Icons.access_time),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: selectedTime,
                  );
                  if (picked != null) {
                    setInnerState(() => selectedTime = picked);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Capture'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final finalTimestamp = DateTime(
        selectedDate.year,
        selectedDate.month,
        selectedDate.day,
        selectedTime.hour,
        selectedTime.minute,
      );

      final summary = ref.read(netWorthSummaryProvider).value;
      if (summary == null) return;

      await ref
          .read(netWorthHistoryProvider.notifier)
          .add(
            NetWorthSnapshotRecord(
              id: const Uuid().v4(),
              netWorth: summary.netWorth,
              assets: summary.assets,
              liabilities: summary.liabilities,
              timestamp: finalTimestamp,
            ),
          );
      await SettingsService.instance.setNetWorthLastUpdated(finalTimestamp);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('✓ Snapshot captured!')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsService>();
    final accountsAsync = ref.watch(accountsProvider);
    final cardsAsync = ref.watch(cardsProvider);
    final loansAsync = ref.watch(loansProvider);
    final summaryAsync = ref.watch(netWorthSummaryProvider);
    final lendingState = ref.watch(lendingProvider);
    final lendings = [
      ...lendingState.activeItems,
      ...lendingState.settledItems,
    ];
    final accounts = accountsAsync.valueOrNull ?? const <BankAccount>[];
    final cards = cardsAsync.valueOrNull ?? const <CreditCard>[];
    final loans = loansAsync.valueOrNull ?? const <Loan>[];
    final totalLiabilities = summaryAsync.valueOrNull?.liabilities ?? 0.0;

    final liquidAccounts = accounts
        .where(
          (a) =>
              a.isAsset &&
              !const [
                'stock',
                'mutual_fund',
                'gold',
                'real_estate',
                'ppf',
              ].contains(a.accountType),
        )
        .toList();
    final investmentAccounts = accounts
        .where(
          (a) =>
              a.isAsset &&
              const [
                'stock',
                'mutual_fund',
                'gold',
                'real_estate',
                'ppf',
              ].contains(a.accountType),
        )
        .toList();
    final totalLiquid = liquidAccounts.fold<double>(
      0.0,
      (s, a) => s + a.balance,
    );
    final totalInvestments = investmentAccounts.fold<double>(
      0.0,
      (s, a) => s + a.balance,
    );

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is BankAccount || payload is CreditCard,
      onUndone: (_) => _refreshData(),
    );

    if (accountsAsync.isLoading ||
        cardsAsync.isLoading ||
        loansAsync.isLoading) {
      return const Scaffold(body: SkeletonLoader.summary());
    }

    if (accountsAsync.hasError || cardsAsync.hasError || loansAsync.hasError) {
      final err = accountsAsync.error ?? cardsAsync.error ?? loansAsync.error;
      return Scaffold(
        appBar: AppBar(title: const Text('Net Worth')),
        body: ErrorStateWidget(
          error: err ?? 'Failed to load',
          title: 'Failed to calculate net worth',
          onRetry: _refreshData,
        ),
      );
    }

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: 'Net Worth',
        actions: [
          IconButton(
            icon: Icon(
              Icons.history_rounded,
              size: 20,
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkTextPrimary
                  : AppTheme.lightTextPrimary,
            ),
            tooltip: 'Detailed History',
            onPressed: () => Navigator.push(
              context,
              AppPageRoute(builder: (_) => NetWorthReportScreen()),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.camera_alt_outlined,
              size: 20,
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkTextPrimary
                  : AppTheme.lightTextPrimary,
            ),
            tooltip: 'Record Snapshot',
            onPressed: _captureSnapshot,
          ),
          IconButton(
            icon: const Icon(
              Icons.add_rounded,
              size: 22,
              color: AppTheme.primaryBlue,
            ),
            tooltip: 'Add Account',
            onPressed: () async {
              final res = await Navigator.push(
                context,
                AppPageRoute(builder: (_) => AddBankAccountScreen()),
              );
              if (res == true) {
                _refreshData();
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshData,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // ─── Liquid Glass Solvency Hero ───
              SliverToBoxAdapter(child: _buildNetWorthHero()),

              // ─── Investments Guiding Banner ───
              SliverToBoxAdapter(child: _buildInvestmentsGuidanceCard(context)),

              // ─── Liquid Cash & Bank Accounts ───
              SliverToBoxAdapter(
                child: _buildSectionHeader(
                  'Liquid Accounts & Cash',
                  totalLiquid,
                  AppTheme.semanticIncome,
                  isAsset: true,
                ),
              ),

              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _buildAccountTile(liquidAccounts[i]),
                  childCount: liquidAccounts.length,
                ),
              ),

              if (liquidAccounts.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      'No liquid accounts added yet. Tap + to add bank or cash.',
                      style: TextStyle(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppTheme.darkTextMuted
                            : AppTheme.lightTextMuted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),

              // ─── Investments & Wealth Portfolio ───
              SliverToBoxAdapter(
                child: _buildSectionHeader(
                  'Investments & Portfolio',
                  totalInvestments,
                  Theme.of(context).colorScheme.primary,
                  isAsset: true,
                ),
              ),

              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _buildAccountTile(investmentAccounts[i]),
                  childCount: investmentAccounts.length,
                ),
              ),

              if (investmentAccounts.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      'No investment accounts tracked. Tap "+ Mutual Funds" or "+ Stocks" above to track your portfolio value.',
                      style: TextStyle(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppTheme.darkTextMuted
                            : AppTheme.lightTextMuted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),

              // ─── Liabilities Section ───
              SliverToBoxAdapter(
                child: _buildSectionHeader(
                  'Liabilities & Debt',
                  totalLiabilities,
                  AppTheme.semanticExpense,
                  isAsset: false,
                ),
              ),

              // Credit card outstanding
              if (cards.where((c) => c.outstanding > 0).isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate((ctx, i) {
                    final activeCards = cards
                        .where((c) => c.outstanding > 0)
                        .toList();
                    return _buildCcLiabilityTile(activeCards[i]);
                  }, childCount: cards.where((c) => c.outstanding > 0).length),
                ),

              // Borrowed lendings
              if (lendings.where((l) => l.type == 'borrowed').isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final loan = lendings
                          .where((l) => l.type == 'borrowed')
                          .toList()[i];
                      return _buildLendingLiabilityTile(loan);
                    },
                    childCount: lendings
                        .where((l) => l.type == 'borrowed')
                        .length,
                  ),
                ),

              // Bank Loans
              if (loans.isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _buildActualLoanTile(loans[i]),
                    childCount: loans.length,
                  ),
                ),

              if (totalLiabilities == 0)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.semanticIncome.withValues(alpha: 0.2),
                          width: 0.75,
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline_rounded,
                            size: 16,
                            color: AppTheme.semanticIncome,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '100% Debt-Free! Zero active liabilities 🎉',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.semanticIncome,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetWorthHero() {
    final summary = ref.watch(netWorthSummaryProvider);

    return summary.when(
      data: (data) {
        final isSolvent = data.netWorth >= 0;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final nonNegativeAssets = data.assets < 0 ? 0.0 : data.assets;
        final totalCapital = nonNegativeAssets + data.liabilities;
        final double assetPct = totalCapital > 0
            ? (nonNegativeAssets / totalCapital).clamp(0.0, 1.0)
            : 1.0;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.elevated,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'TOTAL NET WORTH',
                      style: TextStyle(
                        color: context.textMuted,
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isSolvent
                            ? const Color(0x1F10B981)
                            : const Color(0x1FEF4444),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSolvent
                              ? const Color(0x4010B981)
                              : const Color(0x40EF4444),
                          width: 0.75,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isSolvent
                                ? Icons.verified_rounded
                                : Icons.warning_amber_rounded,
                            size: 13,
                            color: isSolvent
                                ? AppTheme.semanticIncome
                                : AppTheme.semanticExpense,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isSolvent ? 'Solvent' : 'Debt Exceeds Assets',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isSolvent
                                  ? AppTheme.semanticIncome
                                  : AppTheme.semanticExpense,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${data.netWorth < 0 ? '-' : ''}${AppFormat.currency(data.netWorth.abs())}',
                  style: TextStyle(
                    color: isSolvent
                        ? (Theme.of(context).colorScheme.onSurface)
                        : AppTheme.semanticExpense,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: -1.0,
                  ),
                ),
                if (SettingsService.instance.netWorthLastUpdated != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Synced ${DateFormat('dd MMM, hh:mm a').format(SettingsService.instance.netWorthLastUpdated!)}',
                      style: TextStyle(
                        color: context.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),

                // Solvency Split Progress Bar
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Assets ${(assetPct * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.semanticIncome,
                          ),
                        ),
                        if (data.liabilities > 0)
                          Text(
                            'Liabilities ${((1.0 - assetPct) * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.semanticExpense,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        height: 7,
                        width: double.infinity,
                        color: isDark
                            ? const Color(0x22FFFFFF)
                            : const Color(0x18000000),
                        child: Row(
                          children: [
                            Expanded(
                              flex: (assetPct * 1000).round().clamp(1, 999),
                              child: Container(color: AppTheme.semanticIncome),
                            ),
                            if (data.liabilities > 0)
                              Expanded(
                                flex: (((1.0 - assetPct) * 1000).round()).clamp(
                                  1,
                                  999,
                                ),
                                child: Container(
                                  color: AppTheme.semanticExpense,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Two stats boxes
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.semanticIncome.withValues(
                            alpha: isDark ? 0.12 : 0.08,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppTheme.semanticIncome.withValues(
                              alpha: isDark ? 0.25 : 0.15,
                            ),
                            width: 0.75,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 14,
                                  color: AppTheme.semanticIncome,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Total Assets',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: context.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              AppFormat.currency(nonNegativeAssets),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [FontFeature.tabularFigures()],
                                color: AppTheme.semanticIncome,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.semanticExpense.withValues(
                            alpha: isDark ? 0.12 : 0.08,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppTheme.semanticExpense.withValues(
                              alpha: isDark ? 0.25 : 0.15,
                            ),
                            width: 0.75,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.arrow_downward_rounded,
                                  size: 14,
                                  color: AppTheme.semanticExpense,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Total Liabilities',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: context.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              AppFormat.currency(data.liabilities),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [FontFeature.tabularFigures()],
                                color: AppTheme.semanticExpense,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Quick Action Button: Move Funds
                Row(
                  children: [
                    Expanded(
                      child: SpendXGlassButton(
                        variant: SpendXGlassButtonVariant.tonal,
                        onPressed: () async {
                          final res = await Navigator.push(
                            context,
                            AppPageRoute(
                              builder: (_) => const AddExpenseScreen(
                                initialType: 'transfer',
                              ),
                            ),
                          );
                          if (res == true) _refreshData();
                        },
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.swap_horiz_rounded,
                              size: 16,
                              color: AppTheme.primaryBlue,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Move Funds',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
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
        );
      },
      loading: () => const SkeletonLoader.summary(),
      error: (e, _) => Center(child: Text('$e')),
    );
  }

  Widget _buildSectionHeader(
    String title,
    double total,
    Color color, {
    required bool isAsset,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              AppFormat.currency(isAsset ? (total < 0 ? 0 : total) : total),
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildInvestmentsGuidanceCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? const <BankAccount>[];
    final hasInvestments = accounts.any(
      (a) =>
          a.isAsset &&
          const [
            'stock',
            'mutual_fund',
            'gold',
            'real_estate',
            'ppf',
          ].contains(a.accountType),
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [
                  const Color(0xFF1E1B4B).withValues(alpha: 0.6),
                  const Color(0xFF0F172A).withValues(alpha: 0.8),
                ]
              : [Theme.of(context).colorScheme.primaryContainer, const Color(0xFFF8FAFC)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child:  Icon(
                  Icons.auto_graph_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasInvestments
                          ? 'Your Investment Portfolio'
                          : 'Complete Your Net Worth',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasInvestments
                          ? 'Track & update current market values for stocks, mutual funds & gold'
                          : 'Bank SMS only covers cash. Add your stocks, mutual funds, EPF & gold to track your true wealth.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: context.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildQuickAddPill(
                context,
                label: 'Mutual Funds',
                icon: Icons.pie_chart_outline_rounded,
                type: 'mutual_fund',
                color: const Color(0xFFEC4899),
              ),
              _buildQuickAddPill(
                context,
                label: 'Stocks',
                icon: Icons.trending_up_rounded,
                type: 'stock',
                color: Theme.of(context).colorScheme.secondary,
              ),
              _buildQuickAddPill(
                context,
                label: 'Gold',
                icon: Icons.monetization_on_outlined,
                type: 'gold',
                color: Theme.of(context).colorScheme.tertiary,
              ),
              _buildQuickAddPill(
                context,
                label: 'EPF / PPF',
                icon: Icons.savings_outlined,
                type: 'ppf',
                color: const Color(0xFF06B6D4),
              ),
              _buildQuickAddPill(
                context,
                label: 'Real Estate',
                icon: Icons.home_work_outlined,
                type: 'real_estate',
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAddPill(
    BuildContext context, {
    required String label,
    required IconData icon,
    required String type,
    required Color color,
  }) {
    return InkWell(
      onTap: () async {
        final res = await Navigator.push(
          context,
          AppPageRoute(builder: (_) => AddBankAccountScreen(initialType: type)),
        );
        if (res == true) {
          _refreshData();
        }
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              '+ $label',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountTile(BankAccount a) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final displayName = resolveAccountDisplayName(a.name);
    final isCash =
        a.id == 'acc_cash_default' ||
        a.accountType.toLowerCase().contains('cash') ||
        a.name.toLowerCase().contains('cash');

    IconData iconData;
    Color tileColor;
    switch (a.accountType) {
      case 'stock':
        iconData = Icons.trending_up_rounded;
        tileColor = Theme.of(context).colorScheme.secondary;
        break;
      case 'mutual_fund':
        iconData = Icons.pie_chart_rounded;
        tileColor = const Color(0xFFEC4899);
        break;
      case 'gold':
        iconData = Icons.monetization_on_rounded;
        tileColor = Theme.of(context).colorScheme.tertiary;
        break;
      case 'ppf':
        iconData = Icons.savings_rounded;
        tileColor = const Color(0xFF06B6D4);
        break;
      case 'real_estate':
        iconData = Icons.home_work_rounded;
        tileColor = Theme.of(context).colorScheme.primary;
        break;
      case 'fd':
        iconData = Icons.lock_clock_rounded;
        tileColor = Theme.of(context).colorScheme.tertiary;
        break;
      case 'cash':
        iconData = Icons.payments_rounded;
        tileColor = AppTheme.semanticIncome;
        break;
      case 'wallet':
        iconData = Icons.account_balance_wallet_rounded;
        tileColor = Theme.of(context).colorScheme.primary;
        break;
      case 'current':
        iconData = Icons.business_center_rounded;
        tileColor = const Color(0xFF3B82F6);
        break;
      default:
        iconData = isCash
            ? Icons.payments_rounded
            : Icons.account_balance_rounded;
        tileColor = isCash ? AppTheme.semanticIncome : AppTheme.primaryBlue;
    }

    final bankName = isCash
        ? 'Physical Cash'
        : ([
                'stock',
                'mutual_fund',
                'gold',
                'real_estate',
                'ppf',
              ].contains(a.accountType)
              ? (a.bank.isNotEmpty && a.bank != a.name
                    ? TextFormatter.toSmartTitleCase(a.bank)
                    : 'Portfolio Asset')
              : (a.bank == 'acc_cash_default'
                    ? 'Bank Account'
                    : TextFormatter.toSmartTitleCase(a.bank)));

    final isInvestment = const [
      'stock',
      'mutual_fund',
      'gold',
      'real_estate',
      'ppf',
    ].contains(a.accountType);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SpendXGlassSurface(
        width: double.infinity,
        level: SpendXGlassLevel.base,
        borderRadius: BorderRadius.circular(AppRadius.m),
        padding: const EdgeInsets.all(14),
        child: InkWell(
          onTap: () {
            if (isInvestment) {
              _showUpdateAssetValuationSheet(a);
            } else {
              Navigator.push(
                context,
                AppPageRoute(builder: (_) => AccountDetailScreen(account: a)),
              );
            }
          },
          onLongPress: () => _showAccountMenu(a),
          borderRadius: BorderRadius.circular(AppRadius.m),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: tileColor.withValues(alpha: isDark ? 0.20 : 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(iconData, color: tileColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$bankName • ${TextFormatter.toSmartTitleCase(a.accountType)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: context.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    a.balance < 0
                        ? 'Overdrawn: ${AppFormat.currency(a.balance.abs())}'
                        : AppFormat.currency(a.balance),
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: a.balance < 0
                          ? Theme.of(context).colorScheme.tertiary
                          : (context.textPrimary),
                    ),
                  ),
                  if (isInvestment) ...[
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined, size: 10.5, color: tileColor),
                        const SizedBox(width: 3),
                        Text(
                          'Update',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: tileColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCcLiabilityTile(CreditCard c) {
    if (c.outstanding <= 0) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardName = resolveAccountDisplayName(
      c.name.isNotEmpty ? c.name : '${c.bank} Credit Card',
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SpendXGlassSurface(
        width: double.infinity,
        level: SpendXGlassLevel.base,
        borderRadius: BorderRadius.circular(AppRadius.m),
        padding: const EdgeInsets.all(14),
        child: InkWell(
          onTap: () async {
            final res = await Navigator.push(
              context,
              AppPageRoute(
                builder: (_) => const AddExpenseScreen(initialType: 'transfer'),
              ),
            );
            if (res == true) _refreshData();
          },
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.semanticExpense.withValues(
                    alpha: isDark ? 0.20 : 0.12,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.credit_card_rounded,
                  color: AppTheme.semanticExpense,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cardName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${c.bank} • ••${c.last4}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: context.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '−${AppFormat.currency(c.usedAmount)}',
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                      color: AppTheme.semanticExpense,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Tap to pay bill',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLendingLiabilityTile(Lending l) {
    final remaining = l.originalAmount - l.paidAmount;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SpendXGlassSurface(
        width: double.infinity,
        level: SpendXGlassLevel.base,
        borderRadius: BorderRadius.circular(AppRadius.m),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.tertiary.withValues(alpha: isDark ? 0.20 : 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child:  Icon(
                Icons.handshake_rounded,
                color: Theme.of(context).colorScheme.tertiary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Borrowed from ${TextFormatter.toSmartTitleCase(l.personName)}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Peer Borrowing • Repayment Due',
                    style: TextStyle(fontSize: 11.5, color: context.textMuted),
                  ),
                ],
              ),
            ),
            Text(
              '−${AppFormat.currency(remaining)}',
              style:  TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showUpdateAssetValuationSheet(BankAccount a) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ctrl = TextEditingController(
      text: a.balance == a.balance.roundToDouble()
          ? a.balance.toStringAsFixed(0)
          : a.balance.toStringAsFixed(2),
    );
    final initialBalance = a.balance;

    Color assetColor;
    IconData assetIcon;
    switch (a.accountType) {
      case 'stock':
        assetIcon = Icons.trending_up_rounded;
        assetColor = Theme.of(context).colorScheme.secondary;
        break;
      case 'mutual_fund':
        assetIcon = Icons.pie_chart_rounded;
        assetColor = const Color(0xFFEC4899);
        break;
      case 'gold':
        assetIcon = Icons.monetization_on_rounded;
        assetColor = Theme.of(context).colorScheme.tertiary;
        break;
      case 'ppf':
        assetIcon = Icons.savings_rounded;
        assetColor = const Color(0xFF06B6D4);
        break;
      case 'real_estate':
        assetIcon = Icons.home_work_rounded;
        assetColor = Theme.of(context).colorScheme.primary;
        break;
      default:
        assetIcon = Icons.account_balance_rounded;
        assetColor = AppTheme.primaryBlue;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final enteredVal =
                double.tryParse(ctrl.text.trim()) ?? initialBalance;
            final diff = enteredVal - initialBalance;
            final isDiffNonZero = diff.abs() >= 0.01;
            final isPositive = diff > 0;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E222D) : Colors.white,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 20,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white24 : Colors.black12,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: assetColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(assetIcon, color: assetColor, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                resolveAccountDisplayName(a.name),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${TextFormatter.toSmartTitleCase(a.accountType)} • Current: ${AppFormat.currency(initialBalance)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.more_vert_rounded),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showAccountMenu(a);
                          },
                          tooltip: 'More options',
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'UPDATED PORTFOLIO VALUATION',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: context.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        prefixText: '₹ ',
                        prefixStyle: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: assetColor,
                        ),
                        filled: true,
                        fillColor: isDark
                            ? const Color(0xFF141822)
                            : const Color(0xFFF1F5F9),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      onChanged: (_) => setSheetState(() {}),
                    ),
                    if (isDiffNonZero) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            isPositive
                                ? Icons.trending_up_rounded
                                : Icons.trending_down_rounded,
                            size: 16,
                            color: isPositive
                                ? AppTheme.semanticIncome
                                : AppTheme.semanticExpense,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${isPositive ? '+' : '-'}${AppFormat.currency(diff.abs())} change from previous',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isPositive
                                  ? AppTheme.semanticIncome
                                  : AppTheme.semanticExpense,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Quick Adjustments',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: context.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final delta in [
                          5000.0,
                          10000.0,
                          25000.0,
                          50000.0,
                          100000.0,
                        ])
                          InkWell(
                            onTap: () {
                              final curr =
                                  double.tryParse(ctrl.text.trim()) ??
                                  initialBalance;
                              final next = curr + delta;
                              ctrl.text = next == next.roundToDouble()
                                  ? next.toStringAsFixed(0)
                                  : next.toStringAsFixed(2);
                              setSheetState(() {});
                            },
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0x1AFFFFFF)
                                    : const Color(0xFFE2E8F0),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                '+₹${(delta / 1000).toStringAsFixed(0)}k',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? Colors.white70
                                      : const Color(0xFF334155),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SpendXGlassButton(
                      variant: SpendXGlassButtonVariant.primary,
                      onPressed: () async {
                        final parsed = double.tryParse(ctrl.text.trim());
                        if (parsed == null || parsed < 0) return;
                        Navigator.pop(ctx);
                        await ref
                            .read(accountRepoProvider)
                            .updateBalance(a.id, parsed);
                        await ref.read(accountsProvider.notifier).refresh();
                        _refreshData();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Updated ${a.name} valuation to ${AppFormat.currency(parsed)}',
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                      child: const Text('Update Valuation'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAccountMenu(BankAccount a) {
    final isInvestment = const [
      'stock',
      'mutual_fund',
      'gold',
      'real_estate',
      'ppf',
    ].contains(a.accountType);

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          if (isInvestment)
            ListTile(
              leading: Icon(
                Icons.auto_graph_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: const Text('Update Valuation'),
              onTap: () {
                Navigator.pop(context);
                _showUpdateAssetValuationSheet(a);
              },
            ),
          ListTile(
            leading: Icon(
              Icons.edit,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(isInvestment ? 'Edit Asset Details' : 'Edit Account'),
            onTap: () async {
              Navigator.pop(context);
              final res = await Navigator.push(
                context,
                AppPageRoute(builder: (_) => AddBankAccountScreen(existing: a)),
              );
              if (res == true) _refreshData();
            },
          ),
          ListTile(
            leading: Icon(
              Icons.delete,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              isInvestment ? 'Delete Asset' : 'Delete',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                decoration: TextDecoration.none,
              ),
            ),
            onTap: () async {
              Navigator.pop(context);
              await ref.read(accountsProvider.notifier).remove(a.id);
              await _refreshData();
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildActualLoanTile(Loan l) {
    final remaining = l.principalAmount - l.paidAmount;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.tertiary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.account_balance,
              color: Theme.of(context).colorScheme.tertiary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.name,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  l.bank,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '−${AppFormat.currency(remaining)}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.tertiary,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}
