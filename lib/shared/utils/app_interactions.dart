import 'package:flutter/material.dart';

class AppAnimations {
  static const Duration buttonTapDuration = Duration(milliseconds: 120);
  static const Duration cardEntryDuration = Duration(milliseconds: 250);

  static Widget buttonScale({
    required Widget child,
    required bool isPressed,
  }) {
    return AnimatedScale(
      scale: isPressed ? 0.97 : 1.0,
      duration: buttonTapDuration,
      curve: Curves.easeInOut,
      child: child,
    );
  }

  static Widget cardEntry({
    required Widget child,
    required int index,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: cardEntryDuration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
