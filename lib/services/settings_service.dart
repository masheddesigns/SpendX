import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'live_sms_service.dart';

class SettingsService extends ChangeNotifier {
  static const String _onboardingKey = 'onboarding_complete';
  static const String _currencyKey = 'primary_currency';
  static const String _themeModeKey = 'theme_mode';
  static const String _enableLendingKey = 'enable_lending';
  static const String _enableCreditCardsKey = 'enable_credit_cards';
  static const String _enableLoansKey = 'enable_loans';
  static const String _enableLiabilitiesKey = 'enable_liabilities';
  static const String _enableTagsKey = 'enable_tags';
  static const String _periodicReminderKey = 'periodic_reminder_freq';
  static const String _hasGuestSessionKey = 'has_guest_session';
  static const String _autoBackupIntervalKey = 'backup_auto_interval';
  static const String _autoBackupEnabledKey = 'backup_auto_enabled';
  static const String _autoRestoreEnabledKey = 'backup_auto_restore';
  static const String _lastSyncTimeKey = 'last_sync_time';
  static const String _devModeKey = 'developer_mode_enabled';
  static const String _netWorthLastUpdatedKey = 'net_worth_last_updated';
  static const String _lastCloudProviderKey = 'last_cloud_provider';
  static const String _reminderSoundKey = 'reminder_sound';
  static const String _enableAiChatKey = 'enable_ai_chat';
  static const String _geminiApiKeyKey = 'gemini_api_key';
  static const String _enableAiReportKey = 'enable_ai_report';
  static const String _disableIncomeKey = 'settings_disable_income';
  static const String _lastBackupTimeKey = 'last_backup_time';
  static const String _themeVariantKey = 'theme_variant';
  static const String _googleDriveConnectedKey = 'google_drive_connected';
  static const String _googleEmailKey = 'google_email';
  static const String _driveFolderIdKey = 'drive_folder_id';
  static const String _driveConnectedAccountKey = 'drive_connected_account';
  static const String _lastSnapshotDayKey = 'last_snapshot_day';
  static const String _lastManifestEtagKey = 'last_manifest_etag';
  static const String _cachedFileListKey = 'cached_file_list';
  static const String _localSnapshotHashKey = 'local_snapshot_hash';
  static const String _cloudSnapshotVersionKey = 'cloud_snapshot_version';
  static const String _localSnapshotVersionKey = 'local_snapshot_version';
  static const String _textNormalizationCompleteKey =
      'text_normalization_complete_v1';
  static const String _expenseDefaultsCategoryPrefix =
      'expense_defaults_category_';
  static const String _expenseDefaultsAmountsPrefix =
      'expense_defaults_amounts_';
  static const String _expenseDefaultsPaymentIdPrefix =
      'expense_defaults_payment_id_';
  static const String _expenseDefaultsPaymentTypePrefix =
      'expense_defaults_payment_type_';

  // --- External Financial Ingestion Source Keys ---
  static const String _whatsappIngestionEnabledKey =
      'whatsapp_financial_ingestion_enabled';
  static const String _whatsappAllowedSendersKey =
      'whatsapp_financial_allowed_senders';
  static const String _gmailPreviewEnabledKey =
      'gmail_preview_ingestion_enabled';
  static const String _gmailAllowedSendersKey =
      'gmail_financial_allowed_senders';
  static const String _extraIngestionPackagesKey =
      'extra_ingestion_packages';

  static const List<String> defaultWhatsAppSenders = [
    'HDFC Bank',
    'ICICI Bank',
    'SBI',
    'Axis Bank',
    'Kotak Bank',
    'CRED',
    'OneCard',
    'Bank of Baroda',
    'Punjab National Bank',
    'Canara Bank',
    'Union Bank',
    'IDFC FIRST Bank',
    'Federal Bank',
    'IndusInd Bank',
    'Yes Bank',
    'RBL Bank',
    'Standard Chartered',
    'HSBC',
    'Citi',
    'Jupiter',
    'Fi Money',
    'Slice',
    'Paytm',
    'Groww',
    'Zerodha',
  ];

