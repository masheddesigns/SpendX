import 'package:flutter/widgets.dart';

/// Unified motion timing system.
///
/// All animations in the app must use these tokens.
/// Creates muscle-memory consistency across interactions.
class AppMotion {
  AppMotion._();

  // ── Durations ──────────────────────────────────────────
  /// Tap feedback, micro-interactions (scale, opacity).
  static const fast = Duration(milliseconds: 120);

  /// Page transitions, card reveals, section changes.
  static const normal = Duration(milliseconds: 220);

  /// Full-screen transitions, modal entries.
  static const slow = Duration(milliseconds: 320);

  /// Skeleton shimmer, ambient animations.
  static const ambient = Duration(milliseconds: 1200);

  // ── Curves ─────────────────────────────────────────────
  /// Standard deceleration — use for most animations.
  static const curve = Curves.easeOut;

  /// Enter screen — slight overshoot for "landing" feel.
  static const curveEnter = Curves.easeOutCubic;

  /// Exit screen — accelerate out.
  static const curveExit = Curves.easeIn;

  /// Bounce-free spring — for tap scale recovery.
  static const curveSpring = Curves.easeOutQuart;

  // ── Reduced-motion helpers ──────────────────────────────
  /// Returns [Duration.zero] when the user has enabled reduced motion,
  /// otherwise returns the requested [base] duration.
  static Duration duration(BuildContext context, [Duration base = normal]) {
    return MediaQuery.disableAnimationsOf(context) ? Duration.zero : base;
  }
}

/// Context extensions for ergonomic motion duration and reduced-motion checks.
extension AppMotionContext on BuildContext {
  /// Whether the user has requested reduced motion.
  bool get reduceMotion => MediaQuery.disableAnimationsOf(this);

  /// Resolves an animation duration respecting reduced motion settings.
  Duration motionDuration([Duration base = AppMotion.normal]) =>
      reduceMotion ? Duration.zero : base;
}
