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
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              label,
              style: textTheme.labelLarge?.copyWith(
                color: cs.onSurfaceVariant,
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
          style: textTheme.bodyLarge?.copyWith(color: cs.onSurface),
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorText,
            prefixIcon: prefix ??
                (prefixIcon is IconData
                ? Icon(prefixIcon as IconData)
                : prefixIcon as Widget?),
            suffixIcon: suffix ?? suffixIcon,
            hintStyle: textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
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
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12.0),
              borderSide: BorderSide(color: cs.error, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
