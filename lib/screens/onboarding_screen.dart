import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import 'package:provider/provider.dart';

import 'home_screen.dart';
import '../widgets/app_button.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  final int _totalPages = 8;

  // States for interactive screens
  bool _enableVehicles = true;
  bool _enableCreditCards = true;
  bool _enableLending = true;
  String _selectedCurrency = 'USD';
  Set<String> _selectedCategories = {'Food', 'Transport'};

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
    await SettingsService.instance.setEnableVehicles(_enableVehicles);
    await SettingsService.instance.setEnableCreditCards(_enableCreditCards);
    await SettingsService.instance.setEnableLending(_enableLending);

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
            color: _currentPage == index ? Theme.of(context).colorScheme.primary : Colors.grey.shade800,
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
            // Top Bar
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
                          child: const Text('Skip', style: TextStyle(color: Colors.grey)),
                        )
                      : const SizedBox(width: 48),
                ],
              ),
            ),
            
            // Page Content
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(), // Disable swipe
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                },
                children: [
                  _buildWelcomeScreen(),
                  _buildAppOverviewScreen(),
                  _buildFeatureSelectionScreen(),
                  _buildCurrencySetupScreen(),
                  _buildCategorySetupScreen(),
                  _buildDataImportScreen(),
                  _buildThemeSetupScreen(),
                  _buildFinishSetupScreen(),
                ],
              ),
            ),
            
            // Bottom Action Area
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: SizedBox(
                width: double.infinity,
                child: AppButton.secondary(
                  onPressed: _nextPage,
                  text: _currentPage == _totalPages - 1 ? "Let's Go" : "Continue",
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Screens --- //

  Widget _buildWelcomeScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                    blurRadius: 25,
                  )
                ]
              ),
              child: const Icon(Icons.account_balance_wallet, size: 70, color: Colors.white),

            ),
            const SizedBox(height: 48),
            Text(
              'Welcome to SpendX',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'Take control of your finances with powerful tracking and beautiful insights.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.white70,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppOverviewScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'How it works',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 32),
            _buildFeatureCard(Icons.document_scanner, 'AI Vision Scanner', 'Scan bills and PDFs automatically.'),
            const SizedBox(height: 16),
            _buildFeatureCard(Icons.account_balance_wallet_rounded, 'Net Worth Tracking', 'Track assets and balances beautifully.'),
            const SizedBox(height: 16),
            _buildFeatureCard(Icons.credit_card, 'Credit & EMI', 'Manage credit cards, loans, and bills.'),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureCard(IconData icon, String title, String subtitle) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.white)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildFeatureSelectionScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 32),
            Text(
              'Customize modules',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 8),
            Text('Turn on the extra features you plan to use.', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 32),
            _buildToggleTile('Vehicle Tracking', 'Fuel logs and maintenance', _enableVehicles, (v) => setState(() => _enableVehicles = v)),
            const SizedBox(height: 16),
            _buildToggleTile('Credit Cards', 'Track limits and bills', _enableCreditCards, (v) => setState(() => _enableCreditCards = v)),
            const SizedBox(height: 16),
            _buildToggleTile('Lending', 'Manage loans and EMIs', _enableLending, (v) => setState(() => _enableLending = v)),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleTile(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: value
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.10),
          width: 1.5,
        ),
      ),
      child: SwitchListTile(
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        value: value,
        onChanged: onChanged,
        activeColor: Colors.white,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        inactiveThumbColor: Colors.grey[400],
        inactiveTrackColor: Colors.grey[700],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      ),
    );
  }

  Widget _buildCurrencySetupScreen() {
    final currencies = ['USD', 'EUR', 'GBP', 'INR', 'JPY', 'CAD', 'AUD'];

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 32),
            Text(
              'Primary Currency',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 8),
            Text('Select your main currency. You can add more later.', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 32),
            ...currencies.map((currency) {
              final isSelected = _selectedCurrency == currency;
              return GestureDetector(
                onTap: () => setState(() => _selectedCurrency = currency),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isSelected 
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) 
                        : Theme.of(context).colorScheme.surfaceContainer,
                    border: Border.all(
                      color: isSelected 
                          ? Theme.of(context).colorScheme.primary 
                          : Colors.white.withValues(alpha: 0.1),
                      width: isSelected ? 2.0 : 1.0,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      if (isSelected) 
                        BoxShadow(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: isSelected 
                                ? Theme.of(context).colorScheme.primary 
                                : Colors.white10,
                            child: Text(
                              currency,
                              style: TextStyle(
                                color: isSelected ? Colors.white : Colors.white70,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            currency,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                              color: isSelected ? Colors.white : Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      if (isSelected) 
                        Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 24),
                    ],
                  ),
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  Widget _buildCategorySetupScreen() {
    final categories = ['Food', 'Transport', 'Housing', 'Utilities', 'Entertainment', 'Shopping', 'Healthcare'];

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 32),
            Text(
              'Select Categories',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 8),
            Text('Choose the spending categories you use most.', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 32),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: categories.map((cat) {
                final isSelected = _selectedCategories.contains(cat);
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedCategories.remove(cat);
                      } else {
                        _selectedCategories.add(cat);
                      }
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected 
                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) 
                          : Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isSelected 
                            ? Theme.of(context).colorScheme.primary 
                            : Colors.white.withValues(alpha: 0.1),
                        width: 1.5,
                      ),
                      boxShadow: [
                        if (isSelected) 
                          BoxShadow(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                      ],
                    ),
                    child: Text(
                      cat,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataImportScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 32),
            Text(
              'Import Data',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 8),
            Text('Bring your existing financial data into SpendX.', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 48),
            _buildImportCard(Icons.document_scanner, 'AI Bank Statement Import', 'Upload a PDF bank statement. SpendX AI will parse it automatically.', true),
            const SizedBox(height: 16),
            _buildImportCard(Icons.table_chart, 'CSV Import', 'Upload a CSV file from your previous tracking app.', false),
          ],
        ),
      ),
    );
  }

  Widget _buildImportCard(IconData icon, String title, String subtitle, bool isPrimary) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isPrimary
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.10),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isPrimary
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 18)),
          const SizedBox(height: 8),
          Text(subtitle, style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 16),
          AppButton.secondary(
            onPressed: () {},
            text: 'Select File',
            width: 140,
          )
        ],
      ),
    );
  }


  Widget _buildThemeSetupScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 32),
            Text(
              'App Color Theme',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 8),
            Text('Select your preferred organic color palette.', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 48),
            Consumer<AppTheme>(
              builder: (context, themeNotifier, _) {
                return Wrap(
                  spacing: 20,
                  runSpacing: 20,
                  alignment: WrapAlignment.center,
                  children: AppTheme.availableThemes.map((theme) {
                    final color = theme['color'];
                    final isSelected = color == themeNotifier.seedColor;
                    return GestureDetector(
                      onTap: () {
                        themeNotifier.setPrimaryColor(color);
                      },
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: isSelected ? Border.all(color: Colors.white, width: 4) : null,
                          boxShadow: [
                            if (isSelected) BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 12, spreadRadius: 4),
                          ],
                        ),
                        child: isSelected ? Icon(Icons.check, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white, size: 32) : null,
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildFinishSetupScreen() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(32),
              ),
              child: Icon(Icons.check_circle_outline, size: 80, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 48),
            Text(
              'You\'re all set!',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 16),
            Text(
              'Your SpendX is configured and ready to go. Let\'s achieve financial clarity.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.white70,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
