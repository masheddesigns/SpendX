import 'package:flutter/material.dart';
import '../services/settings_service.dart';

class AppTheme extends ChangeNotifier {
  // --- Fintech Dark (Default) ---
  static const Color financeBg = Color(0xFF0B1020);
  static const Color financeSurface = Color(0xFF111827);
  static const Color financeCard = Color(0xFF1E293B);
  static const Color financePrimary = Color(0xFF22C55E);
  static const Color financeSecondary = Color(0xFF38BDF8);
  static const Color financeTertiary = Color(0xFFA78BFA);
  
  // --- Dark Indigo ---
  static const Color indigoBg = Color(0xFF111122);
  static const Color indigoSurface = Color(0xFF1A1A2E);
  static const Color indigoCard = Color(0xFF242444);
  static const Color indigoPrimary = Color(0xFF818CF8); // Indigo
  static const Color indigoSecondary = Color(0xFFC084FC); // Purple
  static const Color indigoTertiary = Color(0xFFFB7185); // Rose

  // --- Dark Graphite ---
  static const Color graphiteBg = Color(0xFF171717);
  static const Color graphiteSurface = Color(0xFF262626);
  static const Color graphiteCard = Color(0xFF333333);
  static const Color graphitePrimary = Color(0xFF10B981); // Emerald
  static const Color graphiteSecondary = Color(0xFF64748B); // Slate
  static const Color graphiteTertiary = Color(0xFFF59E0B); // Amber

  static const Color financeWarning = Color(0xFFF59E0B);
  static const Color financeError = Color(0xFFEF4444);
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);
  static const Color financeBorder = Color(0xFF334155);

  static const List<Map<String, dynamic>> availableThemes = [
    {'id': 'fintech_dark', 'name': 'Fintech Dark', 'color': Color(0xFF22C55E)},
    {'id': 'dark_indigo', 'name': 'Dark Indigo', 'color': Color(0xFF818CF8)},
    {'id': 'dark_graphite', 'name': 'Dark Graphite', 'color': Color(0xFF10B981)},
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
  static Color get primaryColor => _getColorForType('primary');
  static Color get secondaryColor => _getColorForType('secondary');
  static Color get tertiaryColor => _getColorForType('tertiary');
  static Color get accentColor => primaryColor;
  static Color get errorColor => financeError;
  static Color get successColor => financePrimary;
  static Color get warningColor => financeWarning;
  static Color get infoColor => financeSecondary;
  
  static Color get chartIncome => financePrimary;
  static Color get chartExpense => financeError;

  static LinearGradient get primaryGradient => LinearGradient(colors: [primaryColor, primaryColor.withValues(alpha: 0.7)]);
  static LinearGradient get secondaryGradient => LinearGradient(colors: [secondaryColor, secondaryColor.withValues(alpha: 0.7)]);

  static Color tinted(Color color) => color.withValues(alpha: 0.15);

  static Color _getColorForType(String type) {
    final variant = SettingsService.instance.themeVariant;
    switch (variant) {
      case 'dark_indigo':
        if (type == 'primary') return indigoPrimary;
        if (type == 'secondary') return indigoSecondary;
        return indigoTertiary;
      case 'dark_graphite':
        if (type == 'primary') return graphitePrimary;
        if (type == 'secondary') return graphiteSecondary;
        return graphiteTertiary;
      default:
        if (type == 'primary') return financePrimary;
        if (type == 'secondary') return financeSecondary;
        return financeTertiary;
    }
  }

  // --- Instance Members for ProfileHub selection ---
  Color get seedColor {
    final variant = SettingsService.instance.themeVariant;
    return availableThemes.firstWhere((t) => t['id'] == variant, orElse: () => availableThemes.first)['color'];
  }

  void setPrimaryColor(Color color) {
    final theme = availableThemes.firstWhere((t) => (t['color'] as Color).value == color.value, orElse: () => {});
    if (theme.isNotEmpty) {
      SettingsService.instance.setThemeVariant(theme['id'] as String);
    }
  }

  String get currentThemeName {
    final variant = SettingsService.instance.themeVariant;
    return availableThemes.firstWhere((t) => t['id'] == variant, orElse: () => availableThemes.first)['name'];
  }

  ThemeData getTheme() {
    final variant = SettingsService.instance.themeVariant;
    
    Color bg, surface, card, primary, secondary, tertiary;

    switch (variant) {
      case 'dark_indigo':
        bg = indigoBg;
        surface = indigoSurface;
        card = indigoCard;
        primary = indigoPrimary;
        secondary = indigoSecondary;
        tertiary = indigoTertiary;
        break;
      case 'dark_graphite':
        bg = graphiteBg;
        surface = graphiteSurface;
        card = graphiteCard;
        primary = graphitePrimary;
        secondary = graphiteSecondary;
        tertiary = graphiteTertiary;
        break;
      default:
        bg = financeBg;
        surface = financeSurface;
        card = financeCard;
        primary = financePrimary;
        secondary = financeSecondary;
        tertiary = financeTertiary;
    }

    final colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: primary,
      onPrimary: Colors.white,
      secondary: secondary,
      onSecondary: Colors.white,
      tertiary: tertiary,
      onTertiary: Colors.white,
      error: financeError,
      onError: Colors.white,
      surface: surface,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: financeBorder.withValues(alpha: 0.5),
      outlineVariant: textMuted,
      surfaceContainer: card,
      surfaceContainerHigh: card.withValues(alpha: 0.8),
      inverseSurface: textPrimary,
      onInverseSurface: surface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: _buildTextTheme(colorScheme),
      scaffoldBackgroundColor: bg,
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: financeBorder.withValues(alpha: 0.2), width: 0.5),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primary,
        unselectedItemColor: textMuted,
        elevation: 8,
        type: BottomNavigationBarType.fixed,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          elevation: 0,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w500,
        ),
        iconTheme: IconThemeData(color: primary),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: financeBorder)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: financeBorder)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: primary, width: 1.5)),
      ),
    );
  }

  TextTheme _buildTextTheme(ColorScheme cs) {
    return TextTheme(
      headlineLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
        letterSpacing: -0.5,
      ),
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: cs.onSurface,
        letterSpacing: -0.2,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: cs.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: cs.onSurface,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: cs.onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: cs.onSurfaceVariant,
      ),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: cs.onSurfaceVariant,
        letterSpacing: 0.2,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w300,
        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
        letterSpacing: 0.5,
      ),
    );
  }

  ThemeData get currentTheme => getTheme();
}
