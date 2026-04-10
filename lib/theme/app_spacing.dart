import 'package:flutter/material.dart';

class AppSpacing {
  static const double micro = 8.0;
  static const double tight = 12.0;
  static const double standard = 16.0;
  static const double section = 24.0;
  static const double major = 32.0;

  // Shorthands for existing code compatibility if needed, but primarily use the above
  static const double xs = 8.0;
  static const double s = 12.0;
  static const double sm = s;
  static const double m = 16.0;
  static const double md = m;
  static const double l = 24.0;
  static const double lg = l;
  static const double xl = 32.0;
  static const double xxl = 48.0;

  static const EdgeInsets screenPadding = EdgeInsets.all(standard);
  static const EdgeInsets screenPaddingHorizontal = EdgeInsets.symmetric(
    horizontal: standard,
  );
  static const EdgeInsets screenPaddingVertical = EdgeInsets.symmetric(
    vertical: standard,
  );

  static const SizedBox sectionSpacer = SizedBox(height: section);
  static const SizedBox itemSpacer = SizedBox(height: standard);
  static const SizedBox microSpacer = SizedBox(height: micro);

  // ── Consistent card dimensions (use everywhere) ─────────────
  /// Internal padding for all list cards (accounts, transactions, loans, etc.)
  static const EdgeInsets cardPadding =
      EdgeInsets.symmetric(horizontal: 14, vertical: 10);
  /// Gap between cards in a list
  static const double cardGap = 6.0;
  /// Horizontal padding for card lists on screen
  static const double listHorizontalPadding = 12.0;
  /// Section header gap above a card list
  static const double sectionHeaderGap = 8.0;
  /// Gap between section groups
  static const double sectionGap = 16.0;
}
