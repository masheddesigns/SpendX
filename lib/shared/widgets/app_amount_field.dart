import 'package:flutter/material.dart';

import '../../services/settings_service.dart';

class AppAmountField extends StatelessWidget {
  const AppAmountField({
    super.key,
    required this.controller,
    this.focusNode,
    this.amountColor,
    this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final Color? amountColor;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: amountColor ?? cs.primary,
      ),
      decoration: InputDecoration(
        prefixText: '${SettingsService.instance.currencySymbol} ',
        prefixStyle: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: amountColor ?? cs.primary,
        ),
        contentPadding: const EdgeInsets.all(16.0),
        filled: true,
        fillColor: cs.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12.0),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12.0),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12.0),
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
      ),
    );
  }
}
