import 'package:flutter/material.dart';
import 'common/primary_action_button.dart';

enum AppButtonVariant { primary, secondary, outline, text }

class AppButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData? icon;
  final bool isLoading;
  final double? width;

  const AppButton({
    super.key,
    required this.text,
    this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.isLoading = false,
    this.width,
  });

  const AppButton.primary({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.width,
  }) : variant = AppButtonVariant.primary;

  const AppButton.secondary({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.width,
  }) : variant = AppButtonVariant.secondary;

  const AppButton.outline({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.width,
  }) : variant = AppButtonVariant.outline;

  const AppButton.textVariant({
    super.key,
    required this.text,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.width,
  }) : variant = AppButtonVariant.text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Color backgroundColor;
    Color foregroundColor;
    BorderSide? border;

    switch (variant) {
      case AppButtonVariant.primary:
        // Solid primary color – always visible
        backgroundColor = cs.primary;
        foregroundColor = cs.onPrimary;
        break;
      case AppButtonVariant.secondary:
        // Primary container (lighter shade of primary) – visible on dark backgrounds
        backgroundColor = cs.primaryContainer;
        foregroundColor = cs.onPrimaryContainer;
        break;
      case AppButtonVariant.outline:
        backgroundColor = Colors.transparent;
        foregroundColor = cs.primary;
        border = BorderSide(
          color: cs.primary.withValues(alpha: 0.7),
          width: 1.5,
        );
        break;
      case AppButtonVariant.text:
        backgroundColor = Colors.transparent;
        foregroundColor = cs.primary;
        break;
    }

    Widget content = isLoading
        ? SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              Text(text),
            ],
          );

    if (variant == AppButtonVariant.text) {
      return TextButton(
        onPressed: isLoading ? null : onPressed,
        style: TextButton.styleFrom(
          foregroundColor: foregroundColor,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: content,
      );
    }

    return SizedBox(
      width: width,
      child: variant == AppButtonVariant.primary
          ? PrimaryActionButton(
              label: text,
              onPressed: onPressed,
              icon: icon,
              isLoading: isLoading,
              expand: width != null || width == double.infinity,
            )
          : ElevatedButton(
              onPressed: isLoading ? null : onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: backgroundColor,
                foregroundColor: foregroundColor,
                elevation: 0,
                side: border,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: content,
            ),
    );
  }
}
