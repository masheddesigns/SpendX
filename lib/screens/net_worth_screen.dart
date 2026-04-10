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
import '../widgets/custom_snackbar.dart';
import '../shared/widgets/undo_snackbar_listener.dart';
import '../features/liabilities/providers/liabilities_providers.dart'
    show lendingProvider;
import 'bank/add_bank_account_screen.dart';
import 'net_worth/net_worth_report_screen.dart';

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

      await ref.read(netWorthHistoryProvider.notifier).add(
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

  Future<void> _showTransferDialog() async {
    final accounts = ref.read(accountsProvider).valueOrNull ?? const <BankAccount>[];
    if (accounts.length < 2) {
      CustomSnackBar.show(
        context,
        message: 'Add at least 2 accounts to transfer.',
        isError: true,
      );
      return;
    }

    String? sourceId = accounts.first.id;
    String? destId = accounts.last.id;
    final amountController = TextEditingController();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          title: const Text('Account Transfer'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: sourceId,
                decoration: const InputDecoration(labelText: 'From Account'),
                items: accounts
                    .map(
                      (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                    )
                    .toList(),
                onChanged: (v) => setInner(() => sourceId = v),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: destId,
                decoration: const InputDecoration(labelText: 'To Account'),
                items: accounts
                    .map(
                      (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                    )
                    .toList(),
                onChanged: (v) => setInner(() => destId = v),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: amountController,
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '₹',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (sourceId == destId) {
                  CustomSnackBar.show(
                    ctx,
                    message: 'Source and Destination cannot be same.',
                    isError: true,
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Transfer'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final amount = double.tryParse(amountController.text) ?? 0.0;
      if (amount <= 0) return;

      await ref
          .read(ledgerMutationProvider.notifier)
          .addTransfer(
            sourceAccountId: sourceId!,
            destinationAccountId: destId!,
            amount: amount,
            date: DateTime.now(),
            note: 'Internal Transfer',
          );

      if (mounted) {
        CustomSnackBar.show(context, message: 'Transfer successful!');
        _refreshData();
      }
    }
  }

  Color _hexColor(String hex) {
    final clean = hex.replaceAll('#', '');
    return Color(int.parse('0xFF$clean'));
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
    final totalAssets = summaryAsync.valueOrNull?.assets ?? 0.0;
    final totalLiabilities = summaryAsync.valueOrNull?.liabilities ?? 0.0;

    listenForUndoSnackbars(
      ref,
      context,
      matches: (payload) => payload is BankAccount || payload is CreditCard,
      onUndone: (_) => _refreshData(),
    );

    if (accountsAsync.isLoading || cardsAsync.isLoading || loansAsync.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (accountsAsync.hasError || cardsAsync.hasError || loansAsync.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Net Worth')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Failed to calculate net worth'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _refreshData,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Net Worth'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Detailed History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => NetWorthReportScreen()),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        label: const Text('Add Account'),
        icon: const Icon(Icons.add_rounded),
        onPressed: () async {
          final res = await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => AddBankAccountScreen()),
          );
          if (res == true) {
            _refreshData();
          }
        },
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshData,
          child: CustomScrollView(
            slivers: [
              // ─── Net Worth Hero ───
              SliverToBoxAdapter(child: _buildNetWorthHero()),

              // ─── Assets Section ───
              SliverToBoxAdapter(
                child: _buildSectionHeader(
                  'Assets',
                  totalAssets,
                  Theme.of(context).colorScheme.primary,
                ),
              ),

              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _buildAccountTile(
                    accounts.where((a) => a.isAsset).toList()[i],
                  ),
                  childCount: accounts.where((a) => a.isAsset).length,
                ),
              ),

              if (accounts.where((a) => a.isAsset).isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      'No accounts added yet. Tap + to add.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),

              // ─── Liabilities Section ───
              SliverToBoxAdapter(
                child: _buildSectionHeader(
                  'Liabilities',
                  totalLiabilities,
                  Theme.of(context).colorScheme.error,
                ),
              ),

              // Credit card outstanding
              if (cards.isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _buildCcLiabilityTile(cards[i]),
                    childCount: cards.where((c) => c.outstanding > 0).length,
                  ),
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
                      vertical: 8,
                    ),
                    child: Text(
                      'No liabilities 🎉',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 112)),
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
        final isPositive = data.netWorth >= 0;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isPositive
                  ? isDark
                      ? [const Color(0xFF0D2818), const Color(0xFF1A1D2E)]
                      : [const Color(0xFFE8F5E9), const Color(0xFFF0F4FF)]
                  : isDark
                      ? [const Color(0xFF2D1215), const Color(0xFF1A1D2E)]
                      : [const Color(0xFFFCE4EC), const Color(0xFFF0F4FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isPositive
                  ? (isDark ? const Color(0xFF4CAF50) : const Color(0xFF81C784))
                      .withValues(alpha: 0.3)
                  : (isDark ? const Color(0xFFEF5350) : const Color(0xFFE57373))
                      .withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            children: [
              Text(
                'Net Worth',
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${isPositive ? '' : '-'}${AppFormat.currency(data.netWorth.abs())}',
                style: TextStyle(
                  color: isPositive
                      ? (isDark ? const Color(0xFF4CAF50) : const Color(0xFF2E7D32))
                      : (isDark ? const Color(0xFFEF5350) : const Color(0xFFC62828)),
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
              if (SettingsService.instance.netWorthLastUpdated != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Last updated: ${DateFormat('dd MMM, hh:mm a').format(SettingsService.instance.netWorthLastUpdated!)}',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                      fontSize: 12,
                      decoration: TextDecoration.none,
                    ),
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
                      child: _heroStat(
                        'Total Assets',
                        AppFormat.currency(data.assets),
                        isDark
                            ? const Color(0xFF4CAF50)
                            : const Color(0xFF2E7D32),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF2D1215)
                            : const Color(0xFFFCE4EC),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _heroStat(
                        'Total Liabilities',
                        AppFormat.currency(data.liabilities),
                        isDark
                            ? const Color(0xFFEF5350)
                            : const Color(0xFFC62828),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _captureSnapshot,
                  icon: const Icon(Icons.add_chart, size: 18),
                  label: const Text('Record Net Worth Snapshot'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => Text('Error calculating net worth: $e'),
    );
  }

  Widget _heroStat(String label, String val, Color color) => Column(
    children: [
      Text(
        val,
        style: TextStyle(
          color: color,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _buildSectionHeader(String title, double total, Color color) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  Text(
                    title == 'Liabilities'
                        ? 'What you owe'
                        : TextFormatter.toSmartTitleCase(title),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                      decoration: TextDecoration.none,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (title == 'Assets' &&
                      (ref.watch(accountsProvider).valueOrNull ?? const <BankAccount>[])
                              .length >=
                          2) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _showTransferDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.swap_horiz,
                              size: 14,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Transfer',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              AppFormat.currency(total),
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      );

  Widget _buildAccountTile(BankAccount a) {
    final color = _hexColor(a.color);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: InkWell(
        onLongPress: () => _showAccountMenu(a),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.account_balance, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      TextFormatter.toSmartTitleCase(a.name),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${TextFormatter.toSmartTitleCase(a.bank)} · ${TextFormatter.toSmartTitleCase(a.accountType)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                AppFormat.currency(a.balance),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCcLiabilityTile(CreditCard c) {
    if (c.outstanding <= 0) return const SizedBox.shrink();
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
              ).colorScheme.error.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.credit_card,
              color: Theme.of(context).colorScheme.error,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  TextFormatter.toSmartTitleCase(c.name),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  'Credit Card · ****${c.last4}',
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
            '−${AppFormat.currency(c.usedAmount)}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w600,
              fontSize: 16,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLendingLiabilityTile(Lending l) {
    final remaining = l.originalAmount - l.paidAmount;
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
              Icons.handshake,
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
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                Text(
                  'Loan',
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

  void _showAccountMenu(BankAccount a) {
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
          ListTile(
            leading: Icon(
              Icons.edit,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('Edit Account'),
            onTap: () async {
              Navigator.pop(context);
              final res = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AddBankAccountScreen(existing: a),
                ),
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
              'Delete',
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
