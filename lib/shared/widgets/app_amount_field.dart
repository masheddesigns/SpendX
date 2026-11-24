import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/settings_service.dart';
import '../../theme/app_theme.dart';

class AppAmountField extends StatelessWidget {
  const AppAmountField({
    super.key,
    required this.controller,
    this.focusNode,
    this.amountColor,
    this.onChanged,
    this.validator,
    this.textInputAction,
    this.onFieldSubmitted,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final Color? amountColor;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveColor = amountColor ?? colorScheme.primary;

    return Semantics(
      textField: true,
      label: 'Transaction Amount',
      child: TextFormField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        validator: validator,
        textInputAction: textInputAction,
        onFieldSubmitted: onFieldSubmitted,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
        ],
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
          hintText: '0.00',
          hintStyle: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: -0.5,
            color: effectiveColor.withValues(alpha: 0.35),
          ),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.clear_rounded, size: 20),
                tooltip: 'Clear amount',
                onPressed: () {
                  controller.clear();
                  onChanged?.call('');
                },
              );
            },
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20.0,
            vertical: 16.0,
          ),
          filled: true,
          fillColor: context.fieldFillColor,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16.0),
            borderSide: BorderSide(
              color: context.fieldBorderColor,
              width: 0.75,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16.0),
            borderSide: BorderSide(
              color: context.fieldBorderColor,
              width: 0.75,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16.0),
            borderSide: BorderSide(color: effectiveColor, width: 1.5),
          ),
        ),
      ),
    );
  }
}
