import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/emi_plan.dart';
import '../../models/credit_card.dart';
import '../../services/database_helper.dart';
import '../../utils/app_format.dart';


class AddEmiScreen extends StatefulWidget {
  final CreditCard? card;
  final EmiPlan? existingPlan;

  const AddEmiScreen({super.key, this.card, this.existingPlan});

  @override
  State<AddEmiScreen> createState() => _AddEmiScreenState();
}

class _AddEmiScreenState extends State<AddEmiScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _principalCtrl;
  late TextEditingController _rateCtrl;
  late TextEditingController _tenureCtrl;
  DateTime _startDate = DateTime.now();
  String? _selectedCardId;
  List<CreditCard> _cards = [];
  bool _isLoading = true;

  // Live calculation results
  double? _emiAmount;
  double? _totalPayable;
  double? _totalInterest;

  @override
  void initState() {
    super.initState();
    final e = widget.existingPlan;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _principalCtrl = TextEditingController(text: e?.principal.toStringAsFixed(0) ?? '');
    _rateCtrl = TextEditingController(text: e?.interestRate.toString() ?? '0');
    _tenureCtrl = TextEditingController(text: e?.tenureMonths.toString() ?? '12');
    _startDate = e?.startDate ?? DateTime.now();
    _selectedCardId = e?.cardId ?? widget.card?.id;

    _principalCtrl.addListener(_recalculate);
    _rateCtrl.addListener(_recalculate);
    _tenureCtrl.addListener(_recalculate);

    _loadCards();
    _recalculate();
  }

  Future<void> _loadCards() async {
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    if (mounted) setState(() { _cards = cards; _isLoading = false; });
  }

  void _recalculate() {
    final p = double.tryParse(_principalCtrl.text.trim());
    final r = double.tryParse(_rateCtrl.text.trim()) ?? 0;
    final n = int.tryParse(_tenureCtrl.text.trim());
    if (p != null && n != null && n > 0 && p > 0) {
      setState(() {
        _emiAmount = EmiPlan.calculateEmiAmount(p, r, n);
        _totalPayable = _emiAmount! * n;
        _totalInterest = _totalPayable! - p;
      });
    } else {
      setState(() { _emiAmount = null; _totalPayable = null; _totalInterest = null; });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _principalCtrl.dispose();
    _rateCtrl.dispose(); _tenureCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_emiAmount == null) return;

    final plan = EmiPlan(
      id: widget.existingPlan?.id,
      cardId: _selectedCardId,
      name: _nameCtrl.text.trim(),
      principal: double.parse(_principalCtrl.text.trim()),
      interestRate: double.tryParse(_rateCtrl.text.trim()) ?? 0,
      tenureMonths: int.parse(_tenureCtrl.text.trim()),
      emiAmount: _emiAmount,
      startDate: _startDate,
    );

    if (widget.existingPlan == null) {
      await DatabaseHelper.instance.insertEmiPlan(plan);
    } else {
      await DatabaseHelper.instance.updateEmiPlan(plan);
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingPlan == null ? 'Add EMI Plan' : 'Edit EMI Plan'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('Save', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 16)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Live EMI summary card
              if (_emiAmount != null) _buildEmiSummaryCard(),
              if (_emiAmount != null) const SizedBox(height: 20),

              _label('Item / Purchase Name'),
              TextFormField(
                controller: _nameCtrl,
                decoration: _dec('e.g. iPhone 16 Pro, Samsung TV'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              _label('Purchase Amount'),
              TextFormField(
                controller: _principalCtrl,
                keyboardType: TextInputType.number,
                decoration: _dec('e.g. 80000'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                validator: (v) => (double.tryParse(v ?? '') == null) ? 'Enter valid amount' : null,
              ),
              const SizedBox(height: 16),

              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Interest Rate (% p.a.)'),
                  TextFormField(
                    controller: _rateCtrl,
                    keyboardType: TextInputType.number,
                    decoration: _dec('0 for zero-cost'),
                  ),
                ])),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Tenure (months)'),
                  TextFormField(
                    controller: _tenureCtrl,
                    keyboardType: TextInputType.number,
                    decoration: _dec('e.g. 12'),
                    validator: (v) => (int.tryParse(v ?? '') == null) ? 'Required' : null,
                  ),
                ])),
              ]),
              const SizedBox(height: 16),

              _label('Linked Credit Card (optional)'),
              DropdownButtonFormField<String>(
                value: _selectedCardId,
                dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                decoration: _dec('No card / Cash EMI'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('No card / Cash EMI')),
                  ..._cards.map((c) => DropdownMenuItem(value: c.id, child: Text('${c.name} ····${c.last4}'))),
                ],
                onChanged: (v) => setState(() => _selectedCardId = v),
              ),
              const SizedBox(height: 16),

              _label('First EMI Date'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(DateFormat('MMMM d, yyyy').format(_startDate),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w500)),
                trailing: Icon(Icons.calendar_today, color: Theme.of(context).colorScheme.primary),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _startDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2035),
                  );
                  if (d != null) setState(() => _startDate = d);
                },
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmiSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.3), Theme.of(context).colorScheme.secondary.withValues(alpha: 0.15)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(children: [
        const Text('EMI BREAKDOWN', style: TextStyle(color: Colors.white60, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Text(
          '${AppFormat.currency(_emiAmount!)} / month',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 34, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _summaryItem('Principal', AppFormat.currency(double.tryParse(_principalCtrl.text) ?? 0.0), Theme.of(context).colorScheme.primary),
          _summaryItem('Interest', AppFormat.currency(_totalInterest ?? 0), Theme.of(context).colorScheme.error),
          _summaryItem('Total Pay', AppFormat.currency(_totalPayable ?? 0), Theme.of(context).colorScheme.secondary),
        ]),
      ]),
    );
  }

  Widget _summaryItem(String label, String val, Color c) => Column(children: [
    Text(val, style: TextStyle(color: c, fontSize: 15, fontWeight: FontWeight.w600)),
    Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
  ]);

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w500)),
  );

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    filled: true,
    fillColor: Theme.of(context).colorScheme.surfaceContainer,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  );
}
