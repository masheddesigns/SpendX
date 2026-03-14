import 'package:flutter/material.dart';
import '../utils/app_format.dart';
import '../models/bank_account.dart';
import '../models/credit_card.dart';
import '../models/lending.dart';
import '../services/database_helper.dart';
import '../services/database_helper.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../services/settings_service.dart';
import 'bank/add_bank_account_screen.dart';
import 'net_worth/net_worth_report_screen.dart';
import '../widgets/spendx_app_bar.dart';


class NetWorthScreen extends StatefulWidget {
  const NetWorthScreen({super.key});

  @override
  State<NetWorthScreen> createState() => _NetWorthScreenState();
}

class _NetWorthScreenState extends State<NetWorthScreen> {
  List<BankAccount> _accounts = [];
  List<CreditCard> _cards = [];
  List<Lending> _lendings = [];
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final accounts = await DatabaseHelper.instance.getAllBankAccounts();
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    final lendings = await DatabaseHelper.instance.getAllLendings(settledFilter: false);
    setState(() {
      _accounts = accounts;
      _cards = cards;
      _lendings = lendings;
      _loading = false;
    });

    // Auto-capture logic: only if more than 24 hours since last update
    final lastUpdated = SettingsService.instance.netWorthLastUpdated;
    final now = DateTime.now();
    
    if (lastUpdated == null || now.difference(lastUpdated).inHours >= 24) {
      await DatabaseHelper.instance.insertNetWorthSnapshot(
        id: const Uuid().v4(),
        netWorth: _netWorth,
        assets: _totalAssets,
        liabilities: _totalLiabilities,
        timestamp: now,
      );
      await SettingsService.instance.setNetWorthLastUpdated(now);
    }
    
