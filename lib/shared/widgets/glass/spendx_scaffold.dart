import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';

/// SpendX Application Scaffold with ambient environmental depth background.
///
/// Implements Section 3 of C15-A-R1:
/// - Deep graphite/black base
/// - Large, extremely soft ambient light fields (Hero emerald aura, Sapphire mid-body, bottom horizon)
/// - Controlled gradients with enough visual variation behind translucent surfaces
/// - [extendBody: true] so content flows naturally behind the floating glass nav
class SpendXScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;
  final bool extendBody;
  final bool extendBodyBehindAppBar;
  final Color? backgroundColor;

  const SpendXScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.extendBody = true,
    this.extendBodyBehindAppBar = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final baseColor = backgroundColor ??
        (isDark ? AppTheme.darkCanvas : AppTheme.lightCanvas);

    final overlayStyle = isDark
        ? const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.light,
          )
        : const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.dark,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        extendBody: extendBody,
        extendBodyBehindAppBar: extendBodyBehindAppBar,
        backgroundColor: baseColor,
        appBar: appBar,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Environmental ambient background painter
            RepaintBoundary(
              child: CustomPaint(
                painter: SpendXEnvironmentPainter(isDark: isDark),
                size: Size.infinite,
              ),
            ),
            // Content layer
            body,
          ],
        ),
        floatingActionButton: floatingActionButton,
        floatingActionButtonLocation: floatingActionButtonLocation,
        bottomNavigationBar: bottomNavigationBar,
      ),
    );
  }
}

/// Custom GPU painter that renders soft ambient light fields for Liquid Glass refraction.
class SpendXEnvironmentPainter extends CustomPainter {
  final bool isDark;

  const SpendXEnvironmentPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 1. Base canvas fill: Warm, mindful linen/buttermilk in Light, rich obsidian in Dark
    final baseColor = isDark ? const Color(0xFF0C0E14) : const Color(0xFFFAF7F2);
    canvas.drawRect(rect, Paint()..color = baseColor);

    if (isDark) {
      // 2. Ambient Field 1: Hero Deep Forest Emerald
      final center1 = Offset(size.width * 0.25, size.height * 0.20);
      final radius1 = size.width * 0.95;
      final paint1 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x350F3D32),
            Color(0x180A201A),
            Color(0x000C0E14),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center1, radius: radius1));
      canvas.drawCircle(center1, radius1, paint1);

      // 3. Ambient Field 2: Mid-Right Mystic Violet
      final center2 = Offset(size.width * 0.85, size.height * 0.45);
      final radius2 = size.width * 0.85;
      final paint2 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x284338CA),
            Color(0x12251D5E),
            Color(0x000C0E14),
          ],
          stops: const [0.0, 0.50, 1.0],
        ).createShader(Rect.fromCircle(center: center2, radius: radius2));
      canvas.drawCircle(center2, radius2, paint2);

      // 4. Ambient Field 3: Bottom Navigation Horizon
      final center3 = Offset(size.width * 0.50, size.height * 0.94);
      final radius3 = size.width * 0.70;
      final paint3 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x221E1B4B),
            Color(0x000C0E14),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: center3, radius: radius3));
      canvas.drawCircle(center3, radius3, paint3);
    } else {
      // Light Mode Environmental Fields: Warm, organic, sunrise & meadow fields
      // Field 1: Soft sunlit amber aura (top left)
      final center1 = Offset(size.width * 0.15, size.height * 0.12);
      final radius1 = size.width * 0.85;
      final paint1 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x28FDE68A), // warm morning honey glow
            Color(0x14F59E0B),
            Color(0x00FAF7F2),
          ],
          stops: const [0.0, 0.50, 1.0],
        ).createShader(Rect.fromCircle(center: center1, radius: radius1));
      canvas.drawCircle(center1, radius1, paint1);

      // Field 2: Soft sky/periwinkle breath (top right)
      final center2 = Offset(size.width * 0.90, size.height * 0.22);
      final radius2 = size.width * 0.75;
      final paint2 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x18818CF8), // calming periwinkle
            Color(0x086366F1),
            Color(0x00FAF7F2),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center2, radius: radius2));
      canvas.drawCircle(center2, radius2, paint2);

      // Field 3: Gentle meadow sage hint (mid left)
      final center3 = Offset(size.width * 0.10, size.height * 0.55);
      final radius3 = size.width * 0.70;
      final paint3 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x1A34D399), // revitalizing sage mint
            Color(0x00FAF7F2),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: center3, radius: radius3));
      canvas.drawCircle(center3, radius3, paint3);

      // Field 4: Warm baked apricot horizon (bottom right)
      final center4 = Offset(size.width * 0.85, size.height * 0.85);
      final radius4 = size.width * 0.70;
      final paint4 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x14FB923C), // soft apricot warmth
            Color(0x00FAF7F2),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: center4, radius: radius4));
      canvas.drawCircle(center4, radius4, paint4);
    }
  }

  @override
  bool shouldRepaint(covariant SpendXEnvironmentPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}
