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
        specularOpacity = isDark ? 0.15 : 0.0;
        defaultGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0xFF171A26),
                  Color(0xFF141722),
                ]
              : const [
                  Color(0xFFFFFFFF),
                  Color(0xFFFAFBFE),
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0xFF262B3D)
            : const Color(0xFFEDF0F7);
        defaultShadow = isDark
            ? const [
                BoxShadow(
                  color: Color(0x28000000),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ]
            : AppShadows.card;
        break;

      case SpendXGlassLevel.elevated:
        defaultBlur = 24.0;
        specularOpacity = isDark ? 0.25 : 0.0;
        defaultGradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [
                  Color(0xFF1F2333),
                  Color(0xFF191D2B),
                ]
              : const [
                  Color(0xFFFFFFFF),
                  Color(0xFFF8FAFD),
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0xFF2F354B)
            : const Color(0xFFE2E7F1);
        defaultShadow = isDark
            ? const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 20,
                  offset: Offset(0, 6),
                ),
              ]
            : AppShadows.floating;
        break;

      case SpendXGlassLevel.floating:
        defaultBlur = 28.0;
        specularOpacity = isDark ? 0.35 : 0.0;
        defaultGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0xF0171A26),
                  Color(0xF0121520),
                ]
              : const [
                  Color(0xF8FFFFFF),
                  Color(0xF2F7F9FD),
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0xFF2F354B)
            : const Color(0xFFE2E7F1);
        defaultShadow = isDark
            ? const [
                BoxShadow(
                  color: Color(0x60000000),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ]
            : AppShadows.floating;
        break;

      case SpendXGlassLevel.interactive:
        defaultBlur = 14.0;
        specularOpacity = isDark ? 0.20 : 0.0;
        defaultGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? const [
                  Color(0xFF202538),
                  Color(0xFF1A1E2E),
                ]
              : const [
                  Color(0xFFFFFFFF),
                  Color(0xFFF4F6FC),
                ],
        );
        defaultBorderColor = isDark
            ? const Color(0xFF2D3349)
            : const Color(0xFFE2E7F1);
        defaultShadow = isDark
            ? const [
                BoxShadow(
                  color: Color(0x20000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x0A18274B),
                  blurRadius: 8,
                  offset: Offset(0, 2),
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
    if (effectiveShadow.isNotEmpty) {
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
