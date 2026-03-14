import 'package:flutter/material.dart';
import '../services/database_helper.dart';
import '../utils/app_format.dart';
import '../theme/app_theme.dart';
import '../widgets/custom_snackbar.dart';
import 'expense/add_expense_screen.dart';

/// Notification inbox screen: shows upcoming due reminders with quick actions
class NotificationsInboxScreen extends StatefulWidget {
  const NotificationsInboxScreen({super.key});

  @override
  State<NotificationsInboxScreen> createState() => _NotificationsInboxScreenState();
}

class _NotificationsInboxScreenState extends State<NotificationsInboxScreen> {
  List<_NotifItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    setState(() => _isLoading = true);
    final List<_NotifItem> items = [];

    try {
      // Credit card due reminders
      final cards = await DatabaseHelper.instance.getAllCreditCards();
      for (final card in cards) {
        final daysLeft = card.daysUntilDue;
        if (daysLeft <= 7) {
          items.add(_NotifItem(
            id: 'cc_${card.id}',
            icon: Icons.credit_card,
            iconColor: daysLeft <= 3 ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.secondary,
            title: '${card.bank} Card Due',
            subtitle: 'Payment due in $daysLeft days · Outstanding: ${AppFormat.currency(card.outstanding)}',
            type: _NotifType.creditDue,
            payload: card.id,
            daysLeft: daysLeft,
          ));
        }
      }

      // EMI reminders
      final emis = await DatabaseHelper.instance.getAllEmiPlans(activeOnly: true);
      for (final emi in emis) {
        if (emi.isDue) {
          items.add(_NotifItem(
            id: 'emi_${emi.id}',
            icon: Icons.account_balance,
            iconColor: Theme.of(context).colorScheme.primary,
            title: '${emi.name} EMI',
            subtitle: 'Monthly payment: ${AppFormat.currency(emi.emiAmount)} · ${emi.remainingInstalments} instalments left',
            type: _NotifType.emi,
            payload: emi.id,
            daysLeft: -1,
          ));
        }
      }

      // General tip if nothing urgent
      if (items.isEmpty) {
        items.add(_NotifItem(
          id: 'tip_today',
          icon: Icons.lightbulb_outline,
          iconColor: Theme.of(context).colorScheme.secondary,
          title: 'No upcoming dues!',
          subtitle: 'All your bills are on track. Keep it up!',
          type: _NotifType.info,
          payload: null,
          daysLeft: -1,
        ));
      }
    } catch (e) {
      debugPrint('Notification load error: $e');
    }

    // Sort urgent items first
    items.sort((a, b) {
      if (a.daysLeft == -1 && b.daysLeft == -1) return 0;
      if (a.daysLeft == -1) return 1;
      if (b.daysLeft == -1) return -1;
      return a.daysLeft.compareTo(b.daysLeft);
    });

    if (mounted) setState(() { _items = items; _isLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Notifications',
        showLogo: false,
        actions: [

          IconButton(
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _loadNotifications,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadNotifications,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Quick Action row at top
                  _buildQuickActions(context),
                  const SizedBox(height: 20),

                  // Notification items
                  Text(
                    'UPCOMING',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 10),
                  ..._items.map((item) => _buildNotifCard(item, context)),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick Actions', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _quickBtn(
                context,
                icon: Icons.add_circle_outline,
                label: 'Add Expense',
                color: Theme.of(context).colorScheme.error,
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AddExpenseScreen(initialType: 'expense')),
                  );
                  if (result == true && context.mounted) Navigator.pop(context, true);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _quickBtn(
                context,
                icon: Icons.add_circle_outline,
                label: 'Add Income',
                color: Theme.of(context).colorScheme.primary,
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AddExpenseScreen(initialType: 'income')),
                  );
                  if (result == true && context.mounted) Navigator.pop(context, true);
                },
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _quickBtn(BuildContext context, {
    required IconData icon, required String label, required Color color, required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      ),
    );
  }

  Widget _buildNotifCard(_NotifItem item, BuildContext context) {
    final isUrgent = item.daysLeft >= 0 && item.daysLeft <= 3;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isUrgent ? Theme.of(context).colorScheme.error.withValues(alpha: 0.08) : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUrgent ? Theme.of(context).colorScheme.error.withValues(alpha: 0.35) : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: item.iconColor.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(item.icon, color: item.iconColor, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.title, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 4),
          Text(item.subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, height: 1.4)),
        ])),
        if (item.type == _NotifType.creditDue) ...[
          const SizedBox(width: 8),
          _actionButton(
            label: 'Pay',
            color: Theme.of(context).colorScheme.primary,
            icon: Icons.check,
            onTap: () => _showPayCreditDue(item),
          ),
        ] else if (item.type == _NotifType.emi) ...[
          const SizedBox(width: 8),
          _actionButton(
            label: 'Mark',
            color: Theme.of(context).colorScheme.secondary,
            icon: Icons.done_all,
            onTap: () => _markEmiPaid(item),
          ),
        ],
      ]),
    );
  }

  Widget _actionButton({required String label, required Color color, required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
        ]),
      ),
    );
  }

  void _showPayCreditDue(_NotifItem item) async {
    if (item.payload == null) return;
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    final card = cards.where((c) => c.id == item.payload).firstOrNull;
    if (card == null || !mounted) return;

    final ctrl = TextEditingController(text: card.outstanding > 0 ? card.outstanding.toStringAsFixed(0) : '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Pay ${card.bank} Bill', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Outstanding: ${AppFormat.currency(card.outstanding)}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            decoration: InputDecoration(
              labelText: 'Amount to Pay',
              labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final amt = double.tryParse(ctrl.text);
              if (amt == null || amt <= 0) return;
              final newOuts = (card.outstanding - amt).clamp(0.0, double.infinity);
              await DatabaseHelper.instance.updateCreditCardOutstanding(card.id, newOuts);
              if (ctx.mounted) Navigator.pop(ctx);
              _loadNotifications();
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  void _markEmiPaid(_NotifItem item) async {
    if (item.payload == null) return;
    final emis = await DatabaseHelper.instance.getAllEmiPlans();
    final emi = emis.where((e) => e.id == item.payload).firstOrNull;
    if (emi == null || !mounted) return;

    final updated = emi.copyWith(paidInstalments: emi.paidInstalments + 1);
    await DatabaseHelper.instance.updateEmiPlan(updated);
    _loadNotifications();

    if (mounted) {
      CustomSnackBar.show(context, message: '${emi.name} instalment marked as paid!');    }
  }
}

enum _NotifType { creditDue, emi, lending, info }

class _NotifItem {
  final String id;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final _NotifType type;
  final String? payload;
  final int daysLeft;

  const _NotifItem({
    required this.id,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.payload,
    required this.daysLeft,
  });
}
