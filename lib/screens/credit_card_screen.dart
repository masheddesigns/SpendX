import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/credit_card.dart';
import '../models/emi_plan.dart';
import '../services/database_helper.dart';
import '../services/notification_service.dart';
import '../widgets/spendx_app_bar.dart';
import '../widgets/custom_snackbar.dart';
import '../utils/app_format.dart';
import 'credit_card/add_credit_card_screen.dart';
import 'credit_card/add_emi_screen.dart';
import 'credit_card/emi_detail_screen.dart';


class CreditCardScreen extends StatefulWidget {
  const CreditCardScreen({super.key});

  @override
  State<CreditCardScreen> createState() => _CreditCardScreenState();
}

class _CreditCardScreenState extends State<CreditCardScreen> {
  List<CreditCard> _cards = [];
  List<EmiPlan> _allEmis = [];
  int _selectedCardIndex = 0;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  
  final ScrollController _scrollController = ScrollController();
  int _emiOffset = 0;
  final int _limit = 20;
  bool _hasMoreEmis = true;

  @override
  void initState() {
    super.initState();
    _loadData();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
        if (!_isLoading && !_isLoadingMore && _hasMoreEmis) _loadMoreEmis();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _emiOffset = 0;
      _hasMoreEmis = true;
    });
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    final emis = await DatabaseHelper.instance.getAllEmiPlans(activeOnly: true, limit: _limit, offset: 0);
    if (mounted) {
      setState(() {
        _cards = cards;
        _allEmis = emis;
        _emiOffset = emis.length;
        _hasMoreEmis = emis.length >= _limit;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreEmis() async {
    setState(() => _isLoadingMore = true);
    final more = await DatabaseHelper.instance.getAllEmiPlans(activeOnly: true, limit: _limit, offset: _emiOffset);
    if (mounted) {
      setState(() {
        _allEmis.addAll(more);
        _emiOffset += more.length;
        _hasMoreEmis = more.length >= _limit;
        _isLoadingMore = false;
      });
    }
  }

  CreditCard? get _selectedCard =>
      _cards.isNotEmpty ? _cards[_selectedCardIndex.clamp(0, _cards.length - 1)] : null;

  List<EmiPlan> get _emisForSelectedCard =>
      _selectedCard == null ? [] : _allEmis.where((e) => e.cardId == _selectedCard!.id).toList();

  Color _hexColor(String hex) =>
      Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

  void _showActionMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          ListTile(
            leading: CircleAvatar(backgroundColor: Theme.of(context).colorScheme.secondary, child: const Icon(Icons.credit_card, color: Colors.white)),

            title: const Text('Add Credit Card'),
            subtitle: const Text('Track a new card\'s limit and billing'),
            onTap: () async {
              Navigator.pop(context);
              final res = await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddCreditCardScreen()));
              if (res == true) _loadData();
            },
          ),
          ListTile(
            leading: CircleAvatar(backgroundColor: Theme.of(context).colorScheme.primary, child: const Icon(Icons.payment, color: Colors.white)),

            title: const Text('Add EMI Plan'),
            subtitle: const Text('Auto-calculate instalments and interest'),
            onTap: () async {
              Navigator.pop(context);
              final res = await Navigator.push(context, MaterialPageRoute(
                  builder: (_) => AddEmiScreen(card: _selectedCard)));
              if (res == true) _loadData();
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    if (_cards.isEmpty) return _buildEmptyState();

    final card = _selectedCard!;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _showActionMenu,
        backgroundColor: Theme.of(context).colorScheme.primary,

        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            // ─── App Bar ───
            SpendXAppBar(
              title: 'Credit Cards',
            ),


            // ─── Card Carousel ───
            SliverToBoxAdapter(child: _buildCardCarousel()),

            // ─── Utilization & Stats ───
            SliverToBoxAdapter(child: _buildCardStats(card)),

            // ─── Billing Info ───
            SliverToBoxAdapter(child: _buildBillingRow(card)),

            const SliverToBoxAdapter(child: SizedBox(height: 20)),

            // ─── EMI Plans ───
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Emi plans', style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
                  if (_cards.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        final res = await Navigator.push(context, MaterialPageRoute(
                            builder: (_) => AddEmiScreen(card: card)));
                        if (res == true) _loadData();
                      },
                      child: Text('+ Add', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                    ),
                ]),
              ),
            ),

            if (_emisForSelectedCard.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('No EMI plans for this card.\nTap + to add one.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    if (i == _emisForSelectedCard.length) {
                      return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
                    }
                    return _buildEmiTile(_emisForSelectedCard[i]);
                  },
                  childCount: _emisForSelectedCard.length + (_hasMoreEmis ? 1 : 0),
                ),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  Widget _buildCardCarousel() {
    return SizedBox(
      height: 210,
      child: PageView.builder(
        controller: PageController(viewportFraction: 0.85),
        onPageChanged: (i) => setState(() => _selectedCardIndex = i),
        itemCount: _cards.length,
        itemBuilder: (_, i) {
          final c = _cards[i];
          final cardColor = _hexColor(c.color);
          final isSelected = i == _selectedCardIndex;
          return AnimatedScale(
            scale: isSelected ? 1.0 : 0.93,
            duration: const Duration(milliseconds: 200),
            child: GestureDetector(
              onLongPress: () => _showCardMenu(c),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [cardColor, cardColor.withValues(alpha: 0.6)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: isSelected
                      ? [BoxShadow(color: cardColor.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, 8))]
                      : [],
                ),
                padding: const EdgeInsets.all(22),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(c.bank, style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 1.5)),
                    Text(c.cardType, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 1)),
                  ]),
                  const Spacer(),
                  Text('**** **** **** ${c.last4}', style: const TextStyle(color: Colors.white, fontSize: 17, letterSpacing: 3, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 12),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(c.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      const Text('Limit', style: TextStyle(color: Colors.white60, fontSize: 9, letterSpacing: 1)),
                      Text(AppFormat.currency(c.creditLimit), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                    ]),
                  ]),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCardStats(CreditCard card) {
    final utilPct = card.utilizationPct;
    final utilColor = utilPct >= 80 ? Theme.of(context).colorScheme.error : utilPct >= 50 ? Colors.orange : Colors.green;


    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(children: [
        // Utilization Doughnut
        SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: utilPct / 100,
                  strokeWidth: 8,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(utilColor),
                  strokeCap: StrokeCap.round,
                ),
              ),
              Text('${utilPct.toStringAsFixed(0)}%',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(width: 20),
        Expanded(child: Column(children: [
          _statRow('Outstanding', AppFormat.currency(card.outstanding), Theme.of(context).colorScheme.error),
          const SizedBox(height: 10),
          _statRow('Available', AppFormat.currency(card.creditLimit - card.outstanding), Colors.green),
          const SizedBox(height: 10),
          _statRow('Credit Limit', AppFormat.currency(card.creditLimit), Theme.of(context).colorScheme.onSurfaceVariant),

        ])),
      ]),
    );
  }

  Widget _statRow(String label, String value, Color color) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
      Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
    ],
  );

  Widget _buildBillingRow(CreditCard card) {
    final daysUntilDue = card.daysUntilDue;
    final isUrgent = daysUntilDue <= 5;
    final dueColor = daysUntilDue <= 3 ? Theme.of(context).colorScheme.error : daysUntilDue <= 7 ? Colors.orange : Colors.green;


    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isUrgent ? Colors.red.withValues(alpha: 0.1) : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isUrgent ? Colors.red.withValues(alpha: 0.4) : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Top row: icon + due info + days badge
        Row(children: [
          Icon(isUrgent ? Icons.warning_amber_rounded : Icons.credit_card,
              color: dueColor, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              isUrgent ? '⚠ Payment Due Soon!' : 'Payment Due',
              style: TextStyle(color: isUrgent ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 13),

            ),
            Text(
              'Due ${DateFormat('MMMM d').format(card.nextDueDate)}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: dueColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: dueColor.withValues(alpha: 0.35)),
            ),
            child: Text(
              '$daysUntilDue days',
              style: TextStyle(color: dueColor, fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ),
        ]),

        const SizedBox(height: 14),

        // Outstanding amount
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Outstanding Due', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
            const SizedBox(height: 2),
            Text(
              AppFormat.currency(card.outstanding),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 18),
            ),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Billing Day', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
            const SizedBox(height: 2),
            Text('Day ${card.billingDay}', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13, fontWeight: FontWeight.w500)),
          ]),
        ]),

        const SizedBox(height: 14),

        // Action buttons: Set Reminder + Mark as Paid
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _scheduleReminder(card),
              icon: const Icon(Icons.notifications_active_outlined, size: 16),
              label: const Text('Set Reminder', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _showMarkAsPaidDialog(card),
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Mark as Paid', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,

                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  void _scheduleReminder(CreditCard card) async {
    // Schedule a notification 1 day before the due date
    final dueDate = card.nextDueDate;
    final reminderDate = dueDate.subtract(const Duration(days: 1));
    final notifTime = DateTime(reminderDate.year, reminderDate.month, reminderDate.day, 9, 0);

    if (notifTime.isBefore(DateTime.now())) {
      CustomSnackBar.show(context, message: 'Due date is too soon — reminder already passed.', isWarning: true);
      return;
    }

    try {
      await NotificationService.instance.scheduleNotification(
        id: card.id.hashCode.abs() % 100000,
        title: '💳 ${card.bank} Bill Due Tomorrow!',
        body: 'Outstanding: ${AppFormat.currency(card.outstanding)} · Due: ${DateFormat('MMM d').format(dueDate)}',
        scheduledDate: notifTime,
      );
      if (mounted) CustomSnackBar.show(context, message: '🔔 Reminder set for ${DateFormat('MMM d, hh:mm a').format(notifTime)}');
    } catch (e) {
      if (mounted) CustomSnackBar.show(context, message: 'Failed to set reminder: $e', isError: true);
    }
  }

  void _showMarkAsPaidDialog(CreditCard card) {
    final ctrl = TextEditingController(text: card.outstanding > 0 ? card.outstanding.toStringAsFixed(0) : '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Pay ${card.bank} Bill', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Current Outstanding: ${AppFormat.currency(card.outstanding)}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 14),
          TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            decoration: InputDecoration(
              labelText: 'Amount Paid',
              labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              filled: true,
              fillColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              prefixText: '${AppFormat.currencySymbol} ',
              prefixStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: Colors.grey[500]))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () async {
              final amt = double.tryParse(ctrl.text);
              if (amt == null || amt <= 0) return;
              final newOuts = (card.outstanding - amt).clamp(0.0, double.infinity);
              await DatabaseHelper.instance.updateCreditCardOutstanding(card.id, newOuts);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                setState(() {});
                _loadData();
                CustomSnackBar.show(context, message: '✅ Payment of ${AppFormat.currency(amt)} recorded!');
              }
            },
            child: const Text('Confirm Payment', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmiTile(EmiPlan emi) {
    final remaining = emi.remainingInstalments;
    final current = emi.currentInstalment;
    final progress = emi.tenureMonths > 0 ? current / emi.tenureMonths : 0.0;

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EmiDetailScreen(plan: emi))),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(emi.name, style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 15))),
            Text('${AppFormat.currency(emi.emiAmount)}/mo', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 14)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation(progress >= 1 ? Colors.green : Theme.of(context).colorScheme.primary),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('$current / ${emi.tenureMonths} paid', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
            const Spacer(),
            if (remaining > 0) ...[
              const Icon(Icons.schedule, size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Text('$remaining left', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
            ] else
              Text('✓ Complete', style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.w600)),

          ]),
        ]),
      ),
    );
  }

  void _showCardMenu(CreditCard card) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.payment, color: Colors.green),
            title: const Text('Record Payment'),
            onTap: () async {
              Navigator.pop(context);
              _showPaymentDialog(card);
            },
          ),
          ListTile(
            leading: Icon(Icons.edit, color: Theme.of(context).colorScheme.secondary),
            title: const Text('Edit Card'),
            onTap: () async {
              Navigator.pop(context);
              final res = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddCreditCardScreen(existingCard: card)));
              if (res == true) _loadData();
            },
          ),
          ListTile(
            leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
            title: Text('Delete Card', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              Navigator.pop(context);
              await DatabaseHelper.instance.deleteCreditCard(card.id);
              _loadData();
            },
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Scaffold(
      appBar: AppBar(title: const Text('Credit Cards'), backgroundColor: Colors.transparent, elevation: 0),
      floatingActionButton: FloatingActionButton(
        onPressed: _showActionMenu,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.add),
      ),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.credit_card_off, size: 80, color: Colors.grey[800]),
          const SizedBox(height: 16),
          const Text('No Credit Cards', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('Add a card to track limit, outstanding\nand manage EMIs', style: TextStyle(color: Colors.grey[500]), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              final res = await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddCreditCardScreen()));
              if (res == true) _loadData();
            },
            icon: const Icon(Icons.add),
            label: const Text('Add Card'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ]),
      ),
    );
  }

  void _showPaymentDialog(CreditCard card) {
    final ctrl = TextEditingController(text: card.outstanding > 0 ? card.outstanding.toStringAsFixed(0) : '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pay Bill — ${card.bank}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current Outstanding: ${AppFormat.currency(card.outstanding)}', style: TextStyle(color: Colors.grey[400])),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount Paid'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final amt = double.tryParse(ctrl.text);
              if (amt == null || amt <= 0) return;
              final newOutstanding = (card.outstanding - amt).clamp(0.0, double.infinity);
              await DatabaseHelper.instance.updateCreditCardOutstanding(card.id, newOutstanding);
              if (mounted) {
                Navigator.pop(ctx);
                _loadData();
                CustomSnackBar.show(context, message: 'Credit card payment recorded successfully');
              }
            },
            child: const Text('Record'),
          ),
        ],
      ),
    );
  }
}
