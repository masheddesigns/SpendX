import '../services/haptic_service.dart';
import 'package:flutter/material.dart';

class CustomSnackBar {
  /// Show a snackbar. Set [isError] for error (red), [isWarning] for warning (amber),
  /// or leave both false for success (green). Duration for errors is longer (5s).
  static void show(
    BuildContext context, {
    required String message,
    bool isError = false,
    bool isWarning = false,
  }) {
    if (isError) {
      HapticService.instance.critical();
    } else if (isWarning) {
      HapticService.instance.success();
    } else {
      HapticService.instance.tap();
    }

    final Color bgColor = isError
        ? Theme.of(context).colorScheme.error
        : isWarning
            ? Theme.of(context).colorScheme.secondary
            : Theme.of(context).colorScheme.primary;

    final IconData icon = isError
        ? Icons.error_outline_rounded
        : isWarning
            ? Icons.warning_amber_rounded
            : Icons.check_circle_outline_rounded;

    final Duration duration = isError
        ? const Duration(seconds: 5)
        : isWarning
            ? const Duration(seconds: 4)
            : const Duration(seconds: 3);

    final snackBar = SnackBar(
      padding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      duration: duration,
      content: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: bgColor.withValues(alpha: 0.4)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: bgColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: bgColor, size: 18),
            ),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  height: 1.3,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(snackBar);
  }
}
