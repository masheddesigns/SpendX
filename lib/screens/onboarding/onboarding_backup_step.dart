part of '../onboarding_screen.dart';

extension _OnboardingBackupStep on _OnboardingScreenState {
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

}
