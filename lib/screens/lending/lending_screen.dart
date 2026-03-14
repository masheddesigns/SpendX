import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/lending.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';
import '../../utils/app_format.dart';
import 'lending_report_screen.dart';

class LendingScreen extends StatefulWidget {
  const LendingScreen({super.key});

  @override
  State<LendingScreen> createState() => _LendingScreenState();
}

class _LendingScreenState extends State<LendingScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Lending> _active = [];
  List<Lending> _settled = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  
  final ScrollController _activeScrollController = ScrollController();
  final ScrollController _settledScrollController = ScrollController();
  
  int _activeOffset = 0;
  int _settledOffset = 0;
  final int _limit = 20;
  bool _hasMoreActive = true;
  bool _hasMoreSettled = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
    
    _activeScrollController.addListener(() {
      if (_activeScrollController.position.pixels >= _activeScrollController.position.maxScrollExtent - 200) {
        if (!_isLoading && !_isLoadingMore && _hasMoreActive) _loadMore(false);
      }
    });
    
    _settledScrollController.addListener(() {
      if (_settledScrollController.position.pixels >= _settledScrollController.position.maxScrollExtent - 200) {
        if (!_isLoading && !_isLoadingMore && _hasMoreSettled) _loadMore(true);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _activeScrollController.dispose();
    _settledScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _activeOffset = 0;
      _settledOffset = 0;
      _hasMoreActive = true;
      _hasMoreSettled = true;
    });
    try {
      final active = await DatabaseHelper.instance.getAllLendings(settledFilter: false, limit: _limit, offset: 0);
      final settled = await DatabaseHelper.instance.getAllLendings(settledFilter: true, limit: _limit, offset: 0);
      
      if (mounted) {
        setState(() {
          _active = active;
          _settled = settled;
          _activeOffset = active.length;
          _settledOffset = settled.length;
          _hasMoreActive = active.length >= _limit;
          _hasMoreSettled = settled.length >= _limit;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore(bool isSettled) async {
    setState(() => _isLoadingMore = true);
    final offset = isSettled ? _settledOffset : _activeOffset;
    final more = await DatabaseHelper.instance.getAllLendings(settledFilter: isSettled, limit: _limit, offset: offset);
    
    if (mounted) {
      setState(() {
        if (isSettled) {
          _settled.addAll(more);
          _settledOffset += more.length;
          _hasMoreSettled = more.length >= _limit;
        } else {
          _active.addAll(more);
          _activeOffset += more.length;
          _hasMoreActive = more.length >= _limit;
        }
        _isLoadingMore = false;
      });
    }
  }

  void _showAddDialog() {
    final nameCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String type = 'lent';
    DateTime? dueDate;

    final uniqueNames = {
      ..._active.map((e) => e.personName),
      ..._settled.map((e) => e.personName),
    }.toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDs) {
          return DraggableScrollableSheet(
            initialChildSize: 0.92,
            minChildSize: 0.6,
            maxChildSize: 1.0,
            builder: (_, scrollController) => Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Handle bar
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'New Lending Record',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  Divider(color: Theme.of(context).colorScheme.outlineVariant),
                  // Scrollable content
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scrollController,
                      padding: EdgeInsets.only(
                        left: 24,
                        right: 24,
                        top: 16,
                        bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Type selector
                          Text('Type', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(value: 'lent', label: Text('I Lent'), icon: Icon(Icons.arrow_upward)),
                              ButtonSegment(value: 'borrowed', label: Text('I Borrowed'), icon: Icon(Icons.arrow_downward)),
                            ],
                            selected: {type},
                            onSelectionChanged: (s) => setDs(() => type = s.first),
                          ),
                          const SizedBox(height: 20),
                          Text('Person Name', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Autocomplete<String>(
                            optionsBuilder: (TextEditingValue textEditingValue) {
                              if (textEditingValue.text.isEmpty) {
                                return uniqueNames;
                              }
                              return uniqueNames.where((String option) {
                                return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                              });
                            },
                            onSelected: (String selection) {
                              nameCtrl.text = selection;
                            },
                            fieldViewBuilder: (context, controller, focusNode, onEditingComplete) {
                              controller.addListener(() {
                                nameCtrl.text = controller.text;
                              });
                              return TextField(
                                controller: controller,
                                focusNode: focusNode,
                                decoration: InputDecoration(
                                  hintText: 'Type or select an existing person',
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                ),
                                textCapitalization: TextCapitalization.words,
                              );
                            },
                          ),
                          const SizedBox(height: 20),
                          Text('Amount', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: amountCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: '0.00',
                              prefixIcon: Icon(Icons.currency_exchange, size: 14),
                              prefixText: '${AppFormat.currencySymbol} ',
                              prefixStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              filled: true,
                              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text('Notes (optional)', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          TextField(
                            controller: notesCtrl,
                            maxLines: 3,
                            decoration: InputDecoration(
                              hintText: 'Add a note...',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              filled: true,
                              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text('Due Date (optional)', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: ctx,
                                initialDate: DateTime.now().add(const Duration(days: 30)),
                                firstDate: DateTime.now(),
                                lastDate: DateTime(2030),
                              );
                              if (picked != null) setDs(() => dueDate = picked);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                                borderRadius: BorderRadius.circular(12),
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.calendar_today, size: 18, color: Colors.grey[400]),
                                  const SizedBox(width: 12),
                                    Text(
                                      dueDate == null
                                          ? 'Select a due date'
                                          : DateFormat('dd MMM yyyy').format(dueDate!),
                                      style: TextStyle(
                                        color: dueDate == null ? Theme.of(context).colorScheme.onSurfaceVariant : Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  if (dueDate != null) ...[
                                    const Spacer(),
                                      GestureDetector(
                                        onTap: () => setDs(() => dueDate = null),
                                        child: Icon(Icons.cancel, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          // Save button
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: () async {
                                final name = nameCtrl.text.trim();
                                final amount = double.tryParse(amountCtrl.text);
                                if (name.isEmpty || amount == null || amount <= 0) return;
                                await DatabaseHelper.instance.insertLending(Lending(
                                  personName: name,
                                  type: type,
                                  originalAmount: amount,
                                  dueDate: dueDate,
                                  notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                                ));
                                if (mounted) {
                                  Navigator.pop(ctx);
                                  _loadData();
                                }
                              },
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                ),
                                child: const Text('Save Record', style: TextStyle(fontSize: 16)),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }


  void _showAddPaymentDialog(Lending lending) {
    final payCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Record Payment — ${lending.personName}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Remaining: ${AppFormat.currency(lending.originalAmount - lending.paidAmount)}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(controller: payCtrl, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Payment Amount')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final payment = double.tryParse(payCtrl.text);
              if (payment == null || payment <= 0) return;
              final newPaid = (lending.paidAmount + payment).clamp(0.0, lending.originalAmount);
              final settled = newPaid >= lending.originalAmount;
              await DatabaseHelper.instance.updateLending(
                  lending.copyWith(paidAmount: newPaid, isSettled: settled));
              if (mounted) { Navigator.pop(context); _loadData(); }
            },
            child: const Text('Save'),
          ),
          if (!lending.isSettled)
            TextButton(
              onPressed: () async {
                await DatabaseHelper.instance.updateLending(
                    lending.copyWith(paidAmount: lending.originalAmount, isSettled: true));
                if (mounted) { Navigator.pop(context); _loadData(); }
              },
              child: const Text('Mark Fully Settled'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalLent = _active.where((l) => l.type == 'lent').fold(0.0, (s, l) => s + l.remainingAmount);
    final totalBorrowed = _active.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + l.remainingAmount);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lending & Borrowing'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Reports',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LendingReportScreen())),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [Tab(text: 'Active'), Tab(text: 'Settled')],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        backgroundColor: Colors.blue,
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              // Summary Bar
              if (_active.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                    _summaryChip('You Lent', '${AppFormat.currency(totalLent)}', Theme.of(context).colorScheme.primary),
                    _summaryChip('You Owe', '${AppFormat.currency(totalBorrowed)}', Theme.of(context).colorScheme.error),
                    _summaryChip('Net', '${AppFormat.currency((totalLent - totalBorrowed).abs())}',
                        totalLent >= totalBorrowed ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error),
                  ]),
                ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildList(_active, _activeScrollController, _hasMoreActive),
                    _buildList(_settled, _settledScrollController, _hasMoreSettled),
                  ],
                ),
              ),
            ]),
    );
  }

  Widget _buildList(List<Lending> items, ScrollController controller, bool hasMore) {
    if (items.isEmpty && !_isLoading) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.handshake_outlined, size: 64, color: Colors.grey[700]),
        const SizedBox(height: 16),
        Text('Nothing here', style: TextStyle(color: Colors.grey[500])),
      ]));
    }

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.all(16),
      itemCount: items.length + (hasMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == items.length) {
          return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
        }
        final l = items[i];
        final isLent = l.type == 'lent';
        final color = isLent ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error;
        final progress = l.originalAmount > 0 ? l.paidAmount / l.originalAmount : 0.0;

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: color.withValues(alpha: 0.1),
                  child: Icon(isLent ? Icons.arrow_upward : Icons.arrow_downward, color: color, size: 16),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.personName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  Text(isLent ? 'You lent' : 'You borrowed',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${AppFormat.currency(l.originalAmount)}',
                      style: TextStyle(fontWeight: FontWeight.w600, color: color, fontSize: 16)),
                  if (l.paidAmount > 0)
                    Text('Paid: ${AppFormat.currency(l.paidAmount)}',
                        style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                ]),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                if (l.dueDate != null)
                  Row(children: [
                    Icon(l.isOverdue ? Icons.warning_amber_rounded : Icons.calendar_today,
                        size: 13, color: l.isOverdue ? Colors.orange : Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(DateFormat('dd MMM yyyy').format(l.dueDate!),
                        style: TextStyle(fontSize: 12,
                            color: l.isOverdue ? Colors.orange : Theme.of(context).colorScheme.onSurfaceVariant)),
                  ])
                else
                  const SizedBox.shrink(),
                if (!l.isSettled)
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                    onPressed: () => _showAddPaymentDialog(l),
                    child: const Text('Record Payment', style: TextStyle(fontSize: 12)),
                  ),
                if (l.isSettled)
                  Row(children: [
                    const Icon(Icons.check_circle, size: 14, color: Colors.green),
                    const SizedBox(width: 4),
                    Text('Settled', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                  ]),
              ]),
            ]),
          ),
        );
      },
    );
  }

  Widget _summaryChip(String label, String value, Color color) => Column(children: [
    Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: color)),
    const SizedBox(height: 2),
    Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[400])),
  ]);
}
