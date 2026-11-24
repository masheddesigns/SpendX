import 'package:flutter/material.dart';
import '../../../services/sound_effects_service.dart';
import '../../../theme/playful_tokens.dart';

/// Wraps any widget with an elastic spring bounce micro-interaction on tap.
///
/// Features:
/// - Squishes to [scaleDown] (0.94x) on touch-down.
/// - Overshoots with spring elasticity on release.
/// - Plays [SoundEffect.pop] and haptic tick.
/// - Respects system reduced-motion preferences.
class PlayfulBounce extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scaleDown;
  final SoundEffect? sound;
  final bool enableHaptic;
  final String? semanticLabel;

  const PlayfulBounce({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleDown = 0.94,
    this.sound = SoundEffect.pop,
    this.enableHaptic = true,
    this.semanticLabel,
  });

  @override
  State<PlayfulBounce> createState() => _PlayfulBounceState();
}

class _PlayfulBounceState extends State<PlayfulBounce>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: PlayfulTokens.durationPress,
      reverseDuration: PlayfulTokens.durationBounce,
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: widget.scaleDown).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: PlayfulTokens.curveSquish,
        reverseCurve: PlayfulTokens.curveBounce,
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    _isPressed = true;
    _ctrl.forward();
    if (widget.sound != null) {
      SoundEffectsService.instance.play(widget.sound!);
    }
  }

  void _onTapUp(TapUpDetails _) {
    if (!_isPressed) return;
    _isPressed = false;
    _ctrl.reverse();
    widget.onTap?.call();
  }

  void _onTapCancel() {
    if (!_isPressed) return;
    _isPressed = false;
    _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: widget.child,
      );
    }

    return Semantics(
      button: widget.onTap != null,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        onLongPress: widget.onLongPress,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _scaleAnim,
          builder: (context, child) => Transform.scale(
            scale: _scaleAnim.value,
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
