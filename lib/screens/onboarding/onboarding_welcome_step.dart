part of '../onboarding_screen.dart';

extension _OnboardingWelcomeStep on _OnboardingScreenState {
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
                color: isDark
                    ? const Color(0x1A6366F1)
                    : const Color(0x146366F1),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: AppTheme.primaryBlue.withValues(alpha: 0.35),
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryBlue.withValues(
                      alpha: isDark ? 0.3 : 0.15,
                    ),
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
                    semanticsLabel: 'SpendX logo',
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
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: isDark
                        ? AppTheme.darkTextMuted
                        : AppTheme.lightTextMuted,
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
}
