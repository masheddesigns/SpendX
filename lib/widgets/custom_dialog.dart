import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
enum DialogType { success, error, warning, info }

class CustomDialog {
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String message,
    DialogType type = DialogType.info,
    String primaryButtonText = 'OK',
    String? secondaryButtonText,
  }) {
    switch (type) {
      case DialogType.error:
      case DialogType.warning:
        HapticFeedback.heavyImpact();
        break;
      case DialogType.success:
      case DialogType.info:
        HapticFeedback.mediumImpact();
        break;
    }

    Color primaryColor;
    IconData iconData;
    switch (type) {
      case DialogType.error:
        primaryColor = Theme.of(context).colorScheme.error;
        iconData = Icons.error_outline_rounded;
        break;
      case DialogType.success:
        primaryColor = Theme.of(context).colorScheme.primary;
        iconData = Icons.check_circle_outline_rounded;
        break;
      case DialogType.warning:
        primaryColor = Theme.of(context).colorScheme.secondary;
        iconData = Icons.warning_amber_rounded;
        break;
      case DialogType.info:
        primaryColor = Theme.of(context).colorScheme.tertiary;
        iconData = Icons.info_outline_rounded;
        break;
    }

    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: primaryColor.withValues(alpha: 0.3), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withValues(alpha: 0.1),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(iconData, color: primaryColor, size: 40),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    if (secondaryButtonText != null) ...[
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            secondaryButtonText,
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: primaryColor == Theme.of(ctx).colorScheme.error 
                              ? Theme.of(ctx).colorScheme.onError 
                              : (primaryColor == Theme.of(ctx).colorScheme.primary 
                                  ? Theme.of(ctx).colorScheme.onPrimary 
                                  : Colors.white),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          primaryButtonText,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
