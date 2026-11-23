part of '../onboarding_screen.dart';

extension _OnboardingCurrencyStep on _OnboardingScreenState {
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
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Select your primary display currency for account balances, safe-to-spend calculations, and totals.',
            style: TextStyle(fontSize: 13, color: context.textMuted),
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
                  level: isSelected
                      ? SpendXGlassLevel.elevated
                      : SpendXGlassLevel.base,
                  borderRadius: BorderRadius.circular(AppRadius.m),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: InkWell(
                    onTap: () {
                      _updateState(() => _selectedCurrency = c['code']!);
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
                                ? AppTheme.primaryBlue.withValues(
                                    alpha: isDark ? 0.3 : 0.15,
                                  )
                                : (isDark
                                      ? const Color(0x18FFFFFF)
                                      : const Color(0x0A000000)),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            c['symbol']!,
                            style: TextStyle(
                              color: isSelected
                                  ? AppTheme.primaryBlue
                                  : (isDark ? Colors.white : Colors.black),
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
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  color: context.textPrimary,
                                  fontSize: 14.5,
                                ),
                              ),
                              Text(
                                c['code']!,
                                style: TextStyle(
                                  color: context.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isSelected)
                          const Icon(
                            Icons.check_circle_rounded,
                            color: AppTheme.primaryBlue,
                            size: 22,
                          ),
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
}