    _loadHistory();
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
              Text('Capture current net worth state with custom time.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                  if (picked != null) setInnerState(() => selectedDate = picked);
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
                  if (picked != null) setInnerState(() => selectedTime = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Capture')),
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

      await DatabaseHelper.instance.insertNetWorthSnapshot(
        id: const Uuid().v4(),
        netWorth: _netWorth,
        assets: _totalAssets,
        liabilities: _totalLiabilities,
        timestamp: finalTimestamp,
      );
      await SettingsService.instance.setNetWorthLastUpdated(finalTimestamp);
      _loadHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✓ Snapshot captured!')));
      }
    }
  }

  Future<void> _loadHistory() async {
    final history = await DatabaseHelper.instance.getNetWorthHistory();
    if (mounted) {
      setState(() => _history = history);
    }
  }

  double get _totalAssets {
    final bankAssets = _accounts.where((a) => a.isAsset).fold(0.0, (s, a) => s + a.balance);
    return bankAssets;
  }

  double get _totalLiabilities {
    final ccOutstanding = _cards.fold(0.0, (s, c) => s + c.outstanding);
    final loans = _lendings.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + (l.originalAmount - l.paidAmount));
    return ccOutstanding + loans;
  }

  double get _netWorth => _totalAssets - _totalLiabilities;

  Color _hexColor(String hex) => Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Net Worth',
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Detailed History',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NetWorthReportScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final res = await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddBankAccountScreen()));
          if (res == true) _load();
        },
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [

            // ─── Net Worth Hero ───
            SliverToBoxAdapter(child: _buildNetWorthHero()),

            // ─── Assets Section ───
            SliverToBoxAdapter(child: _buildSectionHeader('Assets', _totalAssets, Theme.of(context).colorScheme.primary)),

            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _buildAccountTile(_accounts.where((a) => a.isAsset).toList()[i]),
                childCount: _accounts.where((a) => a.isAsset).length,
              ),
            ),

            if (_accounts.where((a) => a.isAsset).isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('No accounts added yet. Tap + to add.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ),

            // ─── Liabilities Section ───
            SliverToBoxAdapter(child: _buildSectionHeader('Liabilities', _totalLiabilities, Theme.of(context).colorScheme.error)),

            // Credit card outstanding
            if (_cards.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _buildCcLiabilityTile(_cards[i]),
                  childCount: _cards.where((c) => c.outstanding > 0).length,
                ),
              ),

            // Borrowed lendings
            if (_lendings.where((l) => l.type == 'borrowed').isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final loan = _lendings.where((l) => l.type == 'borrowed').toList()[i];
                    return _buildLendingLiabilityTile(loan);
                  },
                  childCount: _lendings.where((l) => l.type == 'borrowed').length,
                ),
              ),

            if (_totalLiabilities == 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('No liabilities 🎉', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  Widget _buildNetWorthHero() {
    final isPositive = _netWorth >= 0;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isPositive
              ? [Theme.of(context).colorScheme.primary.withValues(alpha: 0.3), Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.1)]
              : [Theme.of(context).colorScheme.error.withValues(alpha: 0.3), Theme.of(context).colorScheme.secondary.withValues(alpha: 0.1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: (isPositive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error).withValues(alpha: 0.3)),
      ),
      child: Column(children: [
        Text('Net worth', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          '${isPositive ? '' : '-'}${AppFormat.currency(_netWorth.abs())}',
          style: TextStyle(color: isPositive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error, fontSize: 40, fontWeight: FontWeight.w600),
        ),
        if (SettingsService.instance.netWorthLastUpdated != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Last updated: ${DateFormat('dd MMM, hh:mm a').format(SettingsService.instance.netWorthLastUpdated!)}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5), fontSize: 12),
            ),
          ),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _heroStat('Total Assets', AppFormat.currency(_totalAssets), Colors.greenAccent),
          Container(width: 1, height: 40, color: Theme.of(context).colorScheme.outlineVariant),
          _heroStat('Total Liabilities', AppFormat.currency(_totalLiabilities), Colors.redAccent),
        ]),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _captureSnapshot,
            icon: const Icon(Icons.add_chart, size: 18),
            label: const Text('Record Net Worth Snapshot'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _heroStat(String label, String val, Color color) => Column(children: [
    Text(val, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w600)),
    Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
  ]);

  Widget _buildSectionHeader(String title, double total, Color color) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(title == 'Liabilities' ? 'What you owe' : title, 
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.5)),
      Text(AppFormat.currency(total), style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _buildAccountTile(BankAccount a) {
    final color = _hexColor(a.color);
    return GestureDetector(
      onLongPress: () => _showAccountMenu(a),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.2), shape: BoxShape.circle),
            child: Icon(Icons.account_balance, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.name, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
            Text('${a.bank} · ${a.accountType.toUpperCase()}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
          ])),
          Text(AppFormat.currency(a.balance), style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 16)),
        ]),
      ),
    );
  }

  Widget _buildCcLiabilityTile(CreditCard c) {
    if (c.outstanding <= 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.error.withValues(alpha: 0.15), shape: BoxShape.circle),
          child: Icon(Icons.credit_card, color: Theme.of(context).colorScheme.error, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.name, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
          Text('Credit Card · ****${c.last4}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
        ])),
        Text('−${AppFormat.currency(c.outstanding)}', style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600, fontSize: 16)),
      ]),
    );
  }

  Widget _buildLendingLiabilityTile(Lending l) {
    final remaining = l.originalAmount - l.paidAmount;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.15), shape: BoxShape.circle),
          child: Icon(Icons.handshake, color: Theme.of(context).colorScheme.tertiary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Borrowed from ${l.personName}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
          Text('Loan', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
        ])),
        Text('−${AppFormat.currency(remaining)}', style: TextStyle(color: Theme.of(context).colorScheme.tertiary, fontWeight: FontWeight.w600, fontSize: 16)),
      ]),
    );
  }

  void _showAccountMenu(BankAccount a) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(Icons.edit, color: Theme.of(context).colorScheme.primary),
            title: const Text('Edit Account'),
            onTap: () async {
              Navigator.pop(context);
              final res = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddBankAccountScreen(existing: a)));
              if (res == true) _load();
            },
          ),
          ListTile(
            leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
            title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              Navigator.pop(context);
              await DatabaseHelper.instance.deleteBankAccount(a.id);
              _load();
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
