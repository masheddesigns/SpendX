import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';

/// Apple-inspired Liquid Glass Modal Bottom Sheet.
///
/// Implements Section 11 of C15-A-R1:
/// - Floating Glass Material (Material 3 — Floating Glass)
/// - Strong backdrop blur (sigma 28)
/// - Top specular edge highlight across the upper curved rim
/// - Translucent gradient fill; underlying content subtly visible
/// - Tactile drag affordance handle pill
/// - Handles Android back navigation cleanly
class SpendXGlassSheet extends StatelessWidget {
  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  const SpendXGlassSheet({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    String? title,
    Widget? trailing,
    bool isDismissible = true,
    bool enableDrag = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      barrierColor: Colors.black.withValues(alpha: 0.50), // Translucent scrim
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      builder: (ctx) => SpendXGlassSheet(
        title: title,
        trailing: trailing,
        child: builder(ctx),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final topRadius = Radius.circular(AppRadius.xl);

    final sheetGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isDark
          ? const [
              Color(0x801C2436), // ~50%
              Color(0x66101520), // ~40%
            ]
          : const [
              Color(0xB8FFFFFF), // ~72%
              Color(0x8CF1F5F9), // ~55%
            ],
    );

    final borderColor = isDark
        ? const Color(0x38FFFFFF)
        : const Color(0x28000000);

    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: topRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28.0, sigmaY: 28.0),
        child: Container(
          decoration: BoxDecoration(
            gradient: sheetGradient,
            borderRadius: BorderRadius.vertical(top: topRadius),
            border: Border(
              top: BorderSide(color: borderColor, width: 0.75),
              left: BorderSide(color: borderColor, width: 0.5),
              right: BorderSide(color: borderColor, width: 0.5),
            ),
          ),
          child: Stack(
            children: [
              // Top Specular Highlight Gleam
              Positioned(
                top: 0,
                left: 20,
                right: 20,
                height: 1.0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        Colors.white.withValues(alpha: isDark ? 0.45 : 0.70),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),

              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  10,
                  20,
                  bottomInset > 0 ? bottomInset + 16 : 28,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Centered Drag Affordance Pill
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.28)
                              : Colors.black.withValues(alpha: 0.20),
                          borderRadius: BorderRadius.circular(AppRadius.full),
                        ),
                      ),
                    ),
                    if (title != null) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title!,
                              style: AppTextStyles.heading.copyWith(
                                color: isDark
                                    ? AppTheme.darkTextPrimary
                                    : AppTheme.lightTextPrimary,
                              ),
                            ),
                          ),
                          ?trailing,
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    Flexible(child: child),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
