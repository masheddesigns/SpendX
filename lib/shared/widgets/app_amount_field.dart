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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor = amountColor ?? (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7));

    final fillColor = isDark
        ? const Color(0x1AFFFFFF) // ~10% white
        : const Color(0x66FFFFFF); // ~40% white

    final borderColor = isDark
        ? const Color(0x2EFFFFFF)
        : const Color(0x1F000000);

    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
        letterSpacing: -0.5,
        color: effectiveColor,
      ),
      decoration: InputDecoration(
        prefixText: '${SettingsService.instance.currencySymbol} ',
        prefixStyle: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: -0.5,
          color: effectiveColor,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
        filled: true,
        fillColor: fillColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16.0),
          borderSide: BorderSide(color: borderColor, width: 0.75),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16.0),
          borderSide: BorderSide(color: borderColor, width: 0.75),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16.0),
          borderSide: BorderSide(color: effectiveColor, width: 1.5),
        ),
      ),
    );
  }
}
