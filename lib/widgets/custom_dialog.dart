import '../services/haptic_service.dart';
import 'package:flutter/material.dart';
import '../shared/widgets/glass/spendx_glass_dialog.dart';
import '../theme/app_theme.dart';

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
    Color? iconColor;
    bool isDestructive = false;

    switch (type) {
      case DialogType.error:
        iconData = Icons.error_outline_rounded;
        iconColor = AppTheme.semanticExpense;
        isDestructive = true;
        break;
      case DialogType.success:
        iconData = Icons.check_circle_outline_rounded;
        iconColor = AppTheme.semanticIncome;
        break;
      case DialogType.warning:
        iconData = Icons.warning_amber_rounded;
        iconColor = AppTheme.semanticWarning;
        isDestructive = true;
        break;
      case DialogType.info:
        iconData = Icons.info_outline_rounded;
        iconColor = null;
        break;
    }

    return SpendXGlassDialog.show(
      context,
      title: title,
      message: message,
      primaryLabel: primaryButtonText,
      onPrimary: () => Navigator.pop(context, true),
      secondaryLabel: secondaryButtonText,
      onSecondary: secondaryButtonText != null
          ? () => Navigator.pop(context, false)
          : null,
      icon: iconData,
      iconColor: iconColor,
      isDestructive: isDestructive,
    );
  }
}
