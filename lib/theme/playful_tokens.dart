import 'package:flutter/material.dart';

/// SpendX Playful Design System Tokens.
///
/// Combines modern energetic fintech aesthetics (Duolingo / Revolut / Cash App)
/// with tactile physical feedback, spring physics, and cohesive 8pt-grid geometry.
class PlayfulTokens {
  PlayfulTokens._();

  // ── 1. Cohesive Geometry & Radii ─────────────────────────────
  /// Replaces fragmented radii (2, 3, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 28)
  /// with 5 intentional squircle tiers.
  static const double radiusXs = 8.0;   // Badges, chips, tags
  static const double radiusSm = 12.0;  // Input fields, segment pills
  static const double radiusMd = 18.0;  // Standard cards, sheets, dialogs
  static const double radiusLg = 26.0;  // Hero containers, bottom nav bar
  static const double radiusPill = 999.0; // Interactive buttons, action pills

  // ── 2. Spacing (Strict 4pt / 8pt Rhythmic Grid) ──────────────
  static const double space4 = 4.0;
  static const double space8 = 8.0;
  static const double space12 = 12.0;
  static const double space16 = 16.0;
  static const double space20 = 20.0;
  static const double space24 = 24.0;
  static const double space32 = 32.0;
  static const double space40 = 40.0;
  static const double space48 = 48.0;

  // ── 3. Tactile 3D Depths (Physical Button Lips) ──────────────
  static const double buttonLipHeight = 4.0;
  static const double buttonLipHeightPressed = 1.0;
  static const double buttonDepression = 3.0; // translateY on press

  // ── 4. Spring Physics & Motion Curves ────────────────────────
  /// Bouncy deceleration with intentional 6% overshoot for "squishy" tactile feel.
  static const Curve curveBounce = Curves.easeOutBack;

  /// High-energy elastic spring for celebrations and badge pop-ins.
  static const Curve curveElastic = Curves.elasticOut;

  /// Ultra-responsive press contraction.
  static const Curve curveSquish = Curves.easeInOutCubic;

  /// Smooth deceleration for layout shifts.
  static const Curve curveSmooth = Curves.easeOutCubic;

  // ── 5. Motion Durations ──────────────────────────────────────
  /// Instant tactile response on finger press.
  static const Duration durationPress = Duration(milliseconds: 90);

  /// Spring bounce recovery when finger releases.
  static const Duration durationBounce = Duration(milliseconds: 220);

  /// Pop-in entrance for new cards and list elements.
  static const Duration durationPopIn = Duration(milliseconds: 320);

  /// Page transition with fluid depth.
  static const Duration durationPage = Duration(milliseconds: 300);

  /// Confetti and celebration particles.
  static const Duration durationCelebration = Duration(milliseconds: 800);

  // ── 6. Playful Palette (Vibrant & Energetic) ─────────────────
  static const Color electricViolet = Color(0xFF6558E8);
  static const Color electricVioletLip = Color(0xFF4C3FC7);
  static const Color electricVioletLight = Color(0xFF8175FF);

  static const Color neoMint = Color(0xFF2EC4B6);
  static const Color neoMintLip = Color(0xFF20968B);

  static const Color sunsetCoral = Color(0xFFFF5A5F);
  static const Color sunsetCoralLip = Color(0xFFD63E43);

  static const Color mangoGold = Color(0xFFFFB703);
  static const Color mangoGoldLip = Color(0xFFD49700);

  static const Color cyberCyan = Color(0xFF00BBF9);
  static const Color cyberCyanLip = Color(0xFF0098CC);

  static const Color playfulPurple = Color(0xFF9B5DE5);
  static const Color playfulPurpleLip = Color(0xFF7A43B8);

  // Tactile elevation shadows
  static List<BoxShadow> tactileShadow({
    required Color color,
    double elevation = 4.0,
  }) {
    return [
      BoxShadow(
        color: color.withValues(alpha: 0.35),
        offset: Offset(0, elevation),
        blurRadius: elevation * 2,
        spreadRadius: -1,
      ),
    ];
  }
}
