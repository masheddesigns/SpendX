import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/services/notification_service.dart';
import 'package:spend_x/features/home/screens/home_screen.dart';
import 'package:spend_x/widgets/app_button.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  final int _totalPages = 6;

  // States
  String _selectedCurrency = 'INR';
  bool _notificationsEnabled = false;
  bool _smsEnabled = false;
  String _smsImportPeriod = 'last_30'; // 'last_7', 'last_30', 'last_90', 'all'

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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
    await SettingsService.instance.setEnableVehicles(true);
    await SettingsService.instance.setEnableCreditCards(true);
    await SettingsService.instance.setEnableLending(true);

    // Save SMS preference via SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sms_import_enabled', _smsEnabled);
    await prefs.setString('sms_import_period', _smsImportPeriod);

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_totalPages, (index) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 8,
          width: _currentPage == index ? 24 : 8,
          decoration: BoxDecoration(
            color: _currentPage == index
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade800,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                          icon: const Icon(Icons.arrow_back),
                          onPressed: _previousPage,
                        )
                      : const SizedBox(width: 48),
                  _buildStepIndicator(),
                  _currentPage < _totalPages - 1
                      ? TextButton(
                          onPressed: _finishOnboarding,
                          child: const Text('Skip',
                              style: TextStyle(color: Colors.grey)),
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
                  _buildWelcomeScreen(),
                  _buildCurrencySetupScreen(),
                  _buildNotificationPermissionScreen(),
                  _buildSmsPermissionScreen(),
                  _buildBackupExplanationScreen(),
                  _buildFinishSetupScreen(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: SizedBox(
                width: double.infinity,
                child: AppButton.secondary(
                  onPressed: _nextPage,
                  text: _currentPage == 0
                      ? 'Get Started'
                      : (_currentPage == _totalPages - 1
                          ? 'Finish Setup'
                          : 'Continue'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Welcome ───────────────────────────────────────────

  Widget _buildWelcomeScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 48.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 32),
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF23BE62).withValues(alpha: 0.3),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Center(
                child: Hero(
                  tag: 'app_logo',
                  child: SvgPicture.asset(
                    'assets/logo.svg',
                    width: 64,
                    height: 64,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),
            Text(
              'Welcome to SpendX',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'Track expenses, manage salary, loans, goals, and more '
              '— all stored locally on your device.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.white70,
                    height: 1.5,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            _buildSmallFeature(Icons.security_rounded, 'Privacy First',
                'All data stays on your device'),
            const SizedBox(height: 14),
            _buildSmallFeature(Icons.cloud_done_rounded, 'Encrypted Backup',
                'AES-256 encrypted Google Drive sync'),
            const SizedBox(height: 14),
            _buildSmallFeature(Icons.auto_awesome_rounded, 'Smart Import',
                'Import from CSV, JSON, Notion, and more'),
            const SizedBox(height: 14),
            _buildSmallFeature(Icons.sms_rounded, 'SMS Auto-Track',
                'Auto-detect bank transactions from SMS'),
            const SizedBox(height: 14),
            _buildSmallFeature(Icons.emoji_events_rounded, 'Gamification',
                'Earn XP, level up, and view Wrapped summaries'),
          ],
        ),
      ),
    );
  }

  Widget _buildSmallFeature(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: Colors.white70, size: 20),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.white)),
              Text(subtitle,
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  // ── Currency ──────────────────────────────────────────

  Widget _buildCurrencySetupScreen() {
    final currencies = [
      {'code': 'INR', 'symbol': '\u20B9', 'name': 'Indian Rupee'},
      {'code': 'USD', 'symbol': '\$', 'name': 'US Dollar'},
      {'code': 'EUR', 'symbol': '\u20AC', 'name': 'Euro'},
      {'code': 'GBP', 'symbol': '\u00A3', 'name': 'British Pound'},
      {'code': 'JPY', 'symbol': '\u00A5', 'name': 'Japanese Yen'},
      {'code': 'AUD', 'symbol': 'A\$', 'name': 'Australian Dollar'},
      {'code': 'CAD', 'symbol': 'C\$', 'name': 'Canadian Dollar'},
      {'code': 'AED', 'symbol': '\u062F.\u0625', 'name': 'UAE Dirham'},
      {'code': 'SGD', 'symbol': 'S\$', 'name': 'Singapore Dollar'},
    ];

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 32),
          Text('Primary Currency',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  )),
          const SizedBox(height: 8),
          const Text('Select your main currency for all totals.',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 32),
          Expanded(
            child: ListView.builder(
              itemCount: currencies.length,
              physics: const BouncingScrollPhysics(),
              itemBuilder: (context, index) {
                final c = currencies[index];
                final isSelected = _selectedCurrency == c['code'];

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _selectedCurrency = c['code']!);
                      SettingsService.instance.setPrimaryCurrency(c['code']!);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.15)
                            : Theme.of(context).colorScheme.surfaceContainer,
                        border: Border.all(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white.withValues(alpha: 0.08),
                          width: isSelected ? 2.0 : 1.0,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white.withValues(alpha: 0.05),
                            child: Text(c['symbol']!,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c['name']!,
                                    style: TextStyle(
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: Colors.white,
                                        fontSize: 15)),
                                Text(c['code']!,
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 13)),
                              ],
                            ),
                          ),
                          if (isSelected)
                            Icon(Icons.check_circle_rounded,
                                color: Theme.of(context).colorScheme.primary,
                                size: 24),
                        ],
                      ),
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

  // ── Notifications ─────────────────────────────────────

  Widget _buildNotificationPermissionScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(Icons.notifications_active_rounded,
                  size: 70, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 40),
            Text('Stay on Track',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(
              'Get reminders for recurring payments, loan EMIs, salary due dates, '
              'and weekly/monthly financial summaries.',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Colors.white70, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            _notificationsEnabled
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      const Text('Notifications enabled',
                          style: TextStyle(color: Colors.white70)),
                    ],
                  )
                : AppButton.secondary(
                    onPressed: () async {
                      await NotificationService.instance.requestPermissions();
                      setState(() => _notificationsEnabled = true);
                    },
                    text: 'Enable Notifications',
                  ),
          ],
        ),
      ),
    );
  }

  // ── SMS Permission + Import Period ────────────────────

  Widget _buildSmsPermissionScreen() {
    final cs = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(Icons.sms_rounded,
                  size: 70, color: Color(0xFF0EA5E9)),
            ),
            const SizedBox(height: 40),
            Text('Auto-Track from SMS',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(
              'SpendX can read your bank SMS messages to automatically log transactions. '
              'All processing happens on your device — nothing is sent to any server.',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Colors.white70, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // Enable/Disable toggle
            _smsEnabled
                ? Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle, color: cs.primary),
                          const SizedBox(width: 8),
                          const Text('SMS access enabled',
                              style: TextStyle(color: Colors.white70)),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Import period selection
                      Text('Import messages from:',
                          style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      ..._buildPeriodOptions(cs),
                    ],
                  )
                : Column(
                    children: [
                      AppButton.secondary(
                        onPressed: () async {
                          final status = await Permission.sms.request();
                          if (status.isGranted) {
                            setState(() => _smsEnabled = true);
                          }
                        },
                        text: 'Enable SMS Access',
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () => _nextPage(),
                        child: const Text('Skip — I\'ll add transactions manually',
                            style: TextStyle(color: Colors.white54)),
                      ),
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildPeriodOptions(ColorScheme cs) {
    const options = [
      ('last_7', 'Last 7 days', 'Quick scan of recent transactions'),
      ('last_30', 'Last 30 days', 'Recommended for most users'),
      ('last_90', 'Last 3 months', 'Import recent history'),
      ('all', 'All messages', 'Full SMS scan — may take a moment'),
    ];

    return options.map((opt) {
      final isSelected = _smsImportPeriod == opt.$1;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GestureDetector(
          onTap: () => setState(() => _smsImportPeriod = opt.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? cs.primary.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.03),
              border: Border.all(
                color: isSelected
                    ? cs.primary
                    : Colors.white.withValues(alpha: 0.08),
                width: isSelected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: isSelected ? cs.primary : Colors.white38,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(opt.$2,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                          )),
                      Text(opt.$3,
                          style:
                              const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  // ── Backup ────────────────────────────────────────────

  Widget _buildBackupExplanationScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 48),
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(32),
              ),
              child: const Icon(Icons.cloud_sync_rounded,
                  size: 80, color: Colors.amber),
            ),
            const SizedBox(height: 40),
            Text('Your Data, Your Drive',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(
              'SpendX uses offline-first storage. Backup is optional, encrypted, '
              'and writes only to your personal Google Drive.',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Colors.white70, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Column(
                children: [
                  _benefitRow(
                      Icons.offline_pin_rounded, 'Works Offline', 'No internet? No problem.'),
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(color: Colors.white10)),
                  _benefitRow(Icons.enhanced_encryption_rounded, 'AES-256 Encrypted',
                      'Data encrypted before upload'),
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(color: Colors.white10)),
                  _benefitRow(Icons.devices_rounded, 'Multi-Device',
                      'Sync across phones with same Google account'),
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(color: Colors.white10)),
                  _benefitRow(Icons.restore_page_rounded, 'Easy Recovery',
                      'Restore everything in one tap'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _benefitRow(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary, size: 24),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.white)),
              Text(subtitle,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  // ── Finish ────────────────────────────────────────────

  Widget _buildFinishSetupScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 48.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 48),
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                ),
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                ),
                Icon(Icons.rocket_launch_rounded,
                    size: 60, color: Theme.of(context).colorScheme.primary),
              ],
            ),
            const SizedBox(height: 48),
            Text("You're all set!",
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    )),
            const SizedBox(height: 16),
            Text(
              'SpendX is ready. Start tracking your finances today.',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Colors.white70, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tips_and_updates_rounded,
                          color: Colors.amber[300], size: 20),
                      const SizedBox(width: 12),
                      const Text('Quick Tips',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, color: Colors.white)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _tipRow('Tap + on Home to add your first transaction'),
                  const SizedBox(height: 8),
                  _tipRow('Go to More > Income & Salary to set up salary tracking'),
                  const SizedBox(height: 8),
                  _tipRow('Share any CSV/JSON from Notion or Sheets directly to SpendX'),
                  const SizedBox(height: 8),
                  _tipRow('Enable auto-backup in Backup & Sync for peace of mind'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tipRow(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('\u2022 ', style: TextStyle(color: Colors.white54)),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Colors.white70, height: 1.4)),
        ),
      ],
    );
  }
}
