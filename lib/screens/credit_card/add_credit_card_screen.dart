import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart' as app_data;
import '../../features/accounts/providers/account_providers.dart';
import '../../models/credit_card.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_section_header.dart';
import '../../features/liabilities/providers/liabilities_providers.dart';
import '../../utils/text_formatter.dart';
import '../../utils/app_format.dart';
import '../bank/add_bank_account_screen.dart';

enum CreditCardFormAction { deleted }

class AddCreditCardScreen extends ConsumerStatefulWidget {
  final CreditCard? existingCard;
  const AddCreditCardScreen({super.key, this.existingCard});

  @override
  ConsumerState<AddCreditCardScreen> createState() =>
      _AddCreditCardScreenState();
}

class _AddCreditCardScreenState extends ConsumerState<AddCreditCardScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _bankCtrl;
  late TextEditingController _last4Ctrl;
  late TextEditingController _limitCtrl;
  late TextEditingController _outstandingCtrl;
  late TextEditingController _lastBillCtrl;
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
    _limitCtrl = TextEditingController(
      text: e?.creditLimit.toStringAsFixed(0) ?? '',
    );
    _outstandingCtrl = TextEditingController(
      text: e?.outstanding.toStringAsFixed(0) ?? '0',
    );
    _lastBillCtrl = TextEditingController(
      text: e?.lastStatementBalance.toStringAsFixed(0) ?? '0',
    );
    _billingDay = e?.billingDay ?? 1;
    _dueDay = e?.dueDay ?? 20;
    _cardType = e?.cardType ?? 'visa';
    _selectedColor = e?.color ?? '#6366F1';

    _nameCtrl.addListener(() => setState(() {}));
    _bankCtrl.addListener(() => setState(() {}));
    _last4Ctrl.addListener(() => setState(() {}));
    _limitCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bankCtrl.dispose();
    _last4Ctrl.dispose();
    _limitCtrl.dispose();
    _outstandingCtrl.dispose();
    _lastBillCtrl.dispose();
    super.dispose();
  }

  Color _hexColor(String hex) {
    final clean = hex.replaceAll('#', '');
    return Color(int.parse('0xFF$clean'));
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final outstanding = double.tryParse(_outstandingCtrl.text.trim()) ?? 0.0;
    final lastStatement = double.tryParse(_lastBillCtrl.text.trim()) ?? 0.0;

    final card = CreditCard(
      id: widget.existingCard?.id,
      name: TextFormatter.normalizeName(_nameCtrl.text),
      bank: TextFormatter.normalizeName(_bankCtrl.text),
      last4: _last4Ctrl.text.trim().padLeft(4, '0'),
      limitAmount: double.parse(_limitCtrl.text.trim()),
      billingDay: _billingDay,
      dueDay: _dueDay,
      cardType: _cardType,
      color: _selectedColor,
      usedAmount: outstanding,
      lastStatementBalance: lastStatement,
    );

    if (widget.existingCard == null) {
      ref.read(app_data.cardsProvider.notifier).add(card);
    } else {
      ref.read(app_data.cardsProvider.notifier).replace(card);
    }

    ref.invalidate(creditCardsProvider);
    ref.invalidate(liabilitiesSummaryProvider);
    ref.invalidate(creditOutstandingProvider);

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _requestDelete() async {
    final existingCard = widget.existingCard;
    if (existingCard == null) {
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Card?'),
        content: Text(
          'Delete ${existingCard.name}? Credit card transactions and EMIs linked to it will remain untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      Navigator.pop(context, CreditCardFormAction.deleted);
    }
  }

  Future<void> _convertToAccount() async {
    final existingCard = widget.existingCard;
    if (existingCard == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convert to Bank Account?'),
        content: Text(
          'Convert "${existingCard.name}" to a bank account? '
          'The credit card will be removed and a new bank account created.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Convert'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final repo = ref.read(accountRepoProvider);
    final newAccountId = await repo.convertCardToAccount(existingCard);
    ref.invalidate(creditCardsProvider);
    ref.invalidate(accountsProvider);
    if (!mounted) return;

    // Pop this screen, then open the new account for editing
    Navigator.pop(context, true);

    final newAccount = await repo.getById(newAccountId);
    if (newAccount != null && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AddBankAccountScreen(existing: newAccount),
        ),
      );
    }
  }

  bool get _isValid {
    if (_nameCtrl.text.trim().isEmpty) return false;
    if (_bankCtrl.text.trim().isEmpty) return false;
    if (_last4Ctrl.text.trim().length != 4) return false;
    final limit = double.tryParse(_limitCtrl.text.trim()) ?? 0.0;
    if (limit <= 0) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Credit Card',
        actions: widget.existingCard == null
            ? null
            : [
                IconButton(
                  onPressed: _convertToAccount,
                  icon: const Icon(Icons.account_balance_rounded),
                  tooltip: 'Convert to bank account',
                ),
                IconButton(
                  onPressed: _requestDelete,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete card',
                ),
              ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Card Preview
                _buildCardPreview(),
                const SizedBox(height: 28),

                const AppSectionHeader(
                  title: 'Card Name',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppTextField(
                  controller: _nameCtrl,
                  hintText: 'e.g. HDFC Regalia',
                ),
                const SizedBox(height: AppSpacing.m),

                const AppSectionHeader(
                  title: 'Bank',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppTextField(
                  controller: _bankCtrl,
                  hintText: 'e.g. HDFC, SBI, ICICI',
                ),
                const SizedBox(height: AppSpacing.m),

                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _label('Last 4 Digits'),
                          TextFormField(
                            controller: _last4Ctrl,
                            decoration: _dec('XXXX'),
                            keyboardType: TextInputType.number,
                            maxLength: 4,
                            validator: (v) => (v == null || v.length != 4)
                                ? '4 digits'
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppSectionHeader(
                            title: 'Card Network',
                            padding: EdgeInsets.only(bottom: AppSpacing.s),
                          ),
                          DropdownButtonFormField<String>(
                            initialValue: _cardType,
                            dropdownColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHigh,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Theme.of(
                                context,
                              ).colorScheme.surfaceContainer,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.m,
                                ),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.m,
                                vertical: 14,
                              ),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'visa',
                                child: Text('Visa'),
                              ),
                              DropdownMenuItem(
                                value: 'mastercard',
                                child: Text('Mastercard'),
                              ),
                              DropdownMenuItem(
                                value: 'rupay',
                                child: Text('RuPay'),
                              ),
                              DropdownMenuItem(
                                value: 'amex',
                                child: Text('Amex'),
                              ),
                            ],
                            onChanged: (v) => setState(() => _cardType = v!),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.m),

                const AppSectionHeader(
                  title: 'Credit Limit',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppTextField(
                  controller: _limitCtrl,
                  keyboardType: TextInputType.number,
                  hintText: 'e.g. 100000',
                ),
                const SizedBox(height: AppSpacing.m),

                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppSectionHeader(
                            title: 'Total Outstanding',
                            padding: EdgeInsets.only(bottom: AppSpacing.s),
                          ),
                          AppTextField(
                            controller: _outstandingCtrl,
                            keyboardType: TextInputType.number,
                            hintText: 'e.g. 5000',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppSectionHeader(
                            title: 'Current Bill Due',
                            padding: EdgeInsets.only(bottom: AppSpacing.s),
                          ),
                          AppTextField(
                            controller: _lastBillCtrl,
                            keyboardType: TextInputType.number,
                            hintText: 'e.g. 2500',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.m),

                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppSectionHeader(
                            title: 'Billing Date (day)',
                            padding: EdgeInsets.only(bottom: AppSpacing.s),
                          ),
                          DropdownButtonFormField<int>(
                            initialValue: _billingDay,
                            dropdownColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHigh,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Theme.of(
                                context,
                              ).colorScheme.surfaceContainer,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.m,
                                ),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.m,
                                vertical: 14,
                              ),
                            ),
                            items: List.generate(
                              28,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text('${i + 1}'),
                              ),
                            ),
                            onChanged: (v) => setState(() => _billingDay = v!),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppSectionHeader(
                            title: 'Due Date (day)',
                            padding: EdgeInsets.only(bottom: AppSpacing.s),
                          ),
                          DropdownButtonFormField<int>(
                            initialValue: _dueDay,
                            dropdownColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHigh,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Theme.of(
                                context,
                              ).colorScheme.surfaceContainer,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.m,
                                ),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.m,
                                vertical: 14,
                              ),
                            ),
                            items: List.generate(
                              28,
                              (i) => DropdownMenuItem(
                                value: i + 1,
                                child: Text('${i + 1}'),
                              ),
                            ),
                            onChanged: (v) => setState(() => _dueDay = v!),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.m),

                const AppSectionHeader(
                  title: 'Card Color',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                Wrap(
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
                            color: isSelected
                                ? Colors.white
                                : Colors.transparent,
                            width: 2.5,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: _hexColor(
                                      c['color']!,
                                    ).withValues(alpha: 0.5),
                                    blurRadius: 8,
                                  ),
                                ]
                              : [],
                        ),
                        child: isSelected
                            ? const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 18,
                              )
                            : null,
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: PrimaryButton(
                  label: 'Save Card',
                  onPressed: _isValid ? _save : null,
                ),
              ),
            ],
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
        borderRadius: BorderRadius.circular(AppRadius.m),
        boxShadow: [
          BoxShadow(
            color: cardColor.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _bankCtrl.text.isEmpty
                    ? 'BANK'
                    : TextFormatter.toSmartTitleCase(_bankCtrl.text),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  letterSpacing: 1.5,
                ),
              ),
              Text(
                TextFormatter.toSmartTitleCase(_cardType),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            '**** **** **** ${_last4Ctrl.text.isEmpty ? '0000' : _last4Ctrl.text}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              letterSpacing: 3,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _nameCtrl.text.isEmpty
                    ? 'Card Name'
                    : TextFormatter.toSmartTitleCase(_nameCtrl.text),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'LIMIT',
                    style: TextStyle(color: Colors.white60, fontSize: 10),
                  ),
                  Text(
                    _limitCtrl.text.isEmpty
                        ? AppFormat.currency(0)
                        : AppFormat.currency(
                            double.tryParse(_limitCtrl.text) ?? 0.0,
                          ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Theme.of(context).colorScheme.outline),
    filled: true,
    fillColor: Theme.of(context).colorScheme.surfaceContainer,
    counterText: '',
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  );
}
