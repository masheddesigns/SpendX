import 'package:flutter/material.dart';
import '../../../theme/playful_tokens.dart';

/// Bouncy Playful Page Route Transition.
///
/// Features:
/// - Entering page scales from 0.93 to 1.0 with playful overshoot ([Curves.easeOutBack]).
/// - Fade + subtle upward slide for high physical depth.
/// - Respects reduced motion preferences.
class PlayfulPageRoute<T> extends PageRouteBuilder<T> {
  final Widget Function(BuildContext) builder;

  PlayfulPageRoute({
    required this.builder,
    super.settings,
  }) : super(
          pageBuilder: (context, animation, secondaryAnimation) => builder(context),
          transitionDuration: PlayfulTokens.durationPage,
          reverseTransitionDuration: const Duration(milliseconds: 220),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (MediaQuery.disableAnimationsOf(context)) {
              return child;
            }

            final curved = CurvedAnimation(
              parent: animation,
              curve: PlayfulTokens.curveBounce,
              reverseCurve: Curves.easeInCubic,
            );

            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              ),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.93, end: 1.0).animate(curved),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.0, 0.04),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                ),
              ),
            );
          },
        );
}
