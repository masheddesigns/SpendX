part of '../onboarding_screen.dart';

extension _OnboardingFinishStep on _OnboardingScreenState {
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
                color: AppTheme.primaryBlue.withValues(
                  alpha: isDark ? 0.20 : 0.12,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.3),
                ),
              ),
              child: const Icon(
                Icons.rocket_launch_rounded,
                size: 40,
                color: AppTheme.primaryBlue,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            "You're All Set!",
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'SpendX is configured and ready to autonomously manage your finances.',
            style: TextStyle(fontSize: 13, color: context.textMuted),
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
                    color: AppTheme.primaryBlue.withValues(
                      alpha: isDark ? 0.20 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.history_rounded,
                    color: AppTheme.primaryBlue,
                    size: 20,
                  ),
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
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Import past transaction history to automatically reconstruct initial account balances.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: context.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _smsImportOptIn,
                  activeTrackColor: AppTheme.primaryBlue,
                  onChanged: (v) => _updateState(() => _smsImportOptIn = v),
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
                     Icon(
                      Icons.lightbulb_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
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
                          color: context.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _tipRow(
                  isDark,
                  'Tap the floating + to manually add an expense, income, or move funds between accounts.',
                ),
                const SizedBox(height: 8),
                _tipRow(
                  isDark,
                  'Check the Review Queue if a transaction needs manual account confirmation.',
                ),
                const SizedBox(height: 8),
                _tipRow(
                  isDark,
                  'Set up Credit Cards and EMIs to enable your real-time Safe-to-Spend runway calculation.',
                ),
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
              color: context.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}
