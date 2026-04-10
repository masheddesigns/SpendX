import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_motion.dart';

/// Subtle press-down feedback for tappable elements.
///
/// Combines: scale (0.97) + opacity (0.85) + optional haptic.
/// Duration uses AppMotion.fast (120ms).
class AppTapScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool haptic;

  const AppTapScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.haptic = false,
  });

  @override
  State<AppTapScale> createState() => _AppTapScaleState();
}

class _AppTapScaleState extends State<AppTapScale> {
  bool _pressed = false;

  void _onTapDown(TapDownDetails _) {
    if (widget.onTap != null || widget.onLongPress != null) {
      setState(() => _pressed = true);
    }
  }

  void _onTapUp(TapUpDetails _) => setState(() => _pressed = false);
  void _onTapCancel() => setState(() => _pressed = false);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: () {
        if (widget.haptic) HapticFeedback.lightImpact();
        widget.onTap?.call();
      },
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.curveSpring,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.85 : 1.0,
          duration: AppMotion.fast,
          child: widget.child,
        ),
      ),
    );
  }
}
