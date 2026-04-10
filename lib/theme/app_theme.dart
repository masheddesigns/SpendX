import 'package:flutter/material.dart';
import '../services/settings_service.dart';

export 'app_spacing.dart';

class AppRadius {
  static const double xs = 6.0;
  static const double button = 12.0;
  static const double card = 16.0;
  static const double s = 8.0;
  static const double small = s;
  static const double m = 12.0;
  static const double medium = m;
  static const double l = 16.0;
  static const double large = l;
  static const double xl = 24.0;
  static const double full = 999.0;
}

class AppTextStyles {
  static const TextStyle heading = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.2,
  );

  static const TextStyle subheading = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.normal,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );

  // Compatibility aliases
  static const TextStyle headingLarge = heading;
  static const TextStyle titleLarge = subheading;
  static const TextStyle titleMedium = subheading;
  static const TextStyle titleSmall = subheading;
  static const TextStyle bodyLarge = body;
  static const TextStyle bodyMedium = body;
  static const TextStyle bodySmall = body;
  static const TextStyle labelLarge = caption;
  static const TextStyle labelMedium = caption;
  static const TextStyle labelSmall = caption;
  static const TextStyle headlineSmall = heading;
  static const TextStyle headlineLarge = heading;
}

class AppColors {
  static const Color primary = AppTheme.primaryBlue;
  static const Color success = AppTheme.successGreen;
  static const Color warning = AppTheme.warningAmber;
  static const Color danger = AppTheme.dangerRed;
  static const Color primaryText = AppTheme.darkTextPrimary;
  static const Color secondaryText = AppTheme.darkTextSecondary;
  static const Color mutedText = AppTheme.darkTextMuted;
}

/// Controlled dark theme for full-screen immersive experiences.
/// Only allowed in: Wrapped, Salary dashboard, cinematic modals.
/// NOT for: forms, lists, cards, settings, transactions.
class CinematicTheme {
  CinematicTheme._();
  static const Color bg = Color(0xFF0A0A0A);
  static const Color surface = Color(0xFF121212);
  static const Color surfaceElevated = Color(0xFF1E1E1E);
  static const Color border = Color(0x1FFFFFFF);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0x99FFFFFF); // 60%
  static const Color textMuted = Color(0x66FFFFFF); // 40%
}

class AppTheme extends ChangeNotifier {
  // --- Production Premium System ---
  static const Color darkBg = Color(0xFF0D0F14);
  static const Color darkSurface = Color(0xFF151821);
  static const Color darkCard = Color(0xFF1B1F2A);
  static const Color darkBorder = Color(0xFF262B38);

  static const Color lightBg = Color(0xFFF7F9FC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE5E7EB);

