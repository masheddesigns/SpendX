import 'package:flutter/material.dart';
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

    return Scaffold(
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

    // 1. Base canvas fill
    final baseColor = isDark ? const Color(0xFF07090E) : const Color(0xFFF3F5FA);
    canvas.drawRect(rect, Paint()..color = baseColor);

    if (isDark) {
      // 2. Ambient Field 1: Hero Financial Emerald Aura (behind Safe-to-Spend)
      final center1 = Offset(size.width * 0.25, size.height * 0.22);
      final radius1 = size.width * 0.90;
      final paint1 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x3D0F3D32), // rich emerald breath
            Color(0x1C0A201A),
            Color(0x0007090E),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center1, radius: radius1));
      canvas.drawCircle(center1, radius1, paint1);

      // 3. Ambient Field 2: Mid-Right Sapphire Aura
      final center2 = Offset(size.width * 0.85, size.height * 0.48);
      final radius2 = size.width * 0.80;
      final paint2 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x35192A4B), // deep sapphire breath
            Color(0x140E182A),
            Color(0x0007090E),
          ],
          stops: const [0.0, 0.50, 1.0],
        ).createShader(Rect.fromCircle(center: center2, radius: radius2));
      canvas.drawCircle(center2, radius2, paint2);

      // 4. Ambient Field 3: Bottom Navigation Horizon Luminescence
      final center3 = Offset(size.width * 0.50, size.height * 0.94);
      final radius3 = size.width * 0.70;
      final paint3 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0x2E1C283F), // soft midnight glow
            Color(0x0007090E),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: center3, radius: radius3));
      canvas.drawCircle(center3, radius3, paint3);
    } else {
      // Light Mode Environmental Fields
      final center1 = Offset(size.width * 0.25, size.height * 0.22);
      final radius1 = size.width * 0.90;
      final paint1 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0xFFD4E9E1), // soft sage
            Color(0xFFE2ECF6),
            Color(0x00F3F5FA),
          ],
          stops: const [0.0, 0.60, 1.0],
        ).createShader(Rect.fromCircle(center: center1, radius: radius1));
      canvas.drawCircle(center1, radius1, paint1);

      final center2 = Offset(size.width * 0.85, size.height * 0.48);
      final radius2 = size.width * 0.80;
      final paint2 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0xFFD9E5F7), // soft periwinkle
            Color(0x00F3F5FA),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: center2, radius: radius2));
      canvas.drawCircle(center2, radius2, paint2);

      final center3 = Offset(size.width * 0.50, size.height * 0.94);
      final radius3 = size.width * 0.70;
      final paint3 = Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0xFFDFE8F4),
            Color(0x00F3F5FA),
          ],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: center3, radius: radius3));
      canvas.drawCircle(center3, radius3, paint3);
    }
  }

  @override
  bool shouldRepaint(covariant SpendXEnvironmentPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}
