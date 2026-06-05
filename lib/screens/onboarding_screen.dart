import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:spend_x/services/settings_service.dart';
import 'package:spend_x/services/notification_service.dart';
import 'package:spend_x/features/home/screens/home_screen.dart';
import 'package:spend_x/widgets/app_button.dart';
import '../shared/widgets/app_page_route.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  final int _totalPages = 5;

  // States
  String _selectedCurrency = 'INR';
  bool _notificationsEnabled = false;

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

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      AppPageRoute(builder: (_) => const HomeScreen()),
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
                : Theme.of(context).colorScheme.outlineVariant,
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
                          child: Text('Skip',
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                color: Theme.of(context).colorScheme.surfaceContainer,
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
                    color: Theme.of(context).colorScheme.onSurface,
                    letterSpacing: -0.5,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'Track expenses, manage salary, loans, goals, and more '
              '— all stored locally on your device.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                'Share screenshots or text from any payment app'),
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
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
              Text(subtitle,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
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
                    color: Theme.of(context).colorScheme.onSurface,
                  )),
          const SizedBox(height: 8),
          Text('Select your main currency for all totals.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                              : Theme.of(context).colorScheme.outlineVariant,
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
                                : Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: Text(c['symbol']!,
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurface,
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
                                        color: Theme.of(context).colorScheme.onSurface,
                                        fontSize: 15)),
                                Text(c['code']!,
                                    style: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
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
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(
              'Get reminders for recurring payments, loan EMIs, salary due dates, '
              'and weekly/monthly financial summaries.',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5),
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
                      Text('Notifications enabled',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(
              'SpendX uses offline-first storage. Backup is optional, encrypted, '
              'and writes only to your personal Google Drive.',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Column(
                children: [
                  _benefitRow(
                      Icons.offline_pin_rounded, 'Works Offline', 'No internet? No problem.'),
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Divider(color: Theme.of(context).colorScheme.outlineVariant)),
                  _benefitRow(Icons.enhanced_encryption_rounded, 'AES-256 Encrypted',
                      'Data encrypted before upload'),
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Divider(color: Theme.of(context).colorScheme.outlineVariant)),
                  _benefitRow(Icons.devices_rounded, 'Multi-Device',
                      'Sync across phones with same Google account'),
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Divider(color: Theme.of(context).colorScheme.outlineVariant)),
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
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
              Text(subtitle,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
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
                      color: Theme.of(context).colorScheme.onSurface,
                    )),
            const SizedBox(height: 16),
            Text(
              'SpendX is ready. Start tracking your finances today.',
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tips_and_updates_rounded,
                          color: Colors.amber[300], size: 20),
                      const SizedBox(width: 12),
                      Text('Quick Tips',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurface)),
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
        Text('\u2022 ', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Expanded(
          child: Text(text,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
        ),
      ],
    );
  }
}
