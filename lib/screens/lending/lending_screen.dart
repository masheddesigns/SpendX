import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/lending.dart';
import '../../utils/app_format.dart';
import '../../utils/text_formatter.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import 'lending_report_screen.dart';

class LendingScreen extends ConsumerStatefulWidget {
  const LendingScreen({super.key});

  @override
  ConsumerState<LendingScreen> createState() => _LendingScreenState();
}

class _LendingScreenState extends ConsumerState<LendingScreen> {
  String _filter = 'all'; // all | get | owe | settled

  void _refresh() {
    ref.read(lendingProvider.notifier).refresh();
    ref.invalidate(liabilitiesSummaryProvider);
  }

  // ── Add Entry ──────────────────────────────────────────────────────
  void _showAddEntry(List<Lending> allItems) {
    final uniqueNames = allItems.map((e) => e.personName).toSet().toList();
    String type = 'lent';
    String name = '';
    String amount = '';
    String notes = '';

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final isValid = name.trim().isNotEmpty &&
              (double.tryParse(amount) ?? 0) > 0;
          final cs = Theme.of(ctx).colorScheme;

          return Padding(
            padding: EdgeInsets.only(
              left: 20, right: 20, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Type toggle — clear labels
                Row(
                  children: [
                    Expanded(
                      child: _TypeButton(
                        label: 'You Gave',
                        subtitle: 'They owe you',
                        icon: Icons.arrow_upward_rounded,
                        color: const Color(0xFF22C55E),
                        selected: type == 'lent',
                        onTap: () => setSheet(() => type = 'lent'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TypeButton(
                        label: 'You Got',
                        subtitle: 'You owe them',
                        icon: Icons.arrow_downward_rounded,
                        color: cs.error,
                        selected: type == 'borrowed',
                        onTap: () => setSheet(() => type = 'borrowed'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Person name
                Autocomplete<String>(
                  optionsBuilder: (v) {
                    if (v.text.isEmpty) return uniqueNames;
                    return uniqueNames.where(
                        (n) => n.toLowerCase().contains(v.text.toLowerCase()));
                  },
                  onSelected: (s) => setSheet(() => name = s),
                  fieldViewBuilder: (_, ctrl, focus, _) {
                    ctrl.addListener(() => setSheet(() => name = ctrl.text));
                    return TextField(
                      controller: ctrl,
                      focusNode: focus,
                      decoration: InputDecoration(
                        labelText: 'Person name',
                        filled: true,
                        fillColor: cs.surfaceContainer,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 14),

                // Amount
                TextField(
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setSheet(() => amount = v),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: '\u20b9 ',
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Notes
                TextField(
                  onChanged: (v) => setSheet(() => notes = v),
                  decoration: InputDecoration(
                    labelText: 'Note (optional)',
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: isValid
                        ? () async {
                            final parsedAmount = double.tryParse(amount);
                            if (parsedAmount == null || parsedAmount <= 0) return;
                            await ref.read(lendingProvider.notifier).add(
                                  Lending(
                                    personName: TextFormatter.normalizeName(name),
                                    type: type,
                                    originalAmount: parsedAmount,
                                    notes: notes.trim().isEmpty ? null : notes.trim(),
                                  ),
                                );
                            if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                            _refresh();
                          }
                        : null,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      type == 'lent' ? 'Record: You Gave' : 'Record: You Got',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Payment / Collection Modal ─────────────────────────────────────
  void _showPayment(Lending lending) {
    final remaining = lending.originalAmount - lending.paidAmount;
    final isLent = lending.type == 'lent';
    String customAmount = '';

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final cs = Theme.of(ctx).colorScheme;
          final parsedCustom = double.tryParse(customAmount) ?? 0;
          final isValid = parsedCustom > 0 && parsedCustom <= remaining;

          Future<void> record(double amt) async {
            final newPaid = (lending.paidAmount + amt)
                .clamp(0.0, lending.originalAmount);
            final settled = newPaid >= lending.originalAmount;
            await ref.read(lendingProvider.notifier).replace(
                  lending.copyWith(paidAmount: newPaid, isSettled: settled),
                );
            if (sheetCtx.mounted) Navigator.pop(sheetCtx);
            _refresh();
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 20, right: 20, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isLent ? 'Collect from' : 'Pay back',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                Text(
                  TextFormatter.toSmartTitleCase(lending.personName),
                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Remaining: ${AppFormat.currency(remaining)}',
                  style: TextStyle(
                    color: isLent ? const Color(0xFF22C55E) : cs.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),

                // Quick buttons
                Row(
                  children: [
                    _QuickBtn(label: '25%', onTap: () => record(remaining * 0.25)),
                    const SizedBox(width: 8),
                    _QuickBtn(label: '50%', onTap: () => record(remaining * 0.5)),
                    const SizedBox(width: 8),
                    _QuickBtn(label: 'Full', onTap: () => record(remaining)),
                  ],
                ),
                const SizedBox(height: 16),

                TextField(
                  keyboardType: TextInputType.number,
                  onChanged: (v) => setSheet(() => customAmount = v),
                  decoration: InputDecoration(
                    labelText: 'Custom amount',
                    prefixText: '\u20b9 ',
                    filled: true,
                    fillColor: cs.surfaceContainer,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: isValid ? () => record(parsedCustom) : null,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(isLent ? 'Record Collection' : 'Record Payment'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(lendingProvider);
    final allItems = [...state.activeItems, ...state.settledItems];
    final cs = Theme.of(context).colorScheme;

    // Summary from active items
    double youWillGet = 0, youOwe = 0;
    for (final l in state.activeItems) {
      final rem = l.originalAmount - l.paidAmount;
      if (l.type == 'lent') {
        youWillGet += rem;
      } else {
        youOwe += rem;
      }
    }
    final net = youWillGet - youOwe;

    // Filter items
    List<Lending> filtered;
    switch (_filter) {
      case 'get':
        filtered = state.activeItems.where((l) => l.type == 'lent').toList();
      case 'owe':
        filtered = state.activeItems.where((l) => l.type == 'borrowed').toList();
      case 'settled':
        filtered = state.settledItems;
      default:
        filtered = state.activeItems;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lend & Borrow'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: 'Lending Report',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const LendingReportScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEntry(allItems),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: Column(
        children: [
          // ── Summary ────────────────────────────────────────────────
          if (state.activeItems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _SummaryTile(
                      label: "You'll get",
                      amount: youWillGet,
                      color: const Color(0xFF22C55E),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SummaryTile(
                      label: 'You owe',
                      amount: youOwe,
                      color: cs.error,
                    ),
                  ),
                ],
              ),
            ),
          if (state.activeItems.isNotEmpty && net != 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Net: ${net > 0 ? '+' : ''}${AppFormat.currency(net)}',
                style: TextStyle(
                  color: net > 0 ? const Color(0xFF22C55E) : cs.error,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),

          // ── Filter Tabs ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                _FilterChip(
                  label: 'All',
                  count: state.activeItems.length,
                  selected: _filter == 'all',
                  onTap: () => setState(() => _filter = 'all'),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: "You'll get",
                  count: state.activeItems.where((l) => l.type == 'lent').length,
                  selected: _filter == 'get',
                  color: const Color(0xFF22C55E),
                  onTap: () => setState(() => _filter = 'get'),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'You owe',
                  count: state.activeItems.where((l) => l.type == 'borrowed').length,
                  selected: _filter == 'owe',
                  color: cs.error,
                  onTap: () => setState(() => _filter = 'owe'),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Settled',
                  count: state.settledItems.length,
                  selected: _filter == 'settled',
                  onTap: () => setState(() => _filter = 'settled'),
                ),
              ],
            ),
          ),

          // ── List ───────────────────────────────────────────────────
          Expanded(
            child: filtered.isEmpty
                ? _buildEmpty()
                : RefreshIndicator(
                    onRefresh: () async => _refresh(),
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _LendingCard(
                        lending: filtered[i],
                        onTap: filtered[i].isSettled
                            ? null
                            : () => _showPayment(filtered[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.handshake_outlined, size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            _filter == 'get'
                ? 'No one owes you'
                : _filter == 'owe'
                    ? 'You don\'t owe anyone'
                    : _filter == 'settled'
                        ? 'No settled records'
                        : 'No lending records',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Track money you give or borrow',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Type Selection Button ────────────────────────────────────────────────

class _TypeButton extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _TypeButton({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : cs.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? color : cs.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: selected ? color : cs.onSurfaceVariant, size: 22),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? color : cs.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Lending Card ─────────────────────────────────────────────────────────

class _LendingCard extends StatelessWidget {
  final Lending lending;
  final VoidCallback? onTap;

  const _LendingCard({required this.lending, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLent = lending.type == 'lent';
    final color = isLent ? const Color(0xFF22C55E) : cs.error;
    final remaining = lending.originalAmount - lending.paidAmount;
    final progress = lending.originalAmount > 0
        ? lending.paidAmount / lending.originalAmount
        : 0.0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: color.withValues(alpha: 0.1),
                    child: Text(
                      lending.personName.isNotEmpty
                          ? lending.personName[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          TextFormatter.toSmartTitleCase(lending.personName),
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                        Text(
                          isLent ? 'They owe you' : 'You owe them',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: color,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        AppFormat.currency(remaining),
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                      if (lending.paidAmount > 0)
                        Text(
                          'of ${AppFormat.currency(lending.originalAmount)}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              if (!lending.isSettled && lending.paidAmount > 0) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: cs.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  if (lending.dueDate != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          lending.isOverdue ? Icons.warning_amber_rounded : Icons.calendar_today,
                          size: 12,
                          color: lending.isOverdue ? Colors.orange : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          DateFormat('dd MMM').format(lending.dueDate!),
                          style: TextStyle(
                            fontSize: 11,
                            color: lending.isOverdue ? Colors.orange : cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  const Spacer(),
                  if (lending.isSettled)
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
                        SizedBox(width: 4),
                        Text('Settled', style: TextStyle(fontSize: 11, color: Colors.green)),
                      ],
                    ),
                  if (!lending.isSettled)
                    Text(
                      isLent ? 'Tap to collect' : 'Tap to pay back',
                      style: TextStyle(fontSize: 11, color: cs.primary),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Summary Tile ─────────────────────────────────────────────────────────

class _SummaryTile extends StatelessWidget {
  final String label;
  final double amount;
  final Color color;

  const _SummaryTile({required this.label, required this.amount, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
          const SizedBox(height: 4),
          Text(AppFormat.currency(amount),
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 18)),
        ],
      ),
    );
  }
}

// ── Filter Chip ──────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeColor = color ?? cs.primary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? activeColor.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? activeColor : cs.outlineVariant,
          ),
        ),
        child: Text(
          count > 0 ? '$label ($count)' : label,
          style: TextStyle(
            color: selected ? activeColor : cs.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

// ── Quick Amount Button ──────────────────────────────────────────────────

class _QuickBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
