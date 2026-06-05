import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:spend_x/widgets/spendx_app_bar.dart';

import 'privacy_policy_screen.dart';
import '../shared/widgets/app_page_route.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SpendXAppBar(title: 'About SpendX'),
      body: SafeArea(
        child: FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final version = snapshot.data?.version ?? '1.5.0';

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.primary.withValues(alpha: 0.12),
                        blurRadius: 28,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF23BE62).withValues(alpha: 0.3),
                              blurRadius: 24,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Center(
                          child: SvgPicture.asset(
                            'assets/logo.svg',
                            width: 56,
                            height: 56,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'SpendX',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Version $version',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'SpendX is an offline-first personal finance tracker. '
                        'Track expenses, income, salary, loans, goals, and more '
                        '— all stored locally on your device with optional encrypted cloud backup.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          height: 1.6,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Features ──────────────────────────────────
                _InfoCard(
                  title: 'Key Features',
                  rows: const [
                    _InfoRow(
                      icon: Icons.receipt_long_rounded,
                      label: 'Expense & Income Tracking',
                      value: 'Log transactions with categories, tags, notes, and payment methods. '
                          'Supports recurring payments and auto-logging.',
                    ),
                    _InfoRow(
                      icon: Icons.account_balance_wallet_rounded,
                      label: 'Salary Intelligence',
                      value: 'Track income by company or client — full-time, part-time, freelance, or contract. '
                          'Supports monthly, weekly, bi-weekly, daily, and per-project pay cycles '
                          'with delay analysis, reliability scoring, and payment hold tracking.',
                    ),
                    _InfoRow(
                      icon: Icons.account_balance_rounded,
                      label: 'Loans, Credit Cards & Lending',
                      value: 'Manage loan EMIs, credit card outstanding, and lending/borrowing '
                          'with payment tracking and reminders.',
                    ),
                    _InfoRow(
                      icon: Icons.flag_rounded,
                      label: 'Savings Goals',
                      value: 'Set financial targets with progress tracking, '
                          'contribution logs, and visual progress indicators.',
                    ),
                    _InfoRow(
                      icon: Icons.sms_rounded,
                      label: 'SMS Auto-Import',
                      value: 'Automatically capture bank transactions from SMS messages '
                          'in real-time using smart pattern detection.',
                    ),
                    _InfoRow(
                      icon: Icons.auto_awesome_rounded,
                      label: 'Smart Import',
                      value: 'Import from CSV, JSON, Markdown, HTML, or ZIP (Notion exports). '
                          'Auto-detects columns with 100+ keywords and 200+ category aliases.',
                    ),
                    _InfoRow(
                      icon: Icons.share_rounded,
                      label: 'Share-to-Import',
                      value: 'Share files directly from Notion, Google Sheets, or any app '
                          'to SpendX for instant import via the Android share sheet.',
                    ),
                    _InfoRow(
                      icon: Icons.emoji_events_rounded,
                      label: 'Gamification & Wrapped',
                      value: 'Earn XP, level up through Bronze to Diamond tiers, '
                          'and view Spotify-style weekly/monthly/yearly financial summaries.',
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Tech Stack ────────────────────────────────
                _InfoCard(
                  title: 'Tech Stack',
                  rows: const [
                    _InfoRow(
                      icon: Icons.phone_android_rounded,
                      label: 'Flutter + Riverpod',
                      value: 'Cross-platform UI with Material Design 3 and reactive state management.',
                    ),
                    _InfoRow(
                      icon: Icons.storage_rounded,
                      label: 'SQLite (44 tables)',
                      value: 'Local offline-first database via sqflite with full schema validation.',
                    ),
                    _InfoRow(
                      icon: Icons.cloud_done_outlined,
                      label: 'Google Drive Backup',
                      value: 'AES-256 encrypted backup to your personal Drive with auto-backup, '
                          'auto-restore, and multi-device sync.',
                    ),
                    _InfoRow(
                      icon: Icons.auto_awesome_outlined,
                      label: 'Gemini AI',
                      value: 'Receipt scanning, AI chat assistant, and smart transaction categorization.',
                    ),
                    _InfoRow(
                      icon: Icons.palette_outlined,
                      label: 'Material Design 3',
                      value: 'Multiple theme colors, light/dark mode, and consistent card system.',
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Data Ownership ────────────────────────────
                _InfoCard(
                  title: 'Data Ownership',
                  rows: const [
                    _InfoRow(
                      icon: Icons.lock_outline_rounded,
                      label: 'Privacy-first',
                      value: 'All data stays on your device by default. No external servers, no tracking, no ads.',
                    ),
                    _InfoRow(
                      icon: Icons.enhanced_encryption_outlined,
                      label: 'Encrypted backup',
                      value: 'Cloud backup is AES-256 encrypted on-device before upload. '
                          'Only you can decrypt it — even across devices.',
                    ),
                    _InfoRow(
                      icon: Icons.delete_outline_rounded,
                      label: 'Full control',
                      value: 'Export as CSV/JSON/PDF, restore from backup, clear individual data types, '
                          'or delete everything including cloud backups.',
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Privacy Policy link ───────────────────────
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => Navigator.push(
                    context,
                    AppPageRoute(
                      builder: (_) => const PrivacyPolicyScreen(),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: colorScheme.tertiary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.shield_outlined,
                            color: colorScheme.tertiary,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Privacy Policy',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'How SpendX handles your data, SMS permissions, backups, and AI features.',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      height: 1.5,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final List<_InfoRow> rows;

  const _InfoCard({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),
          for (var index = 0; index < rows.length; index++) ...[
            rows[index],
            if (index < rows.length - 1) const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: colorScheme.primary, size: 22),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
