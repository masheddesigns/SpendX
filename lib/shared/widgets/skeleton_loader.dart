import 'package:flutter/material.dart';
import '../../theme/app_motion.dart';

/// Shimmer sweep skeleton loader.
///
/// Moving gradient sweep instead of simple opacity pulse.
/// Feels more "alive" and premium.
class SkeletonLoader extends StatefulWidget {
  final int itemCount;
  final double itemHeight;
  final EdgeInsets padding;

  const SkeletonLoader({
    super.key,
    this.itemCount = 5,
    this.itemHeight = 72,
    this.padding = const EdgeInsets.all(16),
  });

  const SkeletonLoader.transactions({super.key})
      : itemCount = 6,
        itemHeight = 68,
        padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8);

  const SkeletonLoader.summary({super.key})
      : itemCount = 1,
        itemHeight = 120,
        padding = const EdgeInsets.all(16);

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: AppMotion.ambient,
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final baseColor = cs.surfaceContainer;
    final highlightColor = cs.surfaceContainerHighest;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) => Padding(
        padding: widget.padding,
        child: Column(
          children: List.generate(widget.itemCount, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ShimmerBox(
                animation: _ctrl,
                baseColor: baseColor,
                highlightColor: highlightColor,
                height: widget.itemHeight,
                index: i,
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _ShimmerBox extends StatelessWidget {
  final AnimationController animation;
  final Color baseColor;
  final Color highlightColor;
  final double height;
  final int index;

  const _ShimmerBox({
    required this.animation,
    required this.baseColor,
    required this.highlightColor,
    required this.height,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment(-1.0 + (animation.value * 3), 0),
          end: Alignment(-0.5 + (animation.value * 3), 0),
          colors: [baseColor, highlightColor, baseColor],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Icon placeholder
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: cs.outline.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 90 + (index * 15.0).clamp(0, 60),
                    height: 12,
                    decoration: BoxDecoration(
                      color: cs.outline.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 55 + (index * 8.0).clamp(0, 35),
                    height: 10,
                    decoration: BoxDecoration(
                      color: cs.outline.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 65,
                  height: 13,
                  decoration: BoxDecoration(
                    color: cs.outline.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 36,
                  height: 9,
                  decoration: BoxDecoration(
                    color: cs.outline.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
