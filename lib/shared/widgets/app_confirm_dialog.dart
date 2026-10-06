import 'package:flutter/material.dart';
import 'glass/spendx_glass_dialog.dart';

class AppConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool isDangerous;
  final VoidCallback onConfirm;

  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel = 'Confirm',
    this.cancelLabel = 'Cancel',
    this.isDangerous = false,
    required this.onConfirm,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    bool isDangerous = false,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (context) => AppConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        isDangerous: isDangerous,
        onConfirm: () => Navigator.of(context).pop(true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SpendXGlassDialog(
      title: title,
      message: message,
      primaryLabel: confirmLabel,
      onPrimary: onConfirm,
      secondaryLabel: cancelLabel,
      onSecondary: () => Navigator.of(context).pop(false),
      isDestructive: isDangerous,
      icon: isDangerous ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
    );
  }
}
