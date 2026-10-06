import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'spendx_glass_button.dart';

/// Apple-inspired Liquid Glass Modal Dialog.
///
/// Implements Section 3 of C15-C:
/// - Floating Glass Material with blur (sigma 24)
/// - Translucent fill showing underlying activity subtly
/// - Specular highlight rim across top border
/// - Generous padding, crisp typography, and restrained tactile buttons
/// - Fully Android-native back handling
class SpendXGlassDialog extends StatelessWidget {
  final String title;
  final String? message;
  final Widget? content;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final IconData? icon;
  final Color? iconColor;
  final bool isDestructive;

  const SpendXGlassDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.icon,
    this.iconColor,
    this.isDestructive = false,
  }) : assert(message != null || content != null, 'Either message or content must be provided');

  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String message,
    required String primaryLabel,
    required VoidCallback onPrimary,
    String? secondaryLabel,
    VoidCallback? onSecondary,
    IconData? icon,
    Color? iconColor,
    bool isDestructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogCtx) => SpendXGlassDialog(
        title: title,
        message: message,
        primaryLabel: primaryLabel,
        onPrimary: onPrimary,
        secondaryLabel: secondaryLabel,
        onSecondary: onSecondary,
        icon: icon,
        iconColor: iconColor,
        isDestructive: isDestructive,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(AppRadius.xl);

    final bgGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? const [
              Color(0xD9182336), // ~85%
              Color(0xCC0E1524), // ~80%
            ]
          : const [
              Color(0xF2FFFFFF), // ~95%
              Color(0xD9EEF4FA), // ~85%
            ],
    );

    final borderColor = isDark
        ? const Color(0x38FFFFFF)
        : const Color(0x28000000);

    final effectiveIconColor = iconColor ??
        (isDestructive
            ? AppTheme.semanticExpense
            : AppTheme.primaryBlue);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24.0, sigmaY: 24.0),
          child: Container(
            decoration: BoxDecoration(
              gradient: bgGradient,
              borderRadius: radius,
              border: Border.all(color: borderColor, width: 0.75),
            ),
            child: Stack(
              children: [
                // Top Specular Gleam
                Positioned(
                  top: 0,
                  left: 24,
                  right: 24,
                  height: 1.0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.white.withValues(alpha: isDark ? 0.40 : 0.75),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: effectiveIconColor.withValues(alpha: isDark ? 0.16 : 0.12),
                            border: Border.all(
                              color: effectiveIconColor.withValues(alpha: isDark ? 0.35 : 0.25),
                              width: 0.75,
                            ),
                          ),
                          child: Icon(icon, size: 26, color: effectiveIconColor),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                        ),
                      ),
                      if (message != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          message!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: isDark
                                ? AppTheme.darkTextSecondary
                                : AppTheme.lightTextSecondary,
                          ),
                        ),
                      ],
                      if (content != null) ...[
                        const SizedBox(height: 16),
                        content!,
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          if (secondaryLabel != null) ...[
                            Expanded(
                              child: SpendXGlassButton(
                                variant: SpendXGlassButtonVariant.tonal,
                                onPressed: onSecondary ?? () => Navigator.pop(context, false),
                                child: Text(secondaryLabel!),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: SpendXGlassButton(
                              variant: isDestructive
                                  ? SpendXGlassButtonVariant.danger
                                  : SpendXGlassButtonVariant.primary,
                              onPressed: onPrimary,
                              child: Text(primaryLabel),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
