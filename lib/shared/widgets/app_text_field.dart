import 'package:flutter/material.dart';

class AppTextField extends StatelessWidget {
  final String label;
  final String? hint;
  final String? errorText;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextEditingController? controller;
  final dynamic prefixIcon;
  final Widget? prefix;
  final Widget? suffixIcon;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final int? maxLines;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool readOnly;
  final VoidCallback? onTap;

  const AppTextField({
    super.key,
    String? label,
    String? labelText,
    String? hint,
    String? hintText,
    this.errorText,
    this.obscureText = false,
    this.keyboardType,
    this.controller,
    this.prefixIcon,
    this.prefix,
    this.suffixIcon,
    this.suffix,
    this.onChanged,
    this.validator,
    this.maxLines = 1,
    this.autofocus = false,
    this.focusNode,
    this.readOnly = false,
    this.onTap,
  }) : label = label ?? labelText ?? '',
       hint = hint ?? hintText;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final fillColor = isDark
        ? const Color(0x1AFFFFFF) // ~10% white
        : const Color(0x66FFFFFF); // ~40% white

    final borderColor = isDark
        ? const Color(0x2EFFFFFF) // ~18% white
        : const Color(0x1F000000); // ~12% black

    final focusColor = isDark
        ? const Color(0xFF38BDF8) // AppTheme.accentCyan
        : const Color(0xFF0284C7); // AppTheme.darkAccentCyan

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              label,
              style: textTheme.labelLarge?.copyWith(
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
              ),
            ),
          ),
        TextFormField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          focusNode: focusNode,
          onChanged: onChanged,
          validator: validator,
          maxLines: maxLines,
          autofocus: autofocus,
          readOnly: readOnly,
          onTap: onTap,
          style: textTheme.bodyLarge?.copyWith(
            color: isDark ? Colors.white : const Color(0xFF0F172A),
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorText,
            prefixIcon: prefix ??
                (prefixIcon is IconData
                ? Icon(
                    prefixIcon as IconData,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  )
                : prefixIcon as Widget?),
            suffixIcon: suffix ?? suffixIcon,
            hintStyle: textTheme.bodyLarge?.copyWith(
              color: isDark
                  ? const Color(0x7094A3B8)
                  : const Color(0x8064748B),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 15.0),
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
              borderSide: BorderSide(color: focusColor, width: 1.25),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide(color: cs.error, width: 1.25),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide(color: cs.error, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
