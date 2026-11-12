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
    bool useRootNavigator = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      useSafeArea: true,
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
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom > 0
        ? mediaQuery.viewInsets.bottom
        : mediaQuery.padding.bottom;
    final topRadius = Radius.circular(AppRadius.xl);

    final sheetGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isDark
          ? const [
              Color(0xCC1C2436), // ~80% solid glass
              Color(0xE6101520), // ~90%
            ]
          : const [
              Color(0xF0FFFFFF), // ~94%
              Color(0xE6F1F5F9), // ~90%
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
          width: double.infinity,
          constraints: BoxConstraints(
            maxHeight: mediaQuery.size.height * 0.85,
          ),
          decoration: BoxDecoration(
            gradient: sheetGradient,
            borderRadius: BorderRadius.vertical(top: topRadius),
            border: Border(
              top: BorderSide(color: borderColor, width: 0.75),
              left: BorderSide(color: borderColor, width: 0.5),
              right: BorderSide(color: borderColor, width: 0.5),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Specular Highlight Gleam
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  height: 1.0,
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

                // Centered Drag Affordance Pill
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.28)
                            : Colors.black.withValues(alpha: 0.20),
                        borderRadius: BorderRadius.circular(AppRadius.full),
                      ),
                    ),
                  ),
                ),

                if (title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 10),
                    child: Row(
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
                        IconButton(
                          icon: Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                          ),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),

                Flexible(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      20,
                      0,
                      20,
                      bottomInset > 0 ? bottomInset + 16 : 28,
                    ),
                    child: child,
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
