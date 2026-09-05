import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/utils/category_resolver.dart';
import '../data/providers.dart';
import '../data/repositories/account_repo.dart';
import '../data/repositories/credit_repo.dart';
import '../features/transactions/providers/transaction_providers.dart';
import '../models/bank_account.dart';
import '../models/credit_card.dart';
import '../models/review_item.dart';
import '../models/transaction.dart';
import '../screens/loans/loans_screen.dart';
import '../services/live_sms_service.dart';
import '../services/notification_service_v2.dart';
import '../services/sms_import_service.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/empty_state_widget.dart';
import '../utils/app_format.dart';
import 'import/import_preview_screen.dart';

/// Scans bank SMS messages from the Messages app, lets the user bulk-import
/// detected transactions (with an optional review of any single one), and
/// offers to update linked account / credit card / loan balances.
class SmsImportScreen extends ConsumerStatefulWidget {
  const SmsImportScreen({super.key});

  @override
  ConsumerState<SmsImportScreen> createState() => _SmsImportScreenState();
}

class _SmsImportScreenState extends ConsumerState<SmsImportScreen> {
  static const _ranges = <int?>[30, 60, 90, 180, null];

  bool _scanning = false;
  bool _permissionDenied = false;
  bool _saving = false;
  int? _daysBack = 90;
  String? _defaultAccountId;

