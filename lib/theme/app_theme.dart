import 'package:flutter/material.dart';
import '../services/settings_service.dart';

export 'app_spacing.dart';

class AppRadius {
  static const double xs = 4.0;
  static const double s = 8.0;
  static const double small = s;
  static const double sm = s;
  static const double m = 12.0;
  static const double medium = m;
  static const double md = m;
  static const double l = 16.0;
  static const double large = l;
  static const double lg = l;
  static const double xl = 20.0;
  static const double card = 14.0;
  static const double button = 10.0;
  static const double full = 999.0;
}

class AppTextStyles {
  static const TextStyle displayBalance = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle largeAmount = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle heading = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
  );

  static const TextStyle subheading = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static const TextStyle sectionHeading = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.0,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.0,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
  );

  static const TextStyle navigation = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );

  static const TextStyle button = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );

  static const TextStyle numericData = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  // Compatibility aliases
  static const TextStyle headingLarge = displayBalance;
  static const TextStyle titleLarge = heading;
  static const TextStyle titleMedium = subheading;
  static const TextStyle titleSmall = sectionHeading;
  static const TextStyle bodyLarge = body;
  static const TextStyle bodySmall = bodyMedium;
  static const TextStyle labelLarge = button;
  static const TextStyle labelMedium = caption;
  static const TextStyle labelSmall = caption;
  static const TextStyle headlineSmall = heading;
  static const TextStyle headlineLarge = displayBalance;
}

class AppColors {
  static const Color primary = AppTheme.primaryBlue;
  static const Color success = AppTheme.semanticIncome;
  static const Color warning = AppTheme.semanticWarning;
  static const Color danger = AppTheme.semanticExpense;
  static const Color transfer = AppTheme.semanticTransfer;
  static const Color shortfall = AppTheme.semanticShortfall;
  static const Color primaryText = AppTheme.darkTextPrimary;
  static const Color secondaryText = AppTheme.darkTextSecondary;
  static const Color mutedText = AppTheme.darkTextMuted;
}

/// Controlled dark theme for full-screen immersive experiences.
class CinematicTheme {
  CinematicTheme._();
  static const Color bg = Color(0xFF0A0C10);
  static const Color surface = Color(0xFF12151D);
  static const Color surfaceElevated = Color(0xFF191D28);
  static const Color border = Color(0xFF1E2330);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0x99FFFFFF); // 60%
  static const Color textMuted = Color(0x66FFFFFF); // 40%
}

class AppTheme extends ChangeNotifier {
  // --- Production Liquid Glass Tokens ---
  static const Color darkCanvas = Color(0xFF0A0C10);
  static const Color darkSurface = Color(0xFF12151D);
  static const Color darkElevated = Color(0xFF191D28);
  static const Color darkBorder = Color(0xFF1E2330);
  static const Color darkCard = darkSurface;
  static const Color darkBg = darkCanvas;

  static const Color lightCanvas = Color(0xFFF1F5F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightElevated = Color(0xFFF8FAFC);
  static const Color lightBorder = Color(0xFFE2E8F0);
  static const Color lightCard = lightSurface;
  static const Color lightBg = lightCanvas;

  static const Color primaryBlue = Color(0xFF3B82F6);
  static const Color primaryBlueMuted = Color(0xFF1D3A6B);

  // Financial Semantics (LOCKED)
  static const Color semanticIncome = Color(0xFF10B981);
  static const Color semanticExpense = Color(0xFFF43F5E);
  static const Color semanticTransfer = Color(0xFF64748B);
  static const Color semanticWarning = Color(0xFFF59E0B);
  static const Color semanticShortfall = Color(0xFFE11D48);

  static const Color successGreen = semanticIncome;
  static const Color warningAmber = semanticWarning;
  static const Color dangerRed = semanticExpense;

  static const Color darkTextPrimary = Color(0xFFF8FAFC);
  static const Color darkTextSecondary = Color(0xFF94A3B8);
  static const Color darkTextMuted = Color(0xFF64748B);

  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);
  static const Color lightTextMuted = Color(0xFF94A3B8);

  // Liquid Glass Specific Surface Tokens
  static const Color glassDarkSurface = Color(0xCC12151D); // ~80%
  static const Color glassDarkElevated = Color(0xD9191D28); // ~85%
  static const Color glassDarkNav = Color(0xE610131A); // ~90%
  static const Color glassDarkBorder = Color(0x2EFFFFFF); // 18% white highlight
  static const Color glassDarkBorderSubtle = Color(0x1AFFFFFF); // 10% white

  static const Color glassLightSurface = Color(0xD9FFFFFF); // ~85%
  static const Color glassLightElevated = Color(0xEBFFFFFF); // ~92%
  static const Color glassLightNav = Color(0xF2FFFFFF); // ~95%
  static const Color glassLightBorder = Color(0x26000000); // 15% black
  static const Color glassLightBorderSubtle = Color(0x14000000); // 8% black

  static const double glassBlur = 16.0;
  static const double glassNavBlur = 20.0;
  static const double glassControlBlur = 12.0;

  static const List<Map<String, dynamic>> availableThemes = [
    {'id': 'liquid_glass_dark', 'name': 'Liquid Glass Dark', 'color': Color(0xFF3B82F6)},
    {'id': 'premium_dark', 'name': 'Premium Dark', 'color': Color(0xFF3B82F6)},
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
