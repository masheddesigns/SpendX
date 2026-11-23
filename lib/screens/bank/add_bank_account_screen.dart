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
    {'key': 'stock', 'label': 'Stocks / Equity'},
    {'key': 'mutual_fund', 'label': 'Mutual Funds'},
    {'key': 'gold', 'label': 'Gold / Sovereign'},
    {'key': 'ppf', 'label': 'PPF / EPF / NPS'},
    {'key': 'real_estate', 'label': 'Real Estate'},
    {'key': 'wallet', 'label': 'Digital Wallet'},
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
    final bankText = _bankCtrl.text.trim().isEmpty && _isInvestment
        ? _nameCtrl.text.trim()
        : _bankCtrl.text.trim();
    final account = BankAccount(
      id: widget.existing?.id,
      name: TextFormatter.normalizeName(_nameCtrl.text),
      bank: TextFormatter.normalizeName(bankText),
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
      final oldBalance = widget.existing!.balance;
      if ((account.balance - oldBalance).abs() >= 0.01) {
        await ref.read(accountRepoProvider).updateBalance(account.id, account.balance);
        await ref.read(accountsProvider.notifier).refresh();
      }
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

  bool get _isInvestment =>
      const ['stock', 'mutual_fund', 'gold', 'ppf', 'real_estate']
          .contains(_accountType);

  String get _title {
    if (widget.existing != null) {
      return _isInvestment ? 'Edit Asset' : 'Edit Account';
    }
    switch (_accountType) {
      case 'stock':
        return 'Add Stocks & Equity';
      case 'mutual_fund':
        return 'Add Mutual Funds';
      case 'gold':
        return 'Add Gold & Metals';
      case 'ppf':
        return 'Add EPF / PPF / NPS';
      case 'real_estate':
        return 'Add Real Estate';
      default:
        return 'Add Account';
    }
  }

  String get _nameLabel {
    switch (_accountType) {
      case 'stock':
        return 'Portfolio / Broker Name';
      case 'mutual_fund':
        return 'Fund or Platform Name';
      case 'gold':
        return 'Asset Description';
      case 'ppf':
        return 'Retirement Account';
      case 'real_estate':
        return 'Property Name';
      default:
        return 'Account Name';
    }
  }

  String get _nameHint {
    switch (_accountType) {
      case 'stock':
        return 'e.g. Zerodha Kite, Angel One, US Stocks';
      case 'mutual_fund':
        return 'e.g. Groww Mutual Funds, Coin SIP';
      case 'gold':
        return 'e.g. Sovereign Gold Bonds, 24K Physical';
      case 'ppf':
        return 'e.g. EPFO Provident Fund, SBI PPF';
      case 'real_estate':
        return 'e.g. 2BHK Apartment, Residential Plot';
      default:
        return 'e.g. SBI Savings, HDFC Salary';
    }
  }

  String get _bankLabel {
    switch (_accountType) {
      case 'stock':
        return 'Broker / Depository';
      case 'mutual_fund':
        return 'Platform / AMC';
      case 'gold':
        return 'Held at / Issuer';
      case 'ppf':
        return 'Institution';
      case 'real_estate':
        return 'Location / Builder';
      default:
        return 'Bank / Institution';
    }
  }

  String get _bankHint {
    switch (_accountType) {
      case 'stock':
        return 'e.g. Zerodha, Upstox, Groww';
      case 'mutual_fund':
        return 'e.g. Groww, Nippon India, SBI MF';
      case 'gold':
        return 'e.g. RBI SGB, Home Locker, Tanishq';
      case 'ppf':
        return 'e.g. EPFO, SBI, Post Office';
      case 'real_estate':
        return 'e.g. Bangalore, Prestige';
      default:
        return 'e.g. SBI, HDFC, ICICI';
    }
  }

  bool get _isValid {
    if (_nameCtrl.text.trim().isEmpty) return false;
    if (!_isInvestment && _bankCtrl.text.trim().isEmpty) return false;
    if (_balanceCtrl.text.trim().isEmpty) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SpendXScaffold(
      appBar: SpendXAppBar(
        title: _title,
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
                      _isInvestment ? 'Asset & Valuation Details' : 'Account Details',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimaryOf(context),
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _nameCtrl,
                      labelText: _nameLabel,
                      hintText: _nameHint,
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Please enter a name';
                        }
                        if (val.trim().length < 2) {
                          return 'Name must be at least 2 characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    AppTextField(
                      controller: _bankCtrl,
                      labelText: _bankLabel,
                      hintText: _bankHint,
                      validator: (val) {
                        if (!_isInvestment && (val == null || val.trim().isEmpty)) {
                          return 'Please enter an institution';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _isInvestment ? 'Current Valuation' : 'Initial Balance',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondaryOf(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    AppAmountField(
                      controller: _balanceCtrl,
                      validator: (value) {
                        final amount = double.tryParse(
                          (value ?? '').trim().replaceAll(',', ''),
                        );
                        if (amount == null || !amount.isFinite || amount < 0) {
                          return 'Enter a valid balance of zero or more';
                        }
                        return null;
                      },
                    ),
                    if (_isInvestment) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Tip: You can update this valuation anytime in the Net Worth screen.',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textMutedOf(context),
                        ),
                      ),
                    ],
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
                        color: AppColors.textPrimaryOf(context),
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
                                    : AppColors.textSecondaryOf(context),
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
                              color: AppColors.textPrimaryOf(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Disable for loan or liability accounts',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMutedOf(context),
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
                  child: Text(_isInvestment ? 'Save Asset' : 'Save Account'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
