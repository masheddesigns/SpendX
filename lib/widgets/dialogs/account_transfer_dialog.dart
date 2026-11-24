import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/bank_account.dart';
import '../../models/transaction.dart' as spx;
import '../../data/providers.dart';
import '../custom_snackbar.dart';

/// Opens the standard inter-account transfer modal dialog.
///
/// Allows the user to select source and destination accounts, enter an amount,
/// and posts a balanced double-entry transfer transaction via [FinancialTransactionService].
Future<bool> showAccountTransferDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  List<BankAccount> accounts =
      ref.read(accountsProvider).valueOrNull ?? const <BankAccount>[];
  if (accounts.length < 2) {
    try {
      accounts = await ref.read(accountsProvider.future);
    } catch (_) {}
  }
  if (accounts.length < 2) {
    if (context.mounted) {
      CustomSnackBar.show(
        context,
        message: 'Add at least 2 accounts to transfer.',
        isError: true,
      );
    }
    return false;
  }

  String? sourceId = accounts.first.id;
  String? destId = accounts.last.id;
  final amountController = TextEditingController();

  if (!context.mounted) return false;

  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setInner) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
        title: const Text('Account Transfer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: sourceId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'From Account',
                filled: true,
                fillColor: Theme.of(ctx).colorScheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              dropdownColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              items: accounts
                  .map(
                    (a) => DropdownMenuItem(
                      value: a.id,
                      child: Text(
                        a.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setInner(() => sourceId = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: destId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'To Account',
                filled: true,
                fillColor: Theme.of(ctx).colorScheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              dropdownColor: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              items: accounts
                  .map(
                    (a) => DropdownMenuItem(
                      value: a.id,
                      child: Text(
                        a.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setInner(() => destId = v),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: amountController,
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: '₹',
                filled: true,
                fillColor: Theme.of(ctx).colorScheme.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
            ElevatedButton(
              onPressed: () {
                if (sourceId == destId) {
                  CustomSnackBar.show(
                    ctx,
                    message: 'Source and Destination cannot be same.',
                    isError: true,
                  );
                  return;
                }
                final amount = double.tryParse(amountController.text.trim());
                if (amount == null || amount <= 0) {
                  CustomSnackBar.show(
                    ctx,
                    message: 'Please enter an amount greater than zero.',
                    isError: true,
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Transfer'),
            ),
        ],
      ),
    ),
  );

  if (confirmed == true) {
    final amount = double.tryParse(amountController.text) ?? 0.0;
    if (amount <= 0) return false;

    final tx = spx.Transaction(
      type: 'transfer',
      amount: amount,
      accountId: sourceId!,
      relatedEntityId: destId!,
      date: DateTime.now(),
      notes: 'Internal Transfer',
      userId: 'offline_user',
    );

    await ref.read(financialTransactionServiceProvider).createTransfer(tx);
    invalidateAllFinancialProviders(ref);

    if (context.mounted) {
      CustomSnackBar.show(context, message: 'Transfer successful!');
    }
    return true;
  }
  return false;
}
