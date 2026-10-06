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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final fillColor = isDark
        ? const Color(0x1AFFFFFF)
        : const Color(0x66FFFFFF);

    final borderColor = isDark
        ? const Color(0x2EFFFFFF)
        : const Color(0x1F000000);

    return DropdownButtonFormField<String>(
      initialValue: selectedAccountId,
      dropdownColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: isDark ? Colors.white : const Color(0xFF0F172A),
      ),
      decoration: InputDecoration(
        labelText: 'Account',
        labelStyle: TextStyle(
          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          fontWeight: FontWeight.w600,
        ),
        filled: true,
        fillColor: fillColor,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
            color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
            width: 1.25,
          ),
        ),
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
