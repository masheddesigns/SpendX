import 'package:flutter/material.dart';
import '../../../theme/playful_tokens.dart';

/// Staggered spring entrance pop-in for cards, tiles, and list items.
///
/// Features:
/// - Smooth scale-up from 0.88 with spring overshoot ([PlayfulTokens.curveBounce]).
/// - Vertical translation from +16px to 0px.
/// - Configurable [delay] for delightful cascade / wave effects.
class PlayfulPopIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;

  const PlayfulPopIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = PlayfulTokens.durationPopIn,
  });

  @override
  State<PlayfulPopIn> createState() => _PlayfulPopInState();
}

class _PlayfulPopInState extends State<PlayfulPopIn>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _scaleAnim = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: PlayfulTokens.curveBounce),
    );

    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );

    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _ctrl, curve: PlayfulTokens.curveBounce),
    );

    if (widget.delay == Duration.zero) {
      _ctrl.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _ctrl.forward();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }

    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: ScaleTransition(
          scale: _scaleAnim,
          child: widget.child,
        ),
      ),
    );
  }
}