  static const Color primaryBlue = Color(0xFF4DA3FF);
  static const Color successGreen = Color(0xFF22C55E);
  static const Color warningAmber = Color(0xFFF59E0B);
  static const Color dangerRed = Color(0xFFEF4444);

  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFFA1A7B3);
  static const Color darkTextMuted = Color(0xFF6B7280);

  static const Color lightTextPrimary = Color(0xFF111827);
  static const Color lightTextSecondary = Color(0xFF4B5563);
  static const Color lightTextMuted = Color(0xFF9CA3AF);

  static const List<Map<String, dynamic>> availableThemes = [
    {'id': 'premium_dark', 'name': 'Premium Dark', 'color': Color(0xFF4DA3FF)},
  ];

  AppTheme() {
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  // --- Static Getters for Global Use ---
  static Color get primaryColor => primaryBlue;
  static Color get errorColor => dangerRed;
  static Color get successColor => successGreen;
  static Color get warningColor => warningAmber;
  static Color get infoColor => primaryBlue;

  static Color get chartIncome => successGreen;
  static Color get chartExpense => dangerRed;

  static LinearGradient get primaryGradient =>
      LinearGradient(colors: [primaryColor, primaryColor.withValues(alpha: 0.7)]);
  static LinearGradient get secondaryGradient =>
      LinearGradient(colors: [primaryBlue, primaryBlue.withValues(alpha: 0.7)]);

  static Color tinted(Color color) => color.withValues(alpha: 0.15);

  // --- Instance Members for ProfileHub selection ---
  static Color get seedColor {
    final variant = SettingsService.instance.themeVariant;
    return availableThemes.firstWhere(
      (t) => t['id'] == variant,
      orElse: () => availableThemes.first,
    )['color'];
  }

  static void setPrimaryColor(Color color) {
    final theme = availableThemes.firstWhere(
      (t) => (t['color'] as Color).toARGB32() == color.toARGB32(),
      orElse: () => {},
    );
    if (theme.isNotEmpty) {
      SettingsService.instance.setThemeVariant(theme['id'] as String);
    }
  }

  // Instance versions for Consumer usage
  Color get instanceSeedColor => seedColor;
  void instanceSetPrimaryColor(Color color) => setPrimaryColor(color);

  String get currentThemeName {
    final variant = SettingsService.instance.themeVariant;
    return availableThemes.firstWhere(
      (t) => t['id'] == variant,
      orElse: () => availableThemes.first,
    )['name'];
  }

  static ThemeData get lightTheme => _getTheme('light');
  static ThemeData get darkTheme => _getTheme('dark');

  static ThemeData _getTheme(String mode) {
    return _staticGetTheme(mode: mode);
  }

  static ThemeData _staticGetTheme({String mode = 'dark'}) {

    Color bg, surface, card, primary;
    final bool isLight = mode == 'light';

    if (isLight) {
      bg = lightBg;
      surface = lightSurface;
      card = lightCard;
      primary = primaryBlue;

      final colorScheme = ColorScheme(
        brightness: Brightness.light,
        primary: primary,
        onPrimary: Colors.white,
        secondary: successGreen,
        onSecondary: Colors.white,
        error: dangerRed,
        onError: Colors.white,
        surface: surface,
        onSurface: lightTextPrimary,
        onSurfaceVariant: lightTextSecondary,
        outline: lightBorder,
        outlineVariant: lightTextMuted,
        surfaceContainer: lightCard,
      );

      return ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        textTheme: _buildStaticTextTheme(colorScheme),
        scaffoldBackgroundColor: bg,
        cardTheme: CardThemeData(
          color: card,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: BorderSide(color: lightBorder, width: 1),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
            textStyle: AppTextStyles.subheading,
            elevation: 0,
          ),
        ),
      );
    }

    bg = darkBg;
    surface = darkSurface;
    card = darkCard;
    primary = primaryBlue;

    final colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: primary,
      onPrimary: Colors.white,
      secondary: successGreen,
      onSecondary: Colors.white,
      error: dangerRed,
      onError: Colors.white,
      surface: surface,
      onSurface: darkTextPrimary,
      onSurfaceVariant: darkTextSecondary,
      outline: darkBorder,
      outlineVariant: darkTextMuted,
      surfaceContainer: darkCard,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: _buildStaticTextTheme(colorScheme),
      scaffoldBackgroundColor: bg,
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: const BorderSide(color: darkBorder, width: 1),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: darkSurface,
        selectedItemColor: primary,
        unselectedItemColor: darkTextMuted,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          textStyle: AppTextStyles.subheading,
          elevation: 0,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        titleTextStyle: AppTextStyles.heading.copyWith(color: darkTextPrimary),
        iconTheme: const IconThemeData(color: primaryBlue),
      ),
    );
  }

  static TextTheme _buildStaticTextTheme(ColorScheme cs) {
    return TextTheme(
      headlineLarge: AppTextStyles.heading.copyWith(color: cs.onSurface),
      headlineMedium: AppTextStyles.heading.copyWith(color: cs.onSurface),
      titleLarge: AppTextStyles.subheading.copyWith(color: cs.onSurface),
      titleMedium: AppTextStyles.subheading.copyWith(color: cs.onSurface),
      bodyLarge: AppTextStyles.body.copyWith(color: cs.onSurface),
      bodyMedium: AppTextStyles.body.copyWith(color: cs.onSurfaceVariant),
      labelLarge: AppTextStyles.caption.copyWith(color: cs.onSurfaceVariant),
      labelSmall: AppTextStyles.caption.copyWith(
        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
      ),
    );
  }

  ThemeData getTheme() => SettingsService.instance.themeMode == ThemeMode.light
      ? lightTheme
      : darkTheme;

  ThemeData get currentTheme => getTheme();
}
