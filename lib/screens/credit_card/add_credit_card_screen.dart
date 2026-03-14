import 'package:flutter/material.dart';
import '../../models/credit_card.dart';
import '../../services/database_helper.dart';
import '../../utils/app_format.dart';


class AddCreditCardScreen extends StatefulWidget {
  final CreditCard? existingCard;
  const AddCreditCardScreen({super.key, this.existingCard});

  @override
  State<AddCreditCardScreen> createState() => _AddCreditCardScreenState();
}

class _AddCreditCardScreenState extends State<AddCreditCardScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _bankCtrl;
  late TextEditingController _last4Ctrl;
  late TextEditingController _limitCtrl;
  late TextEditingController _outstandingCtrl;
  int _billingDay = 1;
  int _dueDay = 20;
  String _cardType = 'visa';
  String _selectedColor = '#6366F1';

  final List<Map<String, dynamic>> _cardColors = [
    {'color': '#6366F1', 'label': 'Indigo'},
    {'color': '#8B5CF6', 'label': 'Purple'},
    {'color': '#EC4899', 'label': 'Pink'},
    {'color': '#EF4444', 'label': 'Red'},
    {'color': '#F59E0B', 'label': 'Amber'},
    {'color': '#10B981', 'label': 'Emerald'},
    {'color': '#0EA5E9', 'label': 'Sky'},
    {'color': '#1D4ED8', 'label': 'Blue'},
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existingCard;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _bankCtrl = TextEditingController(text: e?.bank ?? '');
    _last4Ctrl = TextEditingController(text: e?.last4 ?? '');
    _limitCtrl = TextEditingController(text: e?.creditLimit.toStringAsFixed(0) ?? '');
    _outstandingCtrl = TextEditingController(text: e?.outstanding.toStringAsFixed(0) ?? '0');
    _billingDay = e?.billingDay ?? 1;
    _dueDay = e?.dueDay ?? 20;
    _cardType = e?.cardType ?? 'visa';
    _selectedColor = e?.color ?? '#6366F1';
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _bankCtrl.dispose(); _last4Ctrl.dispose();
    _limitCtrl.dispose(); _outstandingCtrl.dispose();
    super.dispose();
  }

  Color _hexColor(String hex) {
    return Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final card = CreditCard(
      id: widget.existingCard?.id,
      name: _nameCtrl.text.trim(),
      bank: _bankCtrl.text.trim(),
      last4: _last4Ctrl.text.trim().padLeft(4, '0'),
      creditLimit: double.parse(_limitCtrl.text.trim()),
      billingDay: _billingDay,
      dueDay: _dueDay,
      cardType: _cardType,
      color: _selectedColor,
      outstanding: double.tryParse(_outstandingCtrl.text.trim()) ?? 0,
    );
    if (widget.existingCard == null) {
      await DatabaseHelper.instance.insertCreditCard(card);
    } else {
      await DatabaseHelper.instance.updateCreditCard(card);
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingCard == null ? 'Add Credit Card' : 'Edit Card'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('Save', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 16)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Card Preview
              _buildCardPreview(),
              const SizedBox(height: 28),

              _label('Card Name'),
              TextFormField(
                controller: _nameCtrl,
                decoration: _dec('e.g. HDFC Regalia'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              _label('Bank'),
              TextFormField(
                controller: _bankCtrl,
                decoration: _dec('e.g. HDFC, SBI, ICICI'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Last 4 Digits'),
                  TextFormField(
                    controller: _last4Ctrl,
                    decoration: _dec('XXXX'),
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    validator: (v) => (v == null || v.length != 4) ? '4 digits' : null,
                  ),
                ])),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Card Network'),
                  DropdownButtonFormField<String>(
                    value: _cardType,
                    dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    decoration: _dec(''),
                    items: const [
                      DropdownMenuItem(value: 'visa', child: Text('Visa')),
                      DropdownMenuItem(value: 'mastercard', child: Text('Mastercard')),
                      DropdownMenuItem(value: 'rupay', child: Text('RuPay')),
                      DropdownMenuItem(value: 'amex', child: Text('Amex')),
                    ],
                    onChanged: (v) => setState(() => _cardType = v!),
                  ),
                ])),
              ]),
              const SizedBox(height: 16),

              _label('Credit Limit'),
              TextFormField(
                controller: _limitCtrl,
                keyboardType: TextInputType.number,
                decoration: _dec('e.g. 100000'),
                validator: (v) => (double.tryParse(v ?? '') == null) ? 'Enter valid amount' : null,
              ),
              const SizedBox(height: 16),

              _label('Current Outstanding'),
              TextFormField(
                controller: _outstandingCtrl,
                keyboardType: TextInputType.number,
                decoration: _dec('0'),
              ),
              const SizedBox(height: 20),

              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Billing Date (day of month)'),
                  DropdownButtonFormField<int>(
                    value: _billingDay,
                    dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    decoration: _dec(''),
                    items: List.generate(28, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
                    onChanged: (v) => setState(() => _billingDay = v!),
                  ),
                ])),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Due Date (day of month)'),
                  DropdownButtonFormField<int>(
                    value: _dueDay,
                    dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    decoration: _dec(''),
                    items: List.generate(28, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
                    onChanged: (v) => setState(() => _dueDay = v!),
                  ),
                ])),
              ]),
              const SizedBox(height: 20),

              _label('Card Color'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: _cardColors.map((c) {
                  final isSelected = _selectedColor == c['color'];
                  return GestureDetector(
                    onTap: () => setState(() => _selectedColor = c['color']!),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _hexColor(c['color']!),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: 2.5,
                        ),
                        boxShadow: isSelected ? [BoxShadow(color: _hexColor(c['color']!).withValues(alpha: 0.5), blurRadius: 8)] : [],
                      ),
                      child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildCardPreview() {
    final cardColor = _hexColor(_selectedColor);
    return Container(
      width: double.infinity,
      height: 180,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cardColor, cardColor.withValues(alpha: 0.6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: cardColor.withValues(alpha: 0.4), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_bankCtrl.text.isEmpty ? 'BANK' : _bankCtrl.text.toUpperCase(),
                style: const TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 1.5)),
            Text(_cardType.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, letterSpacing: 1)),
          ]),
          const Spacer(),
          Text(
            '**** **** **** ${_last4Ctrl.text.isEmpty ? '0000' : _last4Ctrl.text}',
            style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 3, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_nameCtrl.text.isEmpty ? 'Card Name' : _nameCtrl.text,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              const Text('LIMIT', style: TextStyle(color: Colors.white60, fontSize: 10)),
              Text(
                _limitCtrl.text.isEmpty ? AppFormat.currency(0) : AppFormat.currency(double.tryParse(_limitCtrl.text) ?? 0.0),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ]),
          ]),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w500)),
  );

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Theme.of(context).colorScheme.outline),
    filled: true,
    fillColor: Theme.of(context).colorScheme.surfaceContainer,
    counterText: '',
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  );
}
