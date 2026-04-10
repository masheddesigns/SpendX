import 'package:flutter/material.dart';
import '../../theme/app_motion.dart';

/// Premium page transition: fade + slide + subtle scale.
///
/// Creates depth — feels like layers, not flat screens.
/// Uses AppMotion tokens for consistent timing.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  final WidgetBuilder builder;

  AppPageRoute({required this.builder})
      : super(
          transitionDuration: AppMotion.normal,
          reverseTransitionDuration: const Duration(milliseconds: 180),
          pageBuilder: (context, _, _) => builder(context),
          transitionsBuilder: (_, animation, _, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppMotion.curveEnter,
            );

            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.03, 0),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                ),
              ),
            );
          },
        );
}
