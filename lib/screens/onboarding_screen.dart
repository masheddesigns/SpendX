import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/services/notification_service_v2.dart';
import 'package:spend_x/services/live_sms_service.dart';
import 'package:spend_x/features/home/screens/home_screen.dart';
import 'package:spend_x/screens/onboarding_sms_sync_screen.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/glass/spendx_glass_surface.dart';
import '../shared/widgets/glass/spendx_glass_button.dart';
import '../theme/app_theme.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  final int _totalPages = 5;
  bool _smsImportOptIn = true;

  // States
  String _selectedCurrency = 'INR';
  bool _smsPermissionGranted = false;
  bool _notificationListenerEnabled = false;
  bool _systemNotificationsEnabled = false;
  bool _batteryOptimizationIgnored = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  Future<void> _checkPermissions() async {
    final sms = await Permission.sms.isGranted;
    final notifs = await Permission.notification.isGranted;
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    bool listener = false;
    try {
      listener = await LiveSmsService.instance.isNotificationListenerEnabled();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _smsPermissionGranted = sms;
        _systemNotificationsEnabled = notifs;
        _notificationListenerEnabled = listener;
        _batteryOptimizationIgnored = battery;
      });
    }
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finishOnboarding();
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _finishOnboarding() async {
    await SettingsService.instance.setOnboardingComplete(true);
    await SettingsService.instance.setPrimaryCurrency(_selectedCurrency);

    // Enable all features by default
    await SettingsService.instance.setEnableCreditCards(true);
    await SettingsService.instance.setEnableLending(true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_sms_optin', _smsImportOptIn);

    if (!mounted) return;

    if (_smsImportOptIn) {
      Navigator.of(context).pushReplacement(
        AppPageRoute(builder: (_) => const OnboardingSmsSyncScreen()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        AppPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  Widget _buildStepIndicator() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_totalPages, (index) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 6,
          width: _currentPage == index ? 24 : 6,
          decoration: BoxDecoration(
            color: _currentPage == index
                ? AppTheme.primaryBlue
                : (isDark ? const Color(0x33FFFFFF) : const Color(0x22000000)),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F111A) : const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _currentPage > 0
                      ? IconButton(
                          icon: Icon(
                            Icons.arrow_back_rounded,
                            color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                          ),
                          onPressed: _previousPage,
                        )
                      : const SizedBox(width: 48),
                  _buildStepIndicator(),
                  _currentPage < _totalPages - 1
                      ? TextButton(
                          onPressed: _finishOnboarding,
                          child: Text(
                            'Skip',
                            style: TextStyle(
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      : const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const BouncingScrollPhysics(),
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                },
                children: [
                  _buildWelcomeScreen(isDark),
                  _buildCurrencySetupScreen(isDark),
                  _buildAutomaticIngestionScreen(isDark),
                  _buildBackupExplanationScreen(isDark),
                  _buildFinishSetupScreen(isDark),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: SizedBox(
                width: double.infinity,
                child: SpendXGlassButton(
                  variant: SpendXGlassButtonVariant.primary,
                  onPressed: _nextPage,
                  child: Text(
                    _currentPage == 0
                        ? 'Get Started'
                        : (_currentPage == _totalPages - 1
                            ? 'Finish & Launch 🚀'
                            : 'Continue'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 1. Welcome & Core Architecture Sayings ──────────────────

  Widget _buildWelcomeScreen(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: isDark ? const Color(0x1A6366F1) : const Color(0x146366F1),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.35),
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.3 : 0.15),
                    blurRadius: 28,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Center(
                child: Hero(
                  tag: 'app_logo',
                  child: SvgPicture.asset(
                    'assets/logo.svg',
                    width: 52,
                    height: 52,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'SpendX',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'The Autonomous, Double-Entry Financial Engine',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4338CA),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          _buildFeatureCard(
            isDark: isDark,
            icon: Icons.shield_rounded,
            iconColor: AppTheme.semanticIncome,
            title: '100% On-Device Privacy',
            description:
                'Zero external servers, zero telemetry, no accounts required. All financial data, transactions, and rules live purely on your phone.',
          ),
          const SizedBox(height: 10),

          _buildFeatureCard(
            isDark: isDark,
            icon: Icons.balance_rounded,
            iconColor: AppTheme.primaryBlue,
            title: 'Canonical Double-Entry Accounting',
            description:
                'Bank-grade integrity where Debits always equal Credits. Every transfer and bill payment balances mathematically with integer paise accuracy.',
          ),
          const SizedBox(height: 10),

          _buildFeatureCard(
            isDark: isDark,
            icon: Icons.flight_takeoff_rounded,
            iconColor: const Color(0xFFF59E0B),
            title: 'Safe-to-Spend Runway',
            description:
                'Dynamic real-time runway that deducts upcoming credit card statements, loan EMIs, and monthly fixed commitments before telling you what you can safely spend.',
          ),
          const SizedBox(height: 10),

          _buildFeatureCard(
            isDark: isDark,
            icon: Icons.security_update_good_rounded,
            iconColor: const Color(0xFF10B981),
            title: 'Smart Anti-Fraud Ingestion',
            description:
                'Strictly parses alphanumeric TRAI banking headers (e.g. HDFCBK, ICICIB). Personal contacts and OTP verification codes are discarded automatically.',
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureCard({
    required bool isDark,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
  }) {
    return SpendXGlassSurface(
      width: double.infinity,
      level: SpendXGlassLevel.base,
      borderRadius: BorderRadius.circular(AppRadius.m),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: isDark ? 0.20 : 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 2. Primary Currency Setup ─────────────────────────────

  Widget _buildCurrencySetupScreen(bool isDark) {
    final currencies = [
      {'code': 'INR', 'symbol': '₹', 'name': 'Indian Rupee'},
      {'code': 'USD', 'symbol': '\$', 'name': 'US Dollar'},
      {'code': 'EUR', 'symbol': '€', 'name': 'Euro'},
      {'code': 'GBP', 'symbol': '£', 'name': 'British Pound'},
      {'code': 'JPY', 'symbol': '¥', 'name': 'Japanese Yen'},
      {'code': 'AUD', 'symbol': 'A\$', 'name': 'Australian Dollar'},
      {'code': 'CAD', 'symbol': 'C\$', 'name': 'Canadian Dollar'},
      {'code': 'AED', 'symbol': 'د.إ', 'name': 'UAE Dirham'},
      {'code': 'SGD', 'symbol': 'S\$', 'name': 'Singapore Dollar'},
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Primary Currency',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Select your primary display currency for account balances, safe-to-spend calculations, and totals.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView.separated(
              itemCount: currencies.length,
              physics: const BouncingScrollPhysics(),
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final c = currencies[index];
                final isSelected = _selectedCurrency == c['code'];

                return SpendXGlassSurface(
                  width: double.infinity,
                  level: isSelected ? SpendXGlassLevel.elevated : SpendXGlassLevel.base,
                  borderRadius: BorderRadius.circular(AppRadius.m),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: InkWell(
                    onTap: () {
                      setState(() => _selectedCurrency = c['code']!);
                      SettingsService.instance.setPrimaryCurrency(c['code']!);
                    },
                    borderRadius: BorderRadius.circular(AppRadius.m),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected
                                ? AppTheme.primaryBlue.withValues(alpha: isDark ? 0.3 : 0.15)
                                : (isDark ? const Color(0x18FFFFFF) : const Color(0x0A000000)),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            c['symbol']!,
                            style: TextStyle(
                              color: isSelected ? AppTheme.primaryBlue : (isDark ? Colors.white : Colors.black),
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c['name']!,
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  fontSize: 14.5,
                                ),
                              ),
                              Text(
                                c['code']!,
                                style: TextStyle(
                                  color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isSelected)
                          const Icon(Icons.check_circle_rounded, color: AppTheme.primaryBlue, size: 22),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── 3. Automatic Ingestion & Permissions ───────────────────

  Widget _buildAutomaticIngestionScreen(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Autonomous Ingestion',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'SpendX can capture your transactions instantly using local Android events. Configure your ingestion streams below:',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
            ),
          ),
          const SizedBox(height: 20),

          // 1. Payment App Notification Listener (UPI Push Capture)
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.notifications_active_rounded, color: AppTheme.primaryBlue, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Payment App Notifications',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_notificationListenerEnabled, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Instantly captures UPI payments from Google Pay, PhonePe, Paytm, and Cred push notifications in real-time before SMS arrives.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_notificationListenerEnabled)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await LiveSmsService.instance.openNotificationListenerSettings();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.tune_rounded, size: 16, color: AppTheme.primaryBlue),
                        SizedBox(width: 6),
                        Text('Enable Notification Listener', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Capturing payments from GPay, PhonePe & Paytm',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 2. Bank & Card SMS Ingestion
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.sms_rounded, color: Color(0xFF10B981), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Bank & Card Transaction SMS',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_smsPermissionGranted, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Parses official banking SMS from HDFCBK, ICICIB, SBIINB, etc. to attribute debits, credits, and refunds. Personal contacts and OTPs are completely ignored.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_smsPermissionGranted)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await Permission.sms.request();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_open_rounded, size: 16, color: Color(0xFF10B981)),
                        SizedBox(width: 6),
                        Text('Grant SMS Permission', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Monitoring official bank and card SMS',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 3. Alerts & Due Date System Notifications
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.alarm_rounded, color: Color(0xFFF59E0B), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Bill Reminders & Runway Alerts',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_systemNotificationsEnabled, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Receive proactive warnings for upcoming credit card bill due dates, loan EMI installments, and safe-to-spend runway thresholds.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_systemNotificationsEnabled)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await NotificationServiceV2().requestPermissions();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.notifications_active_rounded, size: 16, color: Color(0xFFF59E0B)),
                        SizedBox(width: 6),
                        Text('Allow System Notifications', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Bill reminders and runway alerts enabled',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 4. Unrestricted Battery Execution (FuntouchOS / OriginOS / MIUI / HyperOS)
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8B5CF6).withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.battery_charging_full_rounded, color: Color(0xFF8B5CF6), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  'Unrestricted Background Battery',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _statusPill(_batteryOptimizationIgnored, isDark),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Prevents OEM aggressive battery managers (Vivo FuntouchOS, OriginOS, MIUI) from terminating live notification listeners and SMS parsers when the screen is locked.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (!_batteryOptimizationIgnored)
                  SpendXGlassButton(
                    variant: SpendXGlassButtonVariant.tonal,
                    onPressed: () async {
                      await Permission.ignoreBatteryOptimizations.request();
                      await _checkPermissions();
                    },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.bolt_rounded, size: 16, color: Color(0xFF8B5CF6)),
                        SizedBox(width: 6),
                        Text('Unrestrict Battery Usage', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.semanticIncome.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 16, color: AppTheme.semanticIncome),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Active: Unrestricted background execution enabled',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.semanticIncome),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(bool isEnabled, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isEnabled
            ? const Color(0x1F10B981)
            : (isDark ? const Color(0x22FFFFFF) : const Color(0x18000000)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isEnabled ? 'Active ✓' : 'Setup',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: isEnabled
              ? AppTheme.semanticIncome
              : (isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted),
        ),
      ),
    );
  }

  // ── 4. Encrypted Google Drive Backup ───────────────────────

  Widget _buildBackupExplanationScreen(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.15 : 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                  width: 1.0,
                ),
              ),
              child: const Icon(Icons.cloud_sync_rounded, size: 48, color: Color(0xFFF59E0B)),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Your Data, Your Drive',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'SpendX is strictly offline-first. Cloud backup is 100% optional, client-side encrypted, and stores only in your personal Google Drive.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          _buildFeatureCard(
            isDark: isDark,
            icon: Icons.offline_pin_rounded,
            iconColor: AppTheme.semanticIncome,
            title: 'Full Offline Autonomy',
            description: 'No internet connection needed. All ledger postings, calculations, and rules function seamlessly offline.',
          ),
          const SizedBox(height: 10),

          _buildFeatureCard(
            isDark: isDark,
            icon: Icons.enhanced_encryption_rounded,
            iconColor: AppTheme.primaryBlue,
            title: 'AES-256 Client-Side Encryption',
            description: 'Your database snapshot is encrypted on device using your personal passphrase before uploading to Drive.',
          ),
          const SizedBox(height: 10),

          _buildFeatureCard(
            isDark: isDark,
            icon: Icons.devices_rounded,
            iconColor: const Color(0xFF6366F1),
            title: 'Seamless Cross-Device Restore',
            description: 'Switching phones? Restore your complete double-entry database, rules, and settings in one tap.',
          ),
        ],
      ),
    );
  }

  // ── 5. Finish & Launch Setup ──────────────────────────────

  Widget _buildFinishSetupScreen(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.20 : 0.12),
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.3)),
              ),
              child: const Icon(Icons.rocket_launch_rounded, size: 40, color: AppTheme.primaryBlue),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            "You're All Set!",
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'SpendX is configured and ready to autonomously manage your finances.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // SMS Initial History Sync Option
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.20 : 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.history_rounded, color: AppTheme.primaryBlue, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Scan Past Banking SMS',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Import past transaction history to automatically reconstruct initial account balances.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _smsImportOptIn,
                  activeTrackColor: AppTheme.primaryBlue,
                  onChanged: (v) => setState(() => _smsImportOptIn = v),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Pro Tips
          SpendXGlassSurface(
            width: double.infinity,
            level: SpendXGlassLevel.base,
            borderRadius: BorderRadius.circular(AppRadius.l),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lightbulb_rounded, size: 16, color: Color(0xFFF59E0B)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'PRO TIPS FOR MAXIMUM ACCURACY',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                          color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _tipRow(isDark, 'Tap the floating + to manually add an expense, income, or move funds between accounts.'),
                const SizedBox(height: 8),
                _tipRow(isDark, 'Check the Review Queue if a transaction needs manual account confirmation.'),
                const SizedBox(height: 8),
                _tipRow(isDark, 'Set up Credit Cards and EMIs to enable your real-time Safe-to-Spend runway calculation.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tipRow(bool isDark, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '• ',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: AppTheme.primaryBlue,
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
            ),
          ),
        ),
      ],
    );
  }
}
