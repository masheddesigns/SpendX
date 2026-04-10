import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/accounts/providers/account_providers.dart';
import '../../models/bank_account.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/app_text_field.dart';
import '../../shared/widgets/spendx_app_bar.dart';
import '../../shared/widgets/app_section_header.dart';
import '../../shared/widgets/app_amount_field.dart';
import '../../utils/text_formatter.dart';
import '../credit_card/add_credit_card_screen.dart';

class AddBankAccountScreen extends ConsumerStatefulWidget {
  final BankAccount? existing;
  const AddBankAccountScreen({super.key, this.existing});

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
    _accountType = e?.accountType ?? 'savings';
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

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account?'),
        content: Text('Delete ${existing.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ref.read(accountsProvider.notifier).remove(existing.id);
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _convertToCard() async {
    final existing = widget.existing;
    if (existing == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convert to Credit Card?'),
        content: Text(
          'Convert "${existing.name}" to a credit card? '
          'The bank account will be removed and a new credit card created.',
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
        MaterialPageRoute(
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
    return Scaffold(
      appBar: SpendXAppBar(
        title: 'Account',
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
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: 'Delete account',
                ),
              ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSectionHeader(
                  title: 'Account Name',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppTextField(
                  controller: _nameCtrl,
                  hintText: 'e.g. SBI Savings, Zerodha Stocks',
                ),
                const SizedBox(height: AppSpacing.m),

                const AppSectionHeader(
                  title: 'Institution / Bank',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppTextField(
                  controller: _bankCtrl,
                  hintText: 'e.g. SBI, HDFC, Zerodha',
                ),
                const SizedBox(height: AppSpacing.m),

                const AppSectionHeader(
                  title: 'Balance / Current Value',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
                AppAmountField(controller: _balanceCtrl),
                const SizedBox(height: AppSpacing.m),

                const AppSectionHeader(
                  title: 'Account Type',
                  padding: EdgeInsets.only(bottom: AppSpacing.s),
                ),
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
                        // Liabilities default off for these types
                        _isAsset = true;
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? color.withValues(alpha: 0.25)
                              : Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(AppRadius.m),
                          border: Border.all(
                            color: isSelected
                                ? color
                                : Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Text(
                          t['label']!,
                          style: TextStyle(
                            color: isSelected
                                ? color
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            fontSize: 13,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),

                // Asset or Liability toggle
                AppCard(
                  padding: const EdgeInsets.all(AppSpacing.m),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Count as Asset',
                              style: AppTextStyles.titleSmall,
                            ),
                            Text(
                              'Disable for loan/liability accounts',
                              style: AppTextStyles.bodySmall.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _isAsset,
                        onChanged: (v) => setState(() => _isAsset = v),
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
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
                  label: 'Save Account',
                  onPressed: _isValid ? _save : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
