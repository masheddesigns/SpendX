import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
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
  static const double xxl = 24.0;
  static const double card = 16.0;
  static const double button = 12.0;
  static const double full = 999.0;
}

class AppShadows {
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0A18274B),
      blurRadius: 16,
      offset: Offset(0, 4),
      spreadRadius: -2,
    ),
    BoxShadow(
      color: Color(0x0518274B),
      blurRadius: 6,
      offset: Offset(0, 1),
    ),
  ];

  static const List<BoxShadow> floating = [
    BoxShadow(
      color: Color(0x1218274B),
      blurRadius: 24,
      offset: Offset(0, 8),
      spreadRadius: -4,
    ),
    BoxShadow(
      color: Color(0x0818274B),
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ];

  static const List<BoxShadow> glow = [
    BoxShadow(
      color: Color(0x256558E8),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  static const List<BoxShadow> darkCard = [
    BoxShadow(
      color: Color(0x40000000),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];
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
  // --- Modern Fintech Surface Tokens ---
  static const Color darkCanvas = Color(0xFF0D0F17);
  static const Color darkSurface = Color(0xFF171A26);
  static const Color darkElevated = Color(0xFF1F2333);
  static const Color darkBorder = Color(0xFF262B3D);
  static const Color darkCard = darkSurface;
  static const Color darkBg = darkCanvas;

  static const Color lightCanvas = Color(0xFFFAF7F2);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightElevated = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFEBE6DC);
  static const Color lightCard = lightSurface;
  static const Color lightBg = lightCanvas;

  // Signature SpendX Brand Color (Duolingo / Revolut modern violet-indigo)
  static const Color primaryBlue = Color(0xFF6558E8);
  static const Color primaryBlueMuted = Color(0xFF4C3FC7);

  // Financial Semantics (LOCKED - Finch/Monzo clear and reassuring)
  static const Color semanticIncome = Color(0xFF35B779);
  static const Color semanticExpense = Color(0xFFE76D76);
  static const Color semanticTransfer = Color(0xFF55B8C5);
  static const Color semanticWarning = Color(0xFFF3AD4E);
  static const Color semanticShortfall = Color(0xFFE76D76);

  static const Color successGreen = semanticIncome;
  static const Color warningAmber = semanticWarning;
  static const Color dangerRed = semanticExpense;

  static const Color darkTextPrimary = Color(0xFFF5F7FC);
  static const Color darkTextSecondary = Color(0xFF9AA1B5);
  static const Color darkTextMuted = Color(0xFF656C82);

  static const Color lightTextPrimary = Color(0xFF202432);
  static const Color lightTextSecondary = Color(0xFF6B7280);
  static const Color lightTextMuted = Color(0xFF9AA1B5);

  // Liquid Glass Specific Surface Tokens
  static const Color glassDarkSurface = Color(0xCC171A26);
  static const Color glassDarkElevated = Color(0xD91F2333);
  static const Color glassDarkNav = Color(0xF2121520);
  static const Color glassDarkBorder = Color(0x2EFFFFFF);
  static const Color glassDarkBorderSubtle = Color(0x1AFFFFFF);

  static const Color glassLightSurface = Color(0xF5FFFFFF);
  static const Color glassLightElevated = Color(0xFAFFFFFF);
  static const Color glassLightNav = Color(0xF5FFFFFF);
  static const Color glassLightBorder = Color(0xFFEDF0F7);
  static const Color glassLightBorderSubtle = Color(0xFFF0F3F9);

  static const double glassBlur = 16.0;
  static const double glassNavBlur = 20.0;
  static const double glassControlBlur = 12.0;

  static const List<Map<String, dynamic>> availableThemes = [
    {'id': 'spendx_modern', 'name': 'SpendX Modern', 'color': Color(0xFF6558E8)},
    {'id': 'liquid_glass_dark', 'name': 'Liquid Glass Dark', 'color': Color(0xFF6558E8)},
    {'id': 'premium_dark', 'name': 'Premium Dark', 'color': Color(0xFF6558E8)},
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

  // --- Theme Selection Helpers ---
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
        fontFamily: GoogleFonts.inter().fontFamily,
        colorScheme: colorScheme,
        textTheme: _buildStaticTextTheme(colorScheme),
        scaffoldBackgroundColor: bg,
        dividerTheme: const DividerThemeData(
          color: lightBorder,
          thickness: 1,
          space: 1,
        ),
        cardTheme: CardThemeData(
          color: card,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: const BorderSide(color: lightBorder, width: 1),
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
            textStyle: AppTextStyles.button,
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: primary,
            minimumSize: const Size.fromHeight(48),
            side: const BorderSide(color: lightBorder, width: 1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
            textStyle: AppTextStyles.button,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: primary,
            textStyle: AppTextStyles.button,
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          titleTextStyle: AppTextStyles.heading.copyWith(color: lightTextPrimary),
          iconTheme: const IconThemeData(color: lightTextPrimary),
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: lightSurface,
          selectedItemColor: primary,
          unselectedItemColor: lightTextMuted,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
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
      fontFamily: GoogleFonts.inter().fontFamily,
      colorScheme: colorScheme,
      textTheme: _buildStaticTextTheme(colorScheme),
      scaffoldBackgroundColor: bg,
      dividerTheme: const DividerThemeData(
        color: darkBorder,
        thickness: 1,
        space: 1,
      ),
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
          textStyle: AppTextStyles.button,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: darkBorder, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          textStyle: AppTextStyles.button,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: AppTextStyles.button,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: AppTextStyles.heading.copyWith(color: darkTextPrimary),
        iconTheme: const IconThemeData(color: primaryBlue),
      ),
    );
  }

  static TextTheme _buildStaticTextTheme(ColorScheme cs) {
    final base = GoogleFonts.interTextTheme();
    return base.copyWith(
      displayLarge: AppTextStyles.displayBalance.copyWith(color: cs.onSurface),
      headlineLarge: AppTextStyles.heading.copyWith(color: cs.onSurface),
      headlineMedium: AppTextStyles.heading.copyWith(color: cs.onSurface),
      titleLarge: AppTextStyles.subheading.copyWith(color: cs.onSurface),
      titleMedium: AppTextStyles.subheading.copyWith(color: cs.onSurface),
      titleSmall: AppTextStyles.sectionHeading.copyWith(color: cs.onSurface),
      bodyLarge: AppTextStyles.body.copyWith(color: cs.onSurface),
      bodyMedium: AppTextStyles.bodyMedium.copyWith(color: cs.onSurfaceVariant),
      labelLarge: AppTextStyles.button.copyWith(color: cs.onSurface),
      labelMedium: AppTextStyles.caption.copyWith(color: cs.onSurfaceVariant),
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
