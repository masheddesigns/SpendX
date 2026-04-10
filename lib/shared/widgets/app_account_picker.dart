import 'package:flutter/material.dart';

import '../../models/bank_account.dart';

class AppAccountPicker extends StatelessWidget {
  const AppAccountPicker({
    super.key,
    required this.availableAccounts,
    required this.selectedAccountId,
    required this.onAccountSelected,
    this.activeColor,
  });

  final List<BankAccount> availableAccounts;
  final String? selectedAccountId;
  final ValueChanged<String?> onAccountSelected;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: selectedAccountId,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        labelText: 'Account',
      ),
      items: availableAccounts
          .map(
            (account) => DropdownMenuItem<String>(
              value: account.id,
              child: Text(account.name),
            ),
          )
          .toList(),
      onChanged: onAccountSelected,
    );
  }
}
