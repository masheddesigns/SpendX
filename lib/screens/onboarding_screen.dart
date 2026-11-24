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
import '../shared/widgets/app_confirm_dialog.dart';
import '../shared/widgets/glass/spendx_glass_surface.dart';
import '../shared/widgets/glass/spendx_glass_button.dart';
import '../theme/app_theme.dart';

part 'onboarding/onboarding_welcome_step.dart';
part 'onboarding/onboarding_currency_step.dart';
part 'onboarding/onboarding_ingestion_step.dart';
part 'onboarding/onboarding_backup_step.dart';
part 'onboarding/onboarding_finish_step.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingStepIndicator extends StatelessWidget {
  const _OnboardingStepIndicator({
    required this.currentPage,
    required this.totalPages,
  });

  final int currentPage;
  final int totalPages;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: 'Setup step ${currentPage + 1} of $totalPages',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(totalPages, (index) {
            final selected = currentPage == index;
            final decoration = BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
              borderRadius: BorderRadius.circular(3),
            );
            final margin = const EdgeInsets.symmetric(horizontal: 4);
            if (reduceMotion) {
              return Container(
                margin: margin,
                height: 6,
                width: selected ? 24 : 6,
                decoration: decoration,
              );
            }
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: margin,
              height: 6,
              width: selected ? 24 : 6,
              decoration: decoration,
            );
          }),
        ),
      ),
    );
  }
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  static const _supportedCurrencies = {
    'INR',
    'USD',
    'EUR',
    'GBP',
    'JPY',
    'AUD',
    'CAD',
    'AED',
    'SGD',
  };

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
      if (MediaQuery.disableAnimationsOf(context)) {
        _pageController.jumpToPage(_currentPage + 1);
      } else {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } else {
      _finishOnboarding();
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _pageController.jumpToPage(_currentPage - 1);
      } else {
        _pageController.previousPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void _updateState(VoidCallback update) => setState(update);

  Future<void> _confirmSkip() async {
    final confirmed = await AppConfirmDialog.show(
      context,
      title: 'Skip Setup?',
      message:
          'SpendX works best with your preferred currency and automated tracking enabled. You can always configure these in Settings later.',
      confirmLabel: 'Skip Anyway',
      isDangerous: true,
    );
    if (confirmed == true && mounted) {
      _finishOnboarding();
    }
  }

  Future<void> _finishOnboarding() async {
    if (!_supportedCurrencies.contains(_selectedCurrency)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose a supported currency to continue'),
        ),
      );
      return;
    }

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
      Navigator.of(
        context,
      ).pushReplacement(AppPageRoute(builder: (_) => const HomeScreen()));
    }
  }

  Widget _buildStepIndicator() {
    return _OnboardingStepIndicator(
      currentPage: _currentPage,
      totalPages: _totalPages,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _currentPage > 0
                      ? IconButton(
                          tooltip: 'Arrow Back',
                          icon: Icon(
                            Icons.arrow_back_rounded,
                            color: context.textPrimary,
                          ),
                          onPressed: _previousPage,
                        )
                      : const SizedBox(width: 48),
                  _buildStepIndicator(),
                  _currentPage < _totalPages - 1
                      ? TextButton(
                          onPressed: _confirmSkip,
                          child: Text(
                            'Skip',
                            style: TextStyle(
                              color: context.textMuted,
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
                              ? 'Finish & Launch'
                              : 'Continue'),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
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
}
