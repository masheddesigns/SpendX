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
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: amountColor ?? Theme.of(context).colorScheme.primary,
      ),
      decoration: InputDecoration(
        prefixText: '${SettingsService.instance.currencySymbol} ',
        border: OutlineInputBorder(),
      ),
    );
  }
}