  List<SmsImportResult> _transactions = const [];
  List<BalanceHit> _balances = const [];
  List<DetectedAccount> _detectedAccounts = const [];
  List<DetectedCard> _detectedCards = const [];
  Set<int> _selected = {};

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _permissionDenied = false;
      _transactions = const [];
      _balances = const [];
      _detectedAccounts = const [];
      _detectedCards = const [];
      _selected = {};
    });

    final granted = await SmsImportService.instance.requestPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _scanning = false;
        _permissionDenied = true;
      });
      return;
    }

    // Also request RECEIVE_SMS so incoming SMS can be detected live.
    await LiveSmsService.instance.requestReceivePermission();

    SmsScanBundle bundle;
    try {
      bundle = await SmsImportService.instance.scan(
        options: SmsScanOptions(daysBack: _daysBack),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scan failed: $e')),
      );
      return;
    }
    if (!mounted) return;

    if (bundle.balances.isNotEmpty) {
      try {
        await NotificationServiceV2().showNotification(
          title: 'Update your balances',
          body: '${bundle.balances.length} bank/card/loan balance'
              '${bundle.balances.length == 1 ? '' : 's'} detected from SMS. '
              'Tap to review and confirm.',
          category: 'generalUpdates',
          payload: jsonEncode({'source_type': 'balances'}),
        );
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _transactions = bundle.transactions;
      _balances = bundle.balances;
      _detectedAccounts = bundle.accounts;
      _detectedCards = bundle.cards;
      // Everything is included by default — bulk import is the happy path.
      _selected = {
        for (var i = 0; i < bundle.transactions.length; i++) i,
      };
      _scanning = false;
    });

    // Register any detected accounts/cards so they appear in the app.
    await _autoRegisterDetected(bundle.accounts, bundle.cards);
  }

  /// Persists detected bank accounts and credit cards: creates ones that
  /// aren't registered yet (matched by last4) and updates balances for the
  /// ones that already exist.
  Future<void> _autoRegisterDetected(
    List<DetectedAccount> accounts,
    List<DetectedCard> cards,
  ) async {
    if (accounts.isEmpty && cards.isEmpty) return;

    var addedAccounts = 0;
    var updatedAccounts = 0;
    var addedCards = 0;
    var updatedCards = 0;

    try {
      final existingAccounts =
          ref.read(accountsProvider).valueOrNull ?? const <BankAccount>[];
      final existingCards =
          ref.read(cardsProvider).valueOrNull ?? const <CreditCard>[];

      for (final acc in accounts) {
        if (acc.last4 == null || acc.last4!.isEmpty) continue;
        final existing = existingAccounts
            .where((a) => a.last4 == acc.last4)
            .firstOrNull;
        if (existing != null) {
          await AccountRepo().updateBalance(existing.id, acc.balance);
          updatedAccounts++;
        } else {
          await AccountRepo().create(
            BankAccount(
              name: '${acc.bank} Savings',
              bank: acc.bank,
              balance: acc.balance,
              last4: acc.last4,
            ),
          );
          addedAccounts++;
        }
      }

      for (final card in cards) {
        if (card.last4 == null || card.last4!.isEmpty) continue;
        final existing = existingCards
            .where((c) => c.last4 == card.last4)
            .firstOrNull;
        if (existing != null) {
          await CreditRepo().update(
            existing.copyWith(usedAmount: card.outstanding),
          );
          updatedCards++;
        } else {
          await CreditRepo().insert(
            CreditCard(
              name: '${card.bank} Card',
              bank: card.bank,
              last4: card.last4!,
              limitAmount: 0,
              usedAmount: card.outstanding,
            ),
          );
          addedCards++;
        }
      }

      if (addedAccounts > 0 || updatedAccounts > 0) {
        ref.invalidate(accountsProvider);
      }
      if (addedCards > 0 || updatedCards > 0) {
        ref.invalidate(cardsProvider);
      }
    } catch (_) {
      // Non-fatal — import still continues.
    }

    if (!mounted) return;
    final parts = <String>[];
    if (addedAccounts > 0) {
      parts.add('$addedAccounts account${addedAccounts == 1 ? '' : 's'} added');
    }
    if (addedCards > 0) {
      parts.add('$addedCards card${addedCards == 1 ? '' : 's'} added');
    }
    if (updatedAccounts > 0) {
      parts.add(
        '$updatedAccounts balance${updatedAccounts == 1 ? '' : 's'} updated',
      );
    }
    if (updatedCards > 0) {
      parts.add(
        '$updatedCards card outstanding${updatedCards == 1 ? '' : 's'} updated',
      );
    }
    if (parts.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('SMS sync: ${parts.join(', ')}.')),
      );
    }
  }

  // ── Selection ──────────────────────────────────────────────

  void _toggleSelect(int index) {
    setState(() {
      if (!_selected.add(index)) _selected.remove(index);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _transactions.length) {
        _selected.clear();
      } else {
        _selected.addAll(List.generate(_transactions.length, (i) => i));
      }
    });
  }

  bool get _allSelected =>
      _transactions.isNotEmpty && _selected.length == _transactions.length;

  // ── Import ─────────────────────────────────────────────────

  Future<void> _importSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Import $count transaction${count == 1 ? '' : 's'}?'),
        content: Text(
          _defaultAccountId == null
              ? 'These will be added to your ledger. Tap any transaction first '
                  'to review or edit it before importing.'
              : 'These will be added to your ledger in the selected account. '
                  'Tap any transaction first to review or edit it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final indices = _selected.toList()..sort();
    await _saveAll(indices);
  }

  Future<void> _saveAll(List<int> indices) async {
    if (_saving) return;
    setState(() => _saving = true);

    final accounts =
        ref.read(accountsProvider).valueOrNull ?? const <BankAccount>[];
    var saved = 0;
    try {
      for (final index in indices) {
        if (index >= _transactions.length) continue;
        final parsed = _transactions[index].parsed;
        final type = parsed.isCredit ? 'income' : 'expense';
        final categoryId = await _resolveCategoryId(
          parsed.merchant ?? '',
          type,
        );
        final txn = Transaction(
          userId: 'offline_user',
          type: type,
          amount: parsed.amount,
          date: parsed.date,
          categoryId: categoryId,
          // Prefer the explicitly chosen account, else auto-match by the
          // account number last4 / bank name from the SMS.
          accountId: _defaultAccountId ?? _matchAccountId(parsed, accounts),
          notes: parsed.merchant ?? parsed.rawText,
          source: 'sms',
          externalRef: parsed.refId,
          tags: const [],
        );
        await ref.read(addTransactionProvider)(txn);
        saved++;
      }
    } catch (_) {
      // Non-fatal — import as many as we can.
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      _transactions = const [];
      _balances = const [];
      _selected = {};
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported $saved transaction${saved == 1 ? '' : 's'}.')),
    );
  }

  /// Opens a single transaction for review/edit; drops it from the list
  /// afterwards so it can't be imported twice.
  Future<void> _openPreview(int index) async {
    if (index >= _transactions.length) return;
    await Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => ImportPreviewScreen(
          parsed: _transactions[index].parsed,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _transactions = List.of(_transactions)..removeAt(index);
      final shifted = <int>{};
      for (final s in _selected) {
        if (s == index) continue;
        shifted.add(s > index ? s - 1 : s);
      }
      _selected = shifted;
    });
  }

  String? _matchAccountId(ParsedTransaction parsed, List<BankAccount> accounts) {
  if (parsed.last4 != null) {
    final byLast4 = accounts.where((a) => a.last4 == parsed.last4).firstOrNull;
    if (byLast4 != null) return byLast4.id;
  }
  if (parsed.bankName != null) {
    final kw = parsed.bankName!.toLowerCase();
    final byBank = accounts
        .where(
          (a) =>
              a.bank.toLowerCase().contains(kw) ||
              a.name.toLowerCase().contains(kw),
        )
        .toList();
    if (byBank.length == 1) return byBank.first.id;
  }
  return null;
}

