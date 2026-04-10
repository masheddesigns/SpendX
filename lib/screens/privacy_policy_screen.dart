import 'package:flutter/material.dart';
import 'package:spend_x/widgets/spendx_app_bar.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Privacy Policy'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your data stays yours.',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'SpendX is built around local-first storage and user-controlled backups. '
                    'We do not run a central server that stores your personal financial records. '
                    'No ads, no tracking, no third-party analytics.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const _PolicySection(
              title: 'Local Storage',
              content:
                  'All your financial data — transactions, categories, salary records, loans, '
                  'goals, accounts, lending records, credit card data, and settings — is stored '
                  'locally on your device using an SQLite database. This data never leaves your '
                  'device unless you explicitly enable cloud backup or share/export it.',
            ),
            const _PolicySection(
              title: 'Encrypted Cloud Backup',
              content:
                  'If you enable Google Drive backup, your data is encrypted on your device '
                  'using AES-256 encryption before being uploaded. The encryption key is derived '
                  'from your Google account email, so only devices signed into the same account '
                  'can decrypt the backup. SpendX does not store encryption keys on any server. '
                  'Backup files are stored in your personal Google Drive appData folder, which '
                  'is not visible in your regular Drive files.',
            ),
            const _PolicySection(
              title: 'SMS Permission',
              content:
                  'SpendX requests SMS read permission to automatically detect bank transaction '
                  'messages and log them as expenses or income. SMS data is processed entirely '
                  'on your device using local pattern matching. No SMS content is transmitted to '
                  'any server. You can disable SMS import at any time from the app settings. '
                  'SpendX only reads transaction-related SMS from known bank sender IDs.',
            ),
            const _PolicySection(
              title: 'Share-to-Import',
              content:
                  'When you share a file (CSV, JSON, Markdown, HTML, ZIP) from another app to '
                  'SpendX, the file is received locally and processed on your device. No shared '
                  'files are uploaded to any server. The file is parsed to extract transaction '
                  'data which you can review before importing.',
            ),
            const _PolicySection(
              title: 'AI Features',
              content:
                  'Receipt scanning and the AI chat assistant use Google Gemini API when activated. '
                  'Only the specific image or question you submit is sent to the API — your full '
                  'transaction history is never shared. AI features are optional and require your '
                  'explicit action to use. No AI processing happens in the background.',
            ),
            const _PolicySection(
              title: 'No External Data Storage',
              content:
                  'SpendX does not store your financial data on any external company servers. '
                  'There is no SpendX backend, no user accounts on our servers, and no telemetry. '
                  'The only external service used is Google Drive for optional encrypted backup, '
                  'which writes to your own personal Drive account.',
            ),
            const _PolicySection(
              title: 'Notifications',
              content:
                  'SpendX uses local notifications for payment reminders, recurring transaction '
                  'alerts, and goal milestones. These are scheduled entirely on-device using '
                  'Flutter Local Notifications. No push notification server is involved.',
            ),
            const _PolicySection(
              title: 'Data Control & Deletion',
              content:
                  'You have full control over your data at all times:\n\n'
                  '  \u2022  Export transactions as CSV, JSON, or PDF\n'
                  '  \u2022  Export full app backup as JSON\n'
                  '  \u2022  Clear individual data types (expenses, income, salary, loans, goals, accounts)\n'
                  '  \u2022  Clear ALL app data with one tap\n'
                  '  \u2022  Delete cloud backup from Google Drive\n'
                  '  \u2022  Unlink Google account at any time\n\n'
                  'Deleting data is permanent and cannot be reversed unless you have a backup.',
            ),
            const _PolicySection(
              title: 'Third-Party Services',
              content:
                  'SpendX uses the following third-party services, all under your control:\n\n'
                  '  \u2022  Google Sign-In: Authentication for Drive backup (optional)\n'
                  '  \u2022  Google Drive API: Encrypted backup storage (optional)\n'
                  '  \u2022  Google Gemini AI: Receipt scanning and AI chat (optional, on-demand)\n\n'
                  'No other third-party SDKs, analytics, ad networks, or tracking services are used.',
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'Last updated: April 4, 2026',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  final String title;
  final String content;

  const _PolicySection({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              content,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.6,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
