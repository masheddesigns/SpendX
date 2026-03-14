import 'package:flutter/material.dart';
import '../../models/bank_account.dart';
import '../../services/database_helper.dart';
import '../../theme/app_theme.dart';

class AddBankAccountScreen extends StatefulWidget {
  final BankAccount? existing;
  const AddBankAccountScreen({super.key, this.existing});

  @override
  State<AddBankAccountScreen> createState() => _AddBankAccountScreenState();
}

class _AddBankAccountScreenState extends State<AddBankAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _bankCtrl;
  late TextEditingController _balanceCtrl;
  String _accountType = 'savings';
  bool _isAsset = true;

  final _types = [
    {'key': 'cash', 'label': 'Physical Cash'},
    {'key': 'savings', 'label': 'Savings'},
    {'key': 'current', 'label': 'Current'},
    {'key': 'fd', 'label': 'Fixed Deposit'},
    {'key': 'ppf', 'label': 'PPF'},
    {'key': 'wallet', 'label': 'Wallet'},
    {'key': 'stock', 'label': 'Stocks'},
    {'key': 'mutual_fund', 'label': 'Mutual Fund'},
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _bankCtrl = TextEditingController(text: e?.bank ?? '');
    _balanceCtrl = TextEditingController(text: e?.balance.toStringAsFixed(0) ?? '');
    _accountType = e?.accountType ?? 'savings';
    _isAsset = e?.isAsset ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _bankCtrl.dispose(); _balanceCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final account = BankAccount(
      id: widget.existing?.id,
      name: _nameCtrl.text.trim(),
      bank: _bankCtrl.text.trim(),
      accountType: _accountType,
      balance: double.parse(_balanceCtrl.text.trim()),
      color: BankAccount.colorForType(_accountType),
      icon: BankAccount.iconForType(_accountType),
      isAsset: _isAsset,
    );
    if (widget.existing == null) {
      await DatabaseHelper.instance.insertBankAccount(account);
    } else {
      await DatabaseHelper.instance.updateBankAccount(account);
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add Account' : 'Edit Account'),
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
              _label('Account Name'),
              TextFormField(
                controller: _nameCtrl,
                decoration: _dec('e.g. SBI Savings, Zerodha Stocks'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              _label('Institution / Bank'),
              TextFormField(
                controller: _bankCtrl,
                decoration: _dec('e.g. SBI, HDFC, Zerodha'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              _label('Balance / Current Value'),
              TextFormField(
                controller: _balanceCtrl,
                keyboardType: TextInputType.number,
                decoration: _dec('e.g. 50000'),
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
                validator: (v) => double.tryParse(v ?? '') == null ? 'Enter valid amount' : null,
              ),
              const SizedBox(height: 20),

              _label('Account Type'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _types.map((t) {
                  final isSelected = _accountType == t['key'];
                  final color = Color(int.parse('FF${BankAccount.colorForType(t['key']!).replaceAll('#', '')}', radix: 16));
                  return GestureDetector(
                    onTap: () => setState(() {
                      _accountType = t['key']!;
                      // Liabilities default off for these types
                      _isAsset = true;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? color.withValues(alpha: 0.25) : Theme.of(context).colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: isSelected ? color : Theme.of(context).colorScheme.outlineVariant),
                      ),
                      child: Text(t['label']!, style: TextStyle(color: isSelected ? color : Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),

              // Asset or Liability toggle
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                   Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Count as Asset', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600)),
                    Text('Disable for loan/liability accounts', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                  ])),
                  Switch(value: _isAsset, onChanged: (v) => setState(() => _isAsset = v), activeColor: Theme.of(context).colorScheme.primary),
                ]),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
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
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  );
}
