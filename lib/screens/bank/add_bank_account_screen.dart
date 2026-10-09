import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/accounts/providers/account_providers.dart';
import '../../models/bank_account.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_amount_field.dart';
import '../../utils/text_formatter.dart';
import '../credit_card/add_credit_card_screen.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/app_confirm_dialog.dart';
import '../../shared/widgets/glass/spendx_scaffold.dart';
import '../../shared/widgets/glass/spendx_glass_surface.dart';
import '../../shared/widgets/glass/spendx_glass_button.dart';

class AddBankAccountScreen extends ConsumerStatefulWidget {
  final BankAccount? existing;
  final String? initialType;
  const AddBankAccountScreen({super.key, this.existing, this.initialType});

  @override
  ConsumerState<AddBankAccountScreen> createState() =>
      _AddBankAccountScreenState();
}

class _AddBankAccountScreenState extends ConsumerState<AddBankAccountScreen> {
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
    _balanceCtrl = TextEditingController(
      text: e?.balance.toStringAsFixed(0) ?? '',
    );
    _accountType = e?.accountType ?? widget.initialType ?? 'savings';
    _isAsset = e?.isAsset ?? true;

    _nameCtrl.addListener(() => setState(() {}));
    _bankCtrl.addListener(() => setState(() {}));
    _balanceCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bankCtrl.dispose();
    _balanceCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final account = BankAccount(
      id: widget.existing?.id,
      name: TextFormatter.normalizeName(_nameCtrl.text),
      bank: TextFormatter.normalizeName(_bankCtrl.text),
      accountType: _accountType,
      balance: double.parse(_balanceCtrl.text.trim()),
      color: BankAccount.colorForType(_accountType),
      icon: BankAccount.iconForType(_accountType),
      isAsset: _isAsset,
    );
    if (widget.existing == null) {
      debugPrint('🏦 Account created: ${account.name}');
      await ref.read(accountsProvider.notifier).add(account);
    } else {
      await ref.read(accountsProvider.notifier).replace(account);
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;

    final confirm = await AppConfirmDialog.show(
      context,
      title: 'Delete Account?',
      message: 'Are you sure you want to delete ${existing.name}? All associated transaction links will be detached.',
      confirmLabel: 'Delete',
      isDangerous: true,
    );

    if (confirm == true) {
      await ref.read(accountsProvider.notifier).remove(existing.id);
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _convertToCard() async {
    final existing = widget.existing;
    if (existing == null) return;

    final confirm = await AppConfirmDialog.show(
      context,
      title: 'Convert to Credit Card?',
      message: 'Convert "${existing.name}" to a credit card? The bank account will be removed and a new credit card created.',
      confirmLabel: 'Convert',
    );
    if (confirm != true) return;

    final repo = ref.read(accountRepoProvider);
    final newCardId = await repo.convertAccountToCard(existing);
    ref.invalidate(accountsProvider);
    if (!mounted) return;

    // Pop this screen, then open the new card for editing
    Navigator.pop(context, true);

    final cards = await repo.getCards();
    final newCard = cards.where((c) => c.id == newCardId).firstOrNull;
    if (newCard != null && mounted) {
      Navigator.push(
        context,
        AppPageRoute(
          builder: (_) => AddCreditCardScreen(existingCard: newCard),
        ),
      );
    }
  }

  bool get _isValid {
    if (_nameCtrl.text.trim().isEmpty) return false;
    if (_bankCtrl.text.trim().isEmpty) return false;
    // Balance can be 0 or negative for some accounts, but let's require a valid number entry
    if (_balanceCtrl.text.trim().isEmpty) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: widget.existing == null ? 'Add Account' : 'Edit Account',
        actions: widget.existing == null
            ? null
            : [
                IconButton(
                  onPressed: _convertToCard,
                  icon: const Icon(Icons.credit_card_rounded),
                  tooltip: 'Convert to credit card',
                ),
                IconButton(
                  onPressed: _delete,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.danger,
                  ),
                  tooltip: 'Delete account',
                ),
              ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Details Card ──────────────────────────────
              SpendXGlassSurface(
                level: SpendXGlassLevel.base,
                borderRadius: BorderRadius.circular(AppRadius.l),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Account Details',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppColors.primaryText : const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _nameCtrl,
                      hintText: 'e.g. SBI Savings, Zerodha Stocks',
                    ),
                    const SizedBox(height: 14),
                    AppTextField(
                      controller: _bankCtrl,
                      hintText: 'e.g. SBI, HDFC, Zerodha',
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Initial Balance',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isDark ? AppColors.secondaryText : const Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 6),
                    AppAmountField(controller: _balanceCtrl),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Account Type Card ─────────────────────────
              SpendXGlassSurface(
                level: SpendXGlassLevel.base,
                borderRadius: BorderRadius.circular(AppRadius.l),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Account Type',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppColors.primaryText : const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _types.map((t) {
                        final isSelected = _accountType == t['key'];
                        final cleanHex = BankAccount.colorForType(
                          t['key']!,
                        ).replaceAll('#', '');
                        final color = Color(int.parse('0xFF$cleanHex'));
                        return GestureDetector(
                          onTap: () => setState(() {
                            _accountType = t['key']!;
                            _isAsset = true;
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? color.withValues(alpha: isDark ? 0.25 : 0.18)
                                  : (isDark ? const Color(0x14FFFFFF) : const Color(0x40FFFFFF)),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? color
                                    : (isDark ? const Color(0x24FFFFFF) : const Color(0x18000000)),
                                width: isSelected ? 1.25 : 0.75,
                              ),
                            ),
                            child: Text(
                              t['label']!,
                              style: TextStyle(
                                color: isSelected
                                    ? color
                                    : (isDark ? AppColors.secondaryText : const Color(0xFF475569)),
                                fontSize: 13,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Asset or Liability toggle ─────────────────
              SpendXGlassSurface(
                level: SpendXGlassLevel.base,
                borderRadius: BorderRadius.circular(AppRadius.l),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Count as Asset',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark ? AppColors.primaryText : const Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Disable for loan or liability accounts',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? AppColors.mutedText : const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _isAsset,
                      onChanged: (v) => setState(() => _isAsset = v),
                      activeThumbColor: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: SpendXGlassButton(
                  variant: SpendXGlassButtonVariant.tonal,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SpendXGlassButton(
                  variant: SpendXGlassButtonVariant.primary,
                  onPressed: _isValid ? _save : null,
                  child: const Text('Save Account'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
