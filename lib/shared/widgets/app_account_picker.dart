import 'package:flutter/material.dart';

import '../../models/bank_account.dart';
import '../../theme/app_theme.dart';

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
    final fillColor = context.fieldFillColor;
    final borderColor = context.fieldBorderColor;

    return DropdownButtonFormField<String>(
      initialValue: selectedAccountId,
      dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        labelText: 'Account',
        labelStyle: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
        filled: true,
        fillColor: fillColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: borderColor, width: 0.75),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: borderColor, width: 0.75),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.secondary,
            width: 1.25,
          ),
        ),
      ),
      items: availableAccounts
          .map(
            (account) => DropdownMenuItem<String>(
              value: account.id,
              child: Text(
                account.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: onAccountSelected,
    );
  }
}
