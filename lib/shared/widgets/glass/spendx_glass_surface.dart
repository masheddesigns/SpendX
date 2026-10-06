import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';

/// Established Liquid Glass Material Levels per C15-A-R1 specification.
enum SpendXGlassLevel {
  /// Material 1 — Base Glass: Low-opacity translucent surface for grouped list containers and secondary sections.
  base,

  /// Material 2 — Elevated Glass: Stronger opacity, deeper blur, edge lighting, floating shadow. Used for Safe-to-Spend Hero.
  elevated,

  /// Material 3 — Floating Glass: Highest visual separation, deep drop shadow, top specular sheen. Used for bottom nav and modal sheets.
  floating,

  /// Material 4 — Interactive Glass: Compact, dynamic responsive material for buttons, chips, and segmented controls.
  interactive,
}

/// Foundational Apple-inspired Liquid Glass surface.
///
/// Combines:
/// 1. Environmental background interaction
/// 2. Multi-tier Gaussian backdrop blur
/// 3. Translucent gradient tint (top-down subtle falloff)
/// 4. Specular edge highlight (top rim lighting)
/// 5. Directional hairline perimeter border
/// 6. Floating elevation shadow cast onto the background
class SpendXGlassSurface extends StatelessWidget {
  final Widget child;
  final SpendXGlassLevel level;
  final double? blur;
  final BorderRadius? borderRadius;
  final Color? color;
  final Gradient? gradient;
  final Border? border;
  final List<BoxShadow>? boxShadow;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final bool showSpecularHighlight;

  const SpendXGlassSurface({
    super.key,
    required this.child,
    this.level = SpendXGlassLevel.base,
    this.blur,
    this.borderRadius,
    this.color,
    this.gradient,
    this.border,
    this.boxShadow,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.showSpecularHighlight = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = borderRadius ?? BorderRadius.circular(AppRadius.card);

    // ── Tier Properties ─────────────────────────────────────
    final double defaultBlur;
    final Gradient defaultGradient;
    final Color defaultBorderColor;
    final List<BoxShadow>? defaultShadow;
    final double specularOpacity;

    switch (level) {
      case SpendXGlassLevel.base:
        defaultBlur = 16.0;
        specularOpacity = isDark ? 0.18 : 0.35;
        defaultGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0x33171D2A), // ~20%
                  Color(0x1F0F131D), // ~12%
                ]
              : const [
                  Color(0x66FFFFFF), // ~40%
                  Color(0x38F1F5F9), // ~22%
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0x1FFFFFFF) // 12% white
            : const Color(0x24000000); // 14% black
        defaultShadow = null;
        break;

      case SpendXGlassLevel.elevated:
        defaultBlur = 24.0;
        specularOpacity = isDark ? 0.32 : 0.55;
        defaultGradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [
                  Color(0x4D1E2638), // ~30%
                  Color(0x2B101522), // ~17%
                ]
              : const [
                  Color(0x8AFFFFFF), // ~54%
                  Color(0x52F8FAFC), // ~32%
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0x30FFFFFF) // 19% white
            : const Color(0x2E000000); // 18% black
        defaultShadow = [
          BoxShadow(
            color: isDark
                ? const Color(0x55000000)
                : const Color(0x140F172A),
            blurRadius: 28,
            spreadRadius: -4,
            offset: const Offset(0, 10),
          ),
        ];
        break;

      case SpendXGlassLevel.floating:
        defaultBlur = 28.0;
        specularOpacity = isDark ? 0.45 : 0.70;
        defaultGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0x661A2232), // ~40%
                  Color(0x470D121B), // ~28%
                ]
              : const [
                  Color(0x9EFFFFFF), // ~62%
                  Color(0x6BF1F5F9), // ~42%
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0x3DFFFFFF) // 24% white
            : const Color(0x33000000); // 20% black
        defaultShadow = [
          BoxShadow(
            color: isDark
                ? const Color(0x70000000)
                : const Color(0x1F0F172A),
            blurRadius: 32,
            spreadRadius: -2,
            offset: const Offset(0, 12),
          ),
        ];
        break;

      case SpendXGlassLevel.interactive:
        defaultBlur = 14.0;
        specularOpacity = isDark ? 0.25 : 0.45;
        defaultGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0x3820293A), // ~22%
                  Color(0x24121722), // ~14%
                ]
              : const [
                  Color(0x70FFFFFF), // ~44%
                  Color(0x40F1F5F9), // ~25%
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0x29FFFFFF) // 16% white
            : const Color(0x26000000); // 15% black
        defaultShadow = [
          BoxShadow(
            color: isDark
                ? const Color(0x30000000)
                : const Color(0x0F0F172A),
            blurRadius: 10,
            spreadRadius: -2,
            offset: const Offset(0, 4),
          ),
        ];
        break;
    }

    final effectiveBlur = blur ?? defaultBlur;
    final effectiveShadow = boxShadow ?? defaultShadow;

    // Body decoration
    final BoxDecoration bodyDecoration;
    if (gradient != null) {
      bodyDecoration = BoxDecoration(
        gradient: gradient,
        borderRadius: radius,
        border: border ?? Border.all(color: defaultBorderColor, width: 0.5),
      );
    } else if (color != null) {
      bodyDecoration = BoxDecoration(
        color: color,
        borderRadius: radius,
        border: border ?? Border.all(color: defaultBorderColor, width: 0.5),
      );
    } else {
      bodyDecoration = BoxDecoration(
        gradient: defaultGradient,
        borderRadius: radius,
        border: border ?? Border.all(color: defaultBorderColor, width: 0.5),
      );
    }

    Widget content = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: bodyDecoration,
      child: child,
    );

    // Specular top highlight line
    if (showSpecularHighlight) {
      content = Stack(
        clipBehavior: Clip.antiAlias,
        children: [
          content,
          Positioned(
            top: 0,
            left: 14,
            right: 14,
            height: 1.0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.white.withValues(alpha: specularOpacity),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
        ],
      );
    }

    final frostedBody = ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: effectiveBlur, sigmaY: effectiveBlur),
        child: content,
      ),
    );

    // Outer container for floating drop shadow (not clipped by ClipRRect)
    if (effectiveShadow != null && effectiveShadow.isNotEmpty) {
      return Container(
        margin: margin,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: effectiveShadow,
        ),
        child: frostedBody,
      );
    }

    if (margin != null) {
      return Padding(padding: margin!, child: frostedBody);
    }
    return frostedBody;
  }
}

/// Reusable Glass Card for list groupings and content sections.
class SpendXGlassCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final SpendXGlassLevel level;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final Color? color;
  final Gradient? gradient;
  final Border? border;
  final double? blur;
  final List<BoxShadow>? boxShadow;

  const SpendXGlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.level = SpendXGlassLevel.base,
    this.padding = const EdgeInsets.all(AppSpacing.standard),
    this.margin,
    this.borderRadius,
    this.color,
    this.gradient,
    this.border,
    this.blur,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    final surface = SpendXGlassSurface(
      level: level,
      padding: padding,
      margin: margin,
      borderRadius: borderRadius,
      color: color,
      gradient: gradient,
      border: border,
      blur: blur,
      boxShadow: boxShadow,
      child: child,
    );

    if (onTap == null) return surface;

    final radius = borderRadius ?? BorderRadius.circular(AppRadius.card);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: surface,
        ),
      ),
    );
  }
}
