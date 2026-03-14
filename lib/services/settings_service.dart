import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const String _onboardingKey = 'onboarding_complete';
  static const String _currencyKey = 'primary_currency';
  static const String _themeModeKey = 'theme_mode';
  static const String _enableVehiclesKey = 'enable_vehicles';
  static const String _enableLendingKey = 'enable_lending';
  static const String _enableCreditCardsKey = 'enable_credit_cards';
  static const String _periodicReminderKey = 'periodic_reminder_freq';
  static const String _hasGuestSessionKey = 'has_guest_session';
  static const String _autoBackupIntervalKey = 'auto_backup_interval';
  static const String _lastSyncTimeKey = 'last_sync_time';
  static const String _devModeKey = 'developer_mode_enabled';
  static const String _netWorthLastUpdatedKey = 'net_worth_last_updated';
  static const String _lastCloudProviderKey = 'last_cloud_provider';
  static const String _reminderSoundKey = 'reminder_sound';
  static const String _enableAiChatKey = 'enable_ai_chat';
  static const String _enableAiReportKey = 'enable_ai_report';
  static const String _lastBackupTimeKey = 'last_backup_time';
  static const String _themeVariantKey = 'theme_variant';

  // Private constructor
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  late SharedPreferences _prefs;

  /// Call this during app initialization
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // --- Net Worth Tracker ---
  DateTime? get netWorthLastUpdated {
    final timestamp = _prefs.getInt(_netWorthLastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  Future<void> setNetWorthLastUpdated(DateTime time) async {
    await _prefs.setInt(_netWorthLastUpdatedKey, time.millisecondsSinceEpoch);
    notifyListeners();
  }

  // --- Onboarding ---

  bool get isOnboardingComplete {
    return _prefs.getBool(_onboardingKey) ?? false;
  }

  Future<void> setOnboardingComplete(bool value) async {
    await _prefs.setBool(_onboardingKey, value);
  }

  // --- Features & Settings ---

  String get primaryCurrency {
    return _prefs.getString(_currencyKey) ?? 'USD';
  }

  Future<void> setPrimaryCurrency(String currency) async {
    await _prefs.setString(_currencyKey, currency);
    notifyListeners();
  }

  bool get isDarkMode {
    return _prefs.getBool(_themeModeKey) ?? true; // Always default to dark for fintech theme
  }

  Future<void> setDarkMode(bool isDark) async {
    // Keeping this for potential future light mode refinement, 
    // but the app theme is now optimized for dark.
    await _prefs.setBool(_themeModeKey, isDark);
    notifyListeners();
  }

  // --- Theme Variant ---

  String get themeVariant {
    return _prefs.getString(_themeVariantKey) ?? 'fintech_dark';
  }

  Future<void> setThemeVariant(String variant) async {
    await _prefs.setString(_themeVariantKey, variant);
    notifyListeners();
  }

  // --- Feature Toggles ---

  bool get enableVehicles {
    return _prefs.getBool(_enableVehiclesKey) ?? true; // Default enabled
  }

  Future<void> setEnableVehicles(bool val) async {
    await _prefs.setBool(_enableVehiclesKey, val);
    notifyListeners();
  }

  bool get enableLending {
    return _prefs.getBool(_enableLendingKey) ?? true;
  }

  Future<void> setEnableLending(bool val) async {
    await _prefs.setBool(_enableLendingKey, val);
    notifyListeners();
  }

  bool get enableCreditCards {
    return _prefs.getBool(_enableCreditCardsKey) ?? true;
  }

  Future<void> setEnableCreditCards(bool val) async {
    await _prefs.setBool(_enableCreditCardsKey, val);
    notifyListeners();
  }

  // --- Periodic Reminders ---
  String get periodicReminderFrequency {
    return _prefs.getString(_periodicReminderKey) ?? 'off';
  }

  Future<void> setPeriodicReminderFrequency(String freq) async {
    await _prefs.setString(_periodicReminderKey, freq);
    notifyListeners();
  }

  // --- Guest Session ---
  bool get hasGuestSession {
    return _prefs.getBool(_hasGuestSessionKey) ?? false;
  }

  Future<void> setHasGuestSession(bool val) async {
    await _prefs.setBool(_hasGuestSessionKey, val);
  }

  // --- Auto Backup ---
  /// Interval values: 'off', 'realtime', '30min', '1hr', 'daily'
  String get autoBackupInterval {
    return _prefs.getString(_autoBackupIntervalKey) ?? 'off';
  }

  Future<void> setAutoBackupInterval(String interval) async {
    await _prefs.setString(_autoBackupIntervalKey, interval);
    notifyListeners();
  }

  /// Backward-compat: true if interval is not 'off'
  bool get autoBackupEnabled => autoBackupInterval != 'off';

  Future<void> setAutoBackupEnabled(bool val) async {
    // Legacy – map to realtime when enabling, off when disabling
    await setAutoBackupInterval(val ? 'realtime' : 'off');
  }

  String get autoBackupFrequency {
    return autoBackupInterval; // alias for backward compat
  }

  Future<void> setAutoBackupFrequency(String freq) async {
    await setAutoBackupInterval(freq);
  }

  // --- Sync Meta ---
  DateTime? get lastSyncTime {
    final timestamp = _prefs.getInt(_lastSyncTimeKey);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  Future<void> setLastSyncTime(DateTime time) async {
    await _prefs.setInt(_lastSyncTimeKey, time.millisecondsSinceEpoch);
    notifyListeners();
  }

  // --- Backup Meta ---
  DateTime? get lastBackupTime {
    final timestamp = _prefs.getInt(_lastBackupTimeKey);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  Future<void> setLastBackupTime(DateTime time) async {
    await _prefs.setInt(_lastBackupTimeKey, time.millisecondsSinceEpoch);
    notifyListeners();
  }

  // --- Developer Mode ---
  bool get isDeveloperModeEnabled {
    return _prefs.getBool(_devModeKey) ?? false;
  }

  Future<void> setDeveloperMode(bool val) async {
    await _prefs.setBool(_devModeKey, val);
    notifyListeners();
  }

  // --- Cloud Provider ---
  String? get lastCloudProvider {
    return _prefs.getString(_lastCloudProviderKey);
  }

  Future<void> setLastCloudProvider(String? provider) async {
    if (provider == null) {
      await _prefs.remove(_lastCloudProviderKey);
    } else {
      await _prefs.setString(_lastCloudProviderKey, provider);
    }
    notifyListeners();
  }

  // --- Notification Sounds ---
  String get reminderSound {
    return _prefs.getString(_reminderSoundKey) ?? 'default';
  }

  Future<void> setReminderSound(String sound) async {
    await _prefs.setString(_reminderSoundKey, sound);
    notifyListeners();
  }

  // --- AI Features ---
  bool get enableAiChat {
    return _prefs.getBool(_enableAiChatKey) ?? true;
  }

  Future<void> setEnableAiChat(bool val) async {
    await _prefs.setBool(_enableAiChatKey, val);
    notifyListeners();
  }

  bool get enableAiReport {
    return _prefs.getBool(_enableAiReportKey) ?? true;
  }

  Future<void> setEnableAiReport(bool val) async {
    await _prefs.setBool(_enableAiReportKey, val);
    notifyListeners();
  }
}
