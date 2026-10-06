import 'dart:ui';
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

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final snackBar = SnackBar(
      padding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      duration: duration,
      content: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xD41A2333)
                  : const Color(0xEEFFFFFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.black.withValues(alpha: 0.12),
                width: 0.75,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 36,
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
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
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
        ),
      ),
    );

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(snackBar);
  }
}
