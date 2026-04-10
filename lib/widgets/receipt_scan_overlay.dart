import 'dart:ui';

import 'package:flutter/material.dart';

class ReceiptScanOverlay extends StatefulWidget {
  const ReceiptScanOverlay({
    super.key,
    this.title = 'Scanning receipt...',
    this.subtitle = 'Analyzing receipt data',
  });

  final String title;
  final String subtitle;

  static Future<T?> show<T>(
    BuildContext context, {
    String title = 'Scanning receipt...',
    String subtitle = 'Analyzing receipt data',
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: false,
      barrierLabel: title,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) =>
          ReceiptScanOverlay(title: title, subtitle: subtitle),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<ReceiptScanOverlay> createState() => _ReceiptScanOverlayState();
}

class _ReceiptScanOverlayState extends State<ReceiptScanOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colorScheme.surface.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.25),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 28,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 92,
                      height: 92,
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, _) {
                          final scanOffset = (_controller.value * 42).clamp(
                            0.0,
                            42.0,
                          );
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              Transform.rotate(
                                angle: _controller.value * 6.28,
                                child: CustomPaint(
                                  size: const Size.square(92),
                                  painter: _ArcPainter(
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                              Container(
                                width: 52,
                                height: 62,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: colorScheme.surfaceContainerHighest,
                                  border: Border.all(
                                    color: colorScheme.outline.withValues(
                                      alpha: 0.35,
                                    ),
                                  ),
                                ),
                                child: Stack(
                                  children: [
                                    Positioned(
                                      left: 10,
                                      right: 10,
                                      top: 14,
                                      child: Container(
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: colorScheme.primary.withValues(
                                            alpha: 0.22,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 10,
                                      right: 16,
                                      top: 24,
                                      child: Container(
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: colorScheme.primary.withValues(
                                            alpha: 0.14,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 6,
                                      right: 6,
                                      top: 10 + scanOffset,
                                      child: Container(
                                        height: 3,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Colors.transparent,
                                              colorScheme.secondary,
                                              Colors.transparent,
                                            ],
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: colorScheme.secondary
                                                  .withValues(alpha: 0.35),
                                              blurRadius: 10,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Transform.scale(
                                scale: 0.95 + (_controller.value * 0.08),
                                child: Icon(
                                  Icons.receipt_long_rounded,
                                  color: colorScheme.primary.withValues(
                                    alpha: 0.2,
                                  ),
                                  size: 44,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.2),
          color,
          color.withValues(alpha: 0),
        ],
      ).createShader(Offset.zero & size);

    canvas.drawArc(
      Rect.fromLTWH(6, 6, size.width - 12, size.height - 12),
      -1.4,
      4.4,
      false,
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