  static const List<String> defaultGmailSenders = [
    'hdfcbank.net',
    'icicibank.com',
    'sbi.co.in',
    'axisbank.com',
    'kotak.com',
    'cred.club',
    'getonecard.app',
    'citi.com',
    'standardchartered.co.in',
    'federalbank.co.in',
    'idfcfirstbank.com',
    'indusind.com',
    'yesbank.in',
    'alerts',
    'statements',
    'sbicard.com',
  ];

  // Private constructor
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  late SharedPreferences _prefs;

  /// Call this during app initialization
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String? getLastExpenseCategoryId({required String type}) {
    return _prefs.getString('$_expenseDefaultsCategoryPrefix$type');
  }

  List<double> getRecentExpenseAmounts({required String type}) {
    final values = _prefs.getStringList('$_expenseDefaultsAmountsPrefix$type');
    if (values == null || values.isEmpty) {
      return const [];
    }
    return values
        .map(double.tryParse)
        .whereType<double>()
        .where((amount) => amount > 0)
        .toList();
  }

  String? getLastExpensePaymentSourceId({required String type}) {
    return _prefs.getString('$_expenseDefaultsPaymentIdPrefix$type');
  }

  String? getLastExpensePaymentSourceType({required String type}) {
    return _prefs.getString('$_expenseDefaultsPaymentTypePrefix$type');
  }

  Future<void> saveExpenseDefaults({
    required String type,
    String? categoryId,
    required double amount,
    String? paymentSourceId,
    String? paymentSourceType,
  }) async {
    final normalizedType = type.trim().toLowerCase();

    if (categoryId != null && categoryId.isNotEmpty) {
      await _prefs.setString(
        '$_expenseDefaultsCategoryPrefix$normalizedType',
        categoryId,
      );
    }

    final existingAmounts = getRecentExpenseAmounts(type: normalizedType);
    final nextAmounts = <double>[
      amount,
      ...existingAmounts.where((value) => value != amount),
    ].take(3).toList();

    await _prefs.setStringList(
      '$_expenseDefaultsAmountsPrefix$normalizedType',
      nextAmounts.map(_serializeDefaultAmount).toList(),
    );

    if (paymentSourceId != null &&
        paymentSourceId.isNotEmpty &&
        paymentSourceType != null &&
        paymentSourceType.isNotEmpty) {
      await _prefs.setString(
        '$_expenseDefaultsPaymentIdPrefix$normalizedType',
        paymentSourceId,
      );
      await _prefs.setString(
        '$_expenseDefaultsPaymentTypePrefix$normalizedType',
        paymentSourceType,
      );
    } else {
      await _prefs.remove('$_expenseDefaultsPaymentIdPrefix$normalizedType');
      await _prefs.remove('$_expenseDefaultsPaymentTypePrefix$normalizedType');
    }
  }

  String _serializeDefaultAmount(double amount) {
    if (amount == amount.roundToDouble()) {
      return amount.toStringAsFixed(0);
    }
    return amount.toStringAsFixed(2);
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
    try {
      return _prefs.getString(_currencyKey) ?? 'INR';
    } catch (_) {
      return 'INR';
    }
  }

  String get currencySymbol {
    final code = primaryCurrency;
    switch (code) {
      case 'INR':
        return '₹';
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      case 'JPY':
        return '¥';
      case 'AUD':
        return 'A\$';
      case 'CAD':
        return 'C\$';
      case 'CHF':
        return 'CHF';
      case 'CNY':
        return '¥';
      case 'SAR':
        return 'SR';
      case 'AED':
        return 'د.إ';
      case 'QAR':
        return 'QR';
      case 'KWD':
        return 'KD';
      case 'OMR':
        return 'RO';
      case 'BHD':
        return 'BD';
      case 'SGD':
        return 'S\$';
      case 'MYR':
        return 'RM';
      case 'THB':
        return '฿';
      case 'IDR':
        return 'Rp';
      case 'PHP':
        return '₱';
      case 'KRW':
        return '₩';
      case 'PKR':
        return '₨';
      case 'BDT':
        return '৳';
      case 'RUB':
        return '₽';
      case 'TRY':
        return '₺';
      case 'SEK':
        return 'kr';
      case 'NOK':
        return 'kr';
      case 'DKK':
        return 'kr';
      case 'BRL':
        return 'R\$';
      case 'MXN':
        return '\$';
      default:
        return code;
    }
  }

