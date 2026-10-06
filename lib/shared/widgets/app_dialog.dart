import 'package:flutter/material.dart';
import 'glass/spendx_glass_dialog.dart';

class AppDialog extends StatelessWidget {
  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final IconData? icon;
  final Color? iconColor;

  const AppDialog({
    super.key,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.icon,
    this.iconColor,
  });

  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required String message,
    required String primaryLabel,
    required VoidCallback onPrimary,
    String? secondaryLabel,
    VoidCallback? onSecondary,
    IconData? icon,
    Color? iconColor,
  }) {
    return showDialog<T>(
      context: context,
      builder: (context) => AppDialog(
        title: title,
        message: message,
        primaryLabel: primaryLabel,
        onPrimary: onPrimary,
        secondaryLabel: secondaryLabel,
        onSecondary: onSecondary,
        icon: icon,
        iconColor: iconColor,
      ),
    );
  }

  static Future<bool?> showConfirm({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool isDestructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: title,
        message: message,
        primaryLabel: confirmLabel,
        secondaryLabel: cancelLabel,
        icon: isDestructive ? Icons.warning_amber_rounded : Icons.info_outline,
        iconColor: isDestructive
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
        onPrimary: () => Navigator.pop(dialogContext, true),
        onSecondary: () => Navigator.pop(dialogContext, false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SpendXGlassDialog(
      title: title,
      message: message,
      primaryLabel: primaryLabel,
      onPrimary: onPrimary,
      secondaryLabel: secondaryLabel,
      onSecondary: onSecondary,
      icon: icon,
      iconColor: iconColor,
    );
  }
}