Future<String?> _resolveCategoryId(String merchant, String type) async {
    try {
      final resolution = await resolveCategoryForText(
        rawText: merchant,
        merchant: merchant,
        type: type,
      );
      return resolution.id;
    } catch (_) {
      return null;
    }
  }

  // ── Balance updates ────────────────────────────────────────

  Future<void> _openBalanceUpdate(BalanceHit hit) async {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <BankAccount>[];
    final cards = ref.watch(cardsProvider).valueOrNull ?? const <CreditCard>[];

    if (hit.kind == BalanceKind.loan) {
      Navigator.of(context).push(
        AppPageRoute(builder: (_) => const LoansScreen()),
      );
      return;
    }

    final cs = Theme.of(context).colorScheme;
    final title = hit.kind == BalanceKind.bank
        ? 'Update bank balance'
        : 'Update credit card outstanding';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final candidates = hit.kind == BalanceKind.bank
            ? _matchAccounts(hit, accounts)
            : _matchCards(hit, cards);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Text(
                  '$title to ${AppFormat.currency(hit.amount)}?',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'This keeps your net worth up to date. Tap an account to apply.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ),
              if (candidates.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No matching account found. Add it first in Accounts.',
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final account in candidates)
                        ListTile(
                          leading: Icon(
                            hit.kind == BalanceKind.bank
                                ? Icons.account_balance_outlined
                                : Icons.credit_card_outlined,
                            color: cs.primary,
                          ),
                          title: Text(
                            hit.kind == BalanceKind.bank
                                ? (account as BankAccount).name
                                : (account as CreditCard).name,
                          ),
                          subtitle: Text(
                            hit.kind == BalanceKind.bank
                                ? (account as BankAccount).bank
                                : (account as CreditCard).bank,
                          ),
                          onTap: () async {
                            Navigator.pop(sheetContext);
                            await _applyBalanceUpdate(hit, account);
                          },
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  List<Object> _matchAccounts(BalanceHit hit, List<BankAccount> accounts) {
    final kw = hit.bankKeyword?.toLowerCase();
    final matched = kw == null
        ? <BankAccount>[]
        : accounts
              .where(
                (a) =>
                    a.bank.toLowerCase().contains(kw) ||
                    a.name.toLowerCase().contains(kw),
              )
              .toList();
    return (matched.isNotEmpty ? matched : accounts).cast<Object>();
  }

  List<Object> _matchCards(BalanceHit hit, List<CreditCard> cards) {
    final kw = hit.bankKeyword?.toLowerCase();
    final matched = cards
        .where(
          (c) =>
              (hit.last4 != null && c.last4 == hit.last4) ||
              (kw != null &&
                  (c.bank.toLowerCase().contains(kw) ||
                      c.name.toLowerCase().contains(kw))),
        )
        .toList();
    return (matched.isNotEmpty ? matched : cards).cast<Object>();
  }

  Future<void> _applyBalanceUpdate(BalanceHit hit, Object account) async {
    try {
      if (hit.kind == BalanceKind.bank) {
        final a = account as BankAccount;
        await AccountRepo().updateBalance(a.id, hit.amount);
        ref.invalidate(accountsProvider);
      } else {
        final c = account as CreditCard;
        await CreditRepo().update(c.copyWith(usedAmount: hit.amount));
        ref.invalidate(cardsProvider);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Balance updated — net worth refreshed.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update balance.')),
      );
    }
  }

  // ── Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('SMS Import')),
      body: _permissionDenied
          ? _permissionBanner(cs)
          : _scanning
          ? const Center(child: CircularProgressIndicator())
          : _transactions.isEmpty && _balances.isEmpty
          ? _emptyState(cs)
          : _resultsBody(cs),
    );
  }

  Widget _permissionBanner(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sms_outlined, size: 56, color: cs.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            'SMS permission is required',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'SpendX reads your bank transaction messages on-device to detect '
            'expenses, income and balances. Nothing is uploaded.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => openAppSettings(),
            icon: const Icon(Icons.settings_rounded),
            label: const Text('Open Settings'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _scan, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _emptyState(ColorScheme cs) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.sms_rounded, color: cs.primary, size: 28),
              const SizedBox(height: 12),
              Text(
                'Import from Messages',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Scan bank SMS alerts (debited/credited/UPI) from your Messages '
                'app. Import everything in one tap, review any single '
                'transaction, and keep your balances in sync.',
                style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _rangeSelector(cs),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _scan,
          icon: const Icon(Icons.search_rounded),
          label: Text(_scanning ? 'Scanning…' : 'Scan Bank SMS'),
        ),
        const SizedBox(height: 32),
        const EmptyStateWidget(
          icon: Icons.mark_email_read_outlined,
          title: 'No bank SMS yet',
          description:
              'Tap "Scan Bank SMS" to look for transaction messages in your '
              'Messages app.',
        ),
      ],
    );
  }

  Widget _rangeSelector(ColorScheme cs) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final range in _ranges)
          ChoiceChip(
            label: Text(range == null ? 'All' : '$range days'),
            selected: _daysBack == range,
            onSelected: (_) => setState(() => _daysBack = range),
          ),
      ],
    );
  }

  Widget _resultsBody(ColorScheme cs) {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <BankAccount>[];
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_transactions.length} transaction${_transactions.length == 1 ? '' : 's'} found',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Scan again'),
                  ),
                ],
              ),
              if (_balances.isNotEmpty ||
                  _detectedAccounts.isNotEmpty ||
                  _detectedCards.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    [
                      if (_balances.isNotEmpty)
                        '${_balances.length} balance${_balances.length == 1 ? '' : 's'}',
                      if (_detectedAccounts.isNotEmpty)
                        '${_detectedAccounts.length} account${_detectedAccounts.length == 1 ? '' : 's'}',
                      if (_detectedCards.isNotEmpty)
                        '${_detectedCards.length} card${_detectedCards.length == 1 ? '' : 's'}',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              _rangeSelector(cs),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _defaultAccountId,
                decoration: const InputDecoration(
                  labelText: 'Add to account (optional)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('No account')),
                  for (final a in accounts)
                    DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text('${a.name} (${a.bank})'),
                    ),
                ],
                onChanged: (v) => setState(() => _defaultAccountId = v),
              ),
              const SizedBox(height: 12),
              if (_detectedAccounts.isNotEmpty ||
                  _detectedCards.isNotEmpty) ...[
                _detectedEntitiesSection(cs),
                const SizedBox(height: 12),
              ],
              if (_balances.isNotEmpty) ...[
                _balancesSection(cs),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Checkbox(
                    value: _allSelected,
                    onChanged: (_) => _toggleSelectAll(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _allSelected
                          ? 'All ${_transactions.length} selected'
                          : 'Select all',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (int i = 0; i < _transactions.length; i++) ...[
                _transactionTile(cs, i),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        // Bottom import bar — the single, clear bulk action.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed:
                    _selected.isEmpty || _saving ? null : _importSelected,
                icon: const Icon(Icons.done_all_rounded),
                label: Text(
                  _selected.isEmpty
                      ? 'Select transactions to import'
                      : 'Import ${_selected.length} transaction'
                            '${_selected.length == 1 ? '' : 's'}',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _transactionTile(ColorScheme cs, int index) {
    final result = _transactions[index];
    final isCredit = result.parsed.isCredit;
    final color = isCredit ? const Color(0xFF22C55E) : cs.error;
    return Card(
      child: ListTile(
        onTap: () => _openPreview(index),
        leading: Checkbox(
          value: _selected.contains(index),
          onChanged: (_) => _toggleSelect(index),
        ),
        title: Text(
          result.parsed.merchant ?? 'Unknown merchant',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${isCredit ? 'Received' : 'Spent'} '
          '${AppFormat.currency(result.parsed.amount)} • '
          '${AppFormat.date(result.parsed.date)}',
        ),
        trailing: Icon(
          isCredit ? Icons.south_west_rounded : Icons.north_east_rounded,
          color: color,
          size: 20,
        ),
      ),
    );
  }

  Widget _detectedEntitiesSection(ColorScheme cs) {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <BankAccount>[];
    final cards = ref.watch(cardsProvider).valueOrNull ?? const <CreditCard>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Detected accounts & cards',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (final acc in _detectedAccounts) ...[
          Card(
            child: ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.account_balance_outlined,
                    color: cs.primary, size: 20),
              ),
              title: Text(
                '${acc.bank}${acc.last4 != null ? ' ••${acc.last4}' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('Balance ${AppFormat.currency(acc.balance)}'),
              trailing: TextButton(
                onPressed: () => _registerOrUpdateAccount(acc, accounts),
                child: Text(
                  accounts.any((a) => a.last4 != null && a.last4 == acc.last4)
                      ? 'Update'
                      : 'Register',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        for (final card in _detectedCards) ...[
          Card(
            child: ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.credit_card_outlined,
                    color: cs.primary, size: 20),
              ),
              title: Text(
                '${card.bank}${card.last4 != null ? ' ••${card.last4}' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('Outstanding ${AppFormat.currency(card.outstanding)}'),
              trailing: TextButton(
                onPressed: () => _registerOrUpdateCard(card, cards),
                child: Text(
                  cards.any((c) => c.last4 == card.last4)
                      ? 'Update'
                      : 'Register',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Future<void> _registerOrUpdateAccount(
    DetectedAccount acc,
    List<BankAccount> accounts,
  ) async {
    final existing = accounts
        .where((a) => a.last4 != null && a.last4 == acc.last4)
        .firstOrNull;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          existing == null ? 'Register bank account?' : 'Update balance?',
        ),
        content: Text(
          existing == null
              ? 'Add ${acc.bank} with a balance of '
                  '${AppFormat.currency(acc.balance)}?'
              : 'Set ${existing.name} balance to '
                  '${AppFormat.currency(acc.balance)}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(existing == null ? 'Register' : 'Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      if (existing != null) {
        await AccountRepo().updateBalance(existing.id, acc.balance);
      } else {
        await AccountRepo().create(
          BankAccount(
            name: '${acc.bank} Savings',
            bank: acc.bank,
            balance: acc.balance,
            last4: acc.last4,
          ),
        );
      }
      ref.invalidate(accountsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            existing == null
                ? 'Registered ${acc.bank} with ₹${acc.balance.round()}.'
                : 'Balance updated.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save account.')),
      );
    }
  }

  Future<void> _registerOrUpdateCard(
    DetectedCard card,
    List<CreditCard> cards,
  ) async {
    final existing = cards.where((c) => c.last4 == card.last4).firstOrNull;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          existing == null ? 'Register credit card?' : 'Update outstanding?',
        ),
        content: Text(
          existing == null
              ? 'Add a ${card.bank} card with outstanding '
                  '${AppFormat.currency(card.outstanding)}?'
              : 'Set ${existing.name} outstanding to '
                  '${AppFormat.currency(card.outstanding)}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(existing == null ? 'Register' : 'Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      if (existing != null) {
        await CreditRepo().update(existing.copyWith(usedAmount: card.outstanding));
      } else {
        await CreditRepo().insert(
          CreditCard(
            name: '${card.bank} Card',
            bank: card.bank,
            last4: card.last4 ?? '0000',
            limitAmount: 0,
            usedAmount: card.outstanding,
          ),
        );
      }
      ref.invalidate(cardsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            existing == null
                ? 'Registered ${card.bank} card.'
                : 'Outstanding updated.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save card.')),
      );
    }
  }

  Widget _balancesSection(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Balances detected (${_balances.length})',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (final hit in _balances) ...[
          Card(
            child: ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  hit.kind == BalanceKind.bank
                      ? Icons.account_balance_outlined
                      : hit.kind == BalanceKind.creditCard
                      ? Icons.credit_card_outlined
                      : Icons.account_balance_rounded,
                  color: cs.primary,
                  size: 20,
                ),
              ),
              title: Text(
                hit.kind == BalanceKind.bank
                    ? 'Bank balance'
                    : hit.kind == BalanceKind.creditCard
                    ? 'Credit card outstanding'
                    : 'Loan balance',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(AppFormat.currency(hit.amount)),
              trailing: TextButton(
                onPressed: () => _openBalanceUpdate(hit),
                child: const Text('Update'),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}