  Future<void> setPrimaryCurrency(String currency) async {
    await _prefs.setString(_currencyKey, currency);
    notifyListeners();
  }

  bool get isDarkMode {
    return _prefs.getString(_themeModeKey) == 'dark';
  }

  String get appThemeMode {
    return _prefs.getString(_themeModeKey) ?? 'light';
  }

  ThemeMode get themeMode {
    switch (appThemeMode) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      case 'dark':
      default:
        return ThemeMode.dark;
    }
  }

  Future<void> setDarkMode(bool isDark) async {
    await _prefs.setString(_themeModeKey, isDark ? 'dark' : 'light');
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _prefs.setString(_themeModeKey, value);
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

  bool get enableLoans {
    return _prefs.getBool(_enableLoansKey) ?? true;
  }

  Future<void> setEnableLoans(bool val) async {
    await _prefs.setBool(_enableLoansKey, val);
    notifyListeners();
  }

  bool get enableLiabilities {
    return _prefs.getBool(_enableLiabilitiesKey) ?? true;
  }

  Future<void> setEnableLiabilities(bool val) async {
    await _prefs.setBool(_enableLiabilitiesKey, val);
    notifyListeners();
  }

  // --- Tags Module ---
  bool get enableTags {
    return _prefs.getBool(_enableTagsKey) ?? false;
  }

  Future<void> setEnableTags(bool val) async {
    await _prefs.setBool(_enableTagsKey, val);
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

  /// Interval values in hours (6, 12, 24, 48). 0 indicates 'manual only' / off.
  int get backupIntervalHours {
    return _prefs.getInt(_autoBackupIntervalKey) ?? 0;
  }

  Future<void> setBackupIntervalHours(int hours) async {
    await _prefs.setInt(_autoBackupIntervalKey, hours);
    notifyListeners();
  }

  bool get autoBackupEnabled {
    return _prefs.getBool(_autoBackupEnabledKey) ?? false;
  }

  Future<void> setAutoBackupEnabled(bool val) async {
    await _prefs.setBool(_autoBackupEnabledKey, val);
    notifyListeners();
  }

  bool get autoRestoreEnabled {
    return _prefs.getBool(_autoRestoreEnabledKey) ?? false;
  }

  Future<void> setAutoRestoreEnabled(bool val) async {
    await _prefs.setBool(_autoRestoreEnabledKey, val);
    notifyListeners();
  }

  Future<void> setAutoBackupFrequency(String freq) async {
    // This was an alias for setAutoBackupInterval.
    // Now we map it to our new hours logic for safety if still called.
    if (freq == 'daily') await setBackupIntervalHours(24);
    if (freq == 'off') await setAutoBackupEnabled(false);
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

  bool get isIncomeDisabled {
    return _prefs.getBool(_disableIncomeKey) ?? false;
  }

  Future<void> setIncomeDisabled(bool val) async {
    await _prefs.setBool(_disableIncomeKey, val);
    notifyListeners();
  }

  // --- Google Drive Connection ---
  bool get isGoogleDriveConnected {
    return _prefs.getBool(_googleDriveConnectedKey) ?? false;
  }

  Future<void> setGoogleDriveConnected(bool val) async {
    await _prefs.setBool(_googleDriveConnectedKey, val);
    notifyListeners();
  }

  // --- Google Email ---
  String? get googleEmail {
    return _prefs.getString(_googleEmailKey);
  }

  Future<void> setGoogleEmail(String? email) async {
    if (email == null) {
      await _prefs.remove(_googleEmailKey);
    } else {
      await _prefs.setString(_googleEmailKey, email);
    }
    notifyListeners();
  }

  // Alias for HomeScreen drawer
  String? get googleAccountEmail => googleEmail;

  // --- Drive Folder ID ---
  String? get driveFolderId {
    return _prefs.getString(_driveFolderIdKey);
  }

  Future<void> setDriveFolderId(String? id) async {
    if (id == null) {
      await _prefs.remove(_driveFolderIdKey);
    } else {
      await _prefs.setString(_driveFolderIdKey, id);
    }
  }

  // --- Drive Connected Account ---
  String? get driveConnectedAccount {
    return _prefs.getString(_driveConnectedAccountKey);
  }

  Future<void> setDriveConnectedAccount(String? email) async {
    if (email == null) {
      await _prefs.remove(_driveConnectedAccountKey);
    } else {
      await _prefs.setString(_driveConnectedAccountKey, email);
    }
    notifyListeners();
  }

  // --- Last Snapshot Day ---
  String? get lastSnapshotDay {
    return _prefs.getString(_lastSnapshotDayKey);
  }

  Future<void> setLastSnapshotDay(String day) async {
    await _prefs.setString(_lastSnapshotDayKey, day);
  }

  // --- Backup Optimization Cache ---
  String? get lastManifestEtag {
    return _prefs.getString(_lastManifestEtagKey);
  }

  Future<void> setLastManifestEtag(String? etag) async {
    if (etag == null) {
      await _prefs.remove(_lastManifestEtagKey);
    } else {
      await _prefs.setString(_lastManifestEtagKey, etag);
    }
  }

  String? get cachedFileList {
    return _prefs.getString(_cachedFileListKey);
  }

  Future<void> setCachedFileList(String? json) async {
    if (json == null) {
      await _prefs.remove(_cachedFileListKey);
    } else {
      await _prefs.setString(_cachedFileListKey, json);
    }
  }

  // --- Snapshot Versioning & Hashing ---
  String? get localSnapshotHash {
    return _prefs.getString(_localSnapshotHashKey);
  }

  Future<void> setLocalSnapshotHash(String? hash) async {
    if (hash == null) {
      await _prefs.remove(_localSnapshotHashKey);
    } else {
      await _prefs.setString(_localSnapshotHashKey, hash);
    }
  }

  int get cloudSnapshotVersion {
    return _prefs.getInt(_cloudSnapshotVersionKey) ?? 0;
  }

  Future<void> setCloudSnapshotVersion(int version) async {
    await _prefs.setInt(_cloudSnapshotVersionKey, version);
  }

  int get localSnapshotVersion {
    return _prefs.getInt(_localSnapshotVersionKey) ?? 0;
  }

  Future<void> setLocalSnapshotVersion(int version) async {
    await _prefs.setInt(_localSnapshotVersionKey, version);
    notifyListeners();
  }

  int get connectedDeviceCount {
    return _prefs.getInt('connected_device_count') ?? 1;
  }

  Future<void> setConnectedDeviceCount(int count) async {
    await _prefs.setInt('connected_device_count', count);
    notifyListeners();
  }

  // --- Sync Architecture Hardening (Whitelist) ---

  /// Returns a Map of settings that are allowed to sync across devices.
  Map<String, dynamic> getSyncedSettings() {
    return {
      _currencyKey: primaryCurrency,
      _enableLendingKey: enableLending,
      _enableCreditCardsKey: enableCreditCards,
      _enableLoansKey: enableLoans,
      _enableLiabilitiesKey: enableLiabilities,
      _enableTagsKey: enableTags,
      _periodicReminderKey: periodicReminderFrequency,
      _autoBackupIntervalKey: backupIntervalHours,
      _autoBackupEnabledKey: autoBackupEnabled,
      _enableAiChatKey: enableAiChat,
      _enableAiReportKey: enableAiReport,
      _disableIncomeKey: isIncomeDisabled,
      _themeVariantKey: themeVariant,
    };
  }

  /// Applies settings from a sync snapshot.
  Future<void> applySyncedSettings(Map<String, dynamic> settings) async {
    if (settings.containsKey(_currencyKey)) {
      await setPrimaryCurrency(settings[_currencyKey]);
    }
    if (settings.containsKey(_enableLendingKey)) {
      await setEnableLending(settings[_enableLendingKey]);
    }
    if (settings.containsKey(_enableCreditCardsKey)) {
      await setEnableCreditCards(settings[_enableCreditCardsKey]);
    }
    if (settings.containsKey(_enableLoansKey)) {
      await setEnableLoans(settings[_enableLoansKey]);
    }
    if (settings.containsKey(_enableLiabilitiesKey)) {
      await setEnableLiabilities(settings[_enableLiabilitiesKey]);
    }
    if (settings.containsKey(_enableTagsKey)) {
      await setEnableTags(settings[_enableTagsKey]);
    }
    if (settings.containsKey(_periodicReminderKey)) {
      await setPeriodicReminderFrequency(settings[_periodicReminderKey]);
    }
    if (settings.containsKey(_autoBackupIntervalKey)) {
      final val = settings[_autoBackupIntervalKey];
      if (val is int) {
        await setBackupIntervalHours(val);
      }
      if (val is String) {
        // Migration from old string intervals
        if (val == 'daily') {
          await setBackupIntervalHours(24);
        }
        if (val == 'off') {
          await setAutoBackupEnabled(false);
        }
      }
    }
    if (settings.containsKey(_autoBackupEnabledKey)) {
      await setAutoBackupEnabled(settings[_autoBackupEnabledKey] == true);
    }
    if (settings.containsKey(_enableAiChatKey)) {
      await setEnableAiChat(settings[_enableAiChatKey]);
    }
    if (settings.containsKey(_enableAiReportKey)) {
      await setEnableAiReport(settings[_enableAiReportKey]);
    }
    if (settings.containsKey(_disableIncomeKey)) {
      await setIncomeDisabled(settings[_disableIncomeKey]);
    }
    if (settings.containsKey(_themeVariantKey)) {
      await setThemeVariant(settings[_themeVariantKey]);
    }

    notifyListeners();
  }

  // --- Text Normalization Migration ---
  bool get isTextNormalizationComplete {
    return _prefs.getBool(_textNormalizationCompleteKey) ?? false;
  }

  Future<void> setTextNormalizationComplete(bool val) async {
    await _prefs.setBool(_textNormalizationCompleteKey, val);
  }

  // --- External Financial Ingestion Controls ---

  bool get whatsappIngestionEnabled {
    return _prefs.getBool(_whatsappIngestionEnabledKey) ?? false;
  }

  Future<void> setWhatsAppIngestionEnabled(bool value) async {
    await _prefs.setBool(_whatsappIngestionEnabledKey, value);
    notifyListeners();
    await syncIngestionSettingsToNative();
  }

  List<String> get whatsappAllowedSenders {
    return _prefs.getStringList(_whatsappAllowedSendersKey) ?? defaultWhatsAppSenders;
  }

  Future<void> setWhatsAppAllowedSenders(List<String> senders) async {
    await _prefs.setStringList(_whatsappAllowedSendersKey, senders);
    notifyListeners();
    await syncIngestionSettingsToNative();
  }

  bool get gmailPreviewEnabled {
    return _prefs.getBool(_gmailPreviewEnabledKey) ?? false;
  }

  Future<void> setGmailPreviewEnabled(bool value) async {
    await _prefs.setBool(_gmailPreviewEnabledKey, value);
    notifyListeners();
    await syncIngestionSettingsToNative();
  }

  List<String> get gmailAllowedSenders {
    return _prefs.getStringList(_gmailAllowedSendersKey) ?? defaultGmailSenders;
  }

  Future<void> setGmailAllowedSenders(List<String> senders) async {
    await _prefs.setStringList(_gmailAllowedSendersKey, senders);
    notifyListeners();
    await syncIngestionSettingsToNative();
  }

  List<String> get extraIngestionPackages {
    return _prefs.getStringList(_extraIngestionPackagesKey) ?? const [];
  }

  Future<void> setExtraIngestionPackages(List<String> packages) async {
    await _prefs.setStringList(_extraIngestionPackagesKey, packages);
    notifyListeners();
    await syncIngestionSettingsToNative();
  }

  /// User-supplied Gemini API key. Stored in SharedPreferences (not encrypted);
  /// users are responsible for their own key. Empty means "use build-time key
  /// or none" (AI features disabled).
  String get geminiApiKey => _prefs.getString(_geminiApiKeyKey) ?? '';

  Future<void> setGeminiApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _prefs.remove(_geminiApiKeyKey);
    } else {
      await _prefs.setString(_geminiApiKeyKey, trimmed);
    }
    notifyListeners();
  }

  Future<void> syncIngestionSettingsToNative() async {
    try {
      await LiveSmsService.instance.syncIngestionSourceSettings(
        whatsappEnabled: whatsappIngestionEnabled,
        whatsappSenders: whatsappAllowedSenders,
        gmailEnabled: gmailPreviewEnabled,
        gmailSenders: gmailAllowedSenders,
        extraPackages: extraIngestionPackages,
      );
    } catch (_) {
      // Best-effort across headless tests/unsupported platforms
    }
  }
}
