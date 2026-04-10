import '../services/haptic_service.dart';
import 'package:flutter/material.dart';

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
        HapticService.instance.critical();
        break;
      case DialogType.success:
      case DialogType.info:
        HapticService.instance.success();
        break;
    }

    IconData iconData;
    switch (type) {
      case DialogType.error:
        iconData = Icons.error_outline_rounded;
        break;
      case DialogType.success:
        iconData = Icons.check_circle_outline_rounded;
        break;
      case DialogType.warning:
        iconData = Icons.warning_amber_rounded;
        break;
      case DialogType.info:
        iconData = Icons.info_outline_rounded;
        break;
    }

    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          icon: Icon(iconData),
          title: Text(title),
          content: Text(message),
          actions: [
            if (secondaryButtonText != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(secondaryButtonText),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(primaryButtonText),
            ),
          ],
        );
      },
    );
  }
}
