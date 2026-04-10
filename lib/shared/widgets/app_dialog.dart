import 'package:flutter/material.dart';
import 'primary_button.dart';

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
    final cs = Theme.of(context).colorScheme;

    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: (iconColor ?? cs.primary).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: iconColor ?? cs.primary),
              ),
              const SizedBox(height: 16.0),
            ],
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onSurface),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12.0),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24.0),
            Row(
              children: [
                if (secondaryLabel != null)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12.0),
                      child: SecondaryButton(
                        label: secondaryLabel!,
                        onPressed: onSecondary ?? () => Navigator.pop(context),
                      ),
                    ),
                  ),
                Expanded(
                  child: PrimaryButton(
                    label: primaryLabel,
                    onPressed: onPrimary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
