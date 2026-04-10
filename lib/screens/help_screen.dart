import 'package:flutter/material.dart';
import 'package:spend_x/widgets/spendx_app_bar.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = <_GuideSectionData>[
      // ── Getting Started ─────────────────────────────────
      const _GuideSectionData(
        title: 'Getting Started',
        icon: Icons.rocket_launch_rounded,
        items: [
          _GuideItem(
            title: 'Dashboard Overview',
            body: 'The Home tab shows your financial summary (balance, income, expenses), '
                'Wrapped story bubbles for weekly/monthly/yearly summaries, '
                'and your recent transactions with infinite scroll.',
          ),
          _GuideItem(
            title: 'Bottom Navigation',
            body: 'Home: Dashboard and transactions\n'
                'Accounts: Bank accounts and balances\n'
                'Insights: Analytics, charts, and XP level\n'
                'Plan: Budgets and financial planning\n'
                'More: All tools, settings, and features',
          ),
        ],
      ),

      // ── Adding Transactions ─────────────────────────────
      const _GuideSectionData(
        title: 'Adding Transactions',
        icon: Icons.add_card_rounded,
        items: [
          _GuideItem(
            title: 'Quick Add',
            body: 'Tap the "Add Transaction" button on the Home tab. '
                'Choose expense or income, enter amount, select category, '
                'and optionally add notes and payment method.',
          ),
          _GuideItem(
            title: 'AI Bill Scanning',
            body: 'Use the AI Assistant (More > AI Assistant) to scan receipts. '
                'Take a photo or pick an image — Gemini AI extracts the merchant, amount, and date.',
          ),
          _GuideItem(
            title: 'SMS Auto-Import',
            body: 'Go to More > SMS Import to scan your bank SMS messages. '
                'SpendX detects transaction amounts, merchants, and dates from bank alerts. '
                'Imported transactions go to the Review Queue for approval.',
          ),
          _GuideItem(
            title: 'Smart Categories',
            body: 'SpendX has 19 default categories covering Indian spending patterns — '
                'food, transport, groceries, bills, rent, shopping, health, and more. '
                'You can add custom categories from Settings > Categories.',
          ),
        ],
      ),

      // ── Smart Import ────────────────────────────────────
      const _GuideSectionData(
        title: 'Smart Import',
        icon: Icons.auto_awesome_rounded,
        items: [
          _GuideItem(
            title: 'Supported Formats',
            body: 'CSV, TSV, JSON, Markdown tables, HTML tables, and ZIP archives. '
                'Works with exports from Notion, Google Sheets, Excel, bank statements, and more.',
          ),
          _GuideItem(
            title: 'How It Works',
            body: '1. Go to Settings > Database Tools > Smart Import\n'
                '2. Pick a file or share one from another app\n'
                '3. SpendX auto-detects columns (amount, date, category, description)\n'
                '4. Review the preview and uncheck rows you don\'t want\n'
                '5. Tap "Import" to add transactions',
          ),
          _GuideItem(
            title: 'Notion Export',
            body: 'In Notion, open your expense database > "..." menu > Export > CSV or Markdown. '
                'On Android, you can share the exported ZIP directly to SpendX.',
          ),
          _GuideItem(
            title: 'Share-to-Import',
            body: 'From any app (Notion, Files, Google Sheets, WhatsApp), '
                'share a supported file and select SpendX. '
                'The Smart Import screen opens automatically with the file parsed.',
          ),
        ],
      ),

      // ── Salary Tracking ─────────────────────────────────
      const _GuideSectionData(
        title: 'Income & Salary',
        icon: Icons.account_balance_wallet_rounded,
        items: [
          _GuideItem(
            title: 'Adding an Income Source',
            body: 'Go to More > Income & Salary > Add Income Source.\n\n'
                'Choose employment type:\n'
                '  \u2022  Full-time: Traditional salaried job\n'
                '  \u2022  Part-time: Reduced hours employment\n'
                '  \u2022  Freelance: Client/project-based work\n'
                '  \u2022  Contract: Fixed-term engagement\n\n'
                'Then select your pay cycle: Monthly, Weekly, Bi-weekly, Daily, or Per Project (freelance only).',
          ),
          _GuideItem(
            title: 'Pay Cycles',
            body: 'SpendX adapts to how you get paid:\n\n'
                '  \u2022  Monthly: Fixed salary once a month\n'
                '  \u2022  Weekly: Rate \u00d7 ~4.33 per month\n'
                '  \u2022  Bi-weekly: Rate \u00d7 ~2.17 per month\n'
                '  \u2022  Daily: Rate \u00d7 working days (Mon-Fri)\n'
                '  \u2022  Per Project: No fixed amount, track as payments come in\n\n'
                'You can log multiple payments per month for any cycle.',
          ),
          _GuideItem(
            title: 'Payment Status',
            body: 'Each month has one of 5 statuses:\n\n'
                '  \u2022  Pending: Awaiting payment\n'
                '  \u2022  Partial: Some payment received\n'
                '  \u2022  Paid: Full payment received\n'
                '  \u2022  Overdue: Past due date, not fully paid\n'
                '  \u2022  On Hold: You flagged it (client dispute, delay)\n\n'
                'On-hold months are excluded from reliability scoring.',
          ),
          _GuideItem(
            title: 'Employer Reliability',
            body: 'SpendX computes a reliability score:\n'
                '  \u2022  60% weight: On-time payment rate\n'
                '  \u2022  20% weight: Average delay penalty\n'
                '  \u2022  20% weight: Longest delay streak penalty\n\n'
                'View this in the company dashboard. On-hold months are excluded.',
          ),
          _GuideItem(
            title: 'Salary Reports',
            body: 'Export salary data as CSV or PDF from Database Tools. '
                'Reports include payment history, delay analysis, and company-wise summaries.',
          ),
        ],
      ),

      // ── Loans & Credit ──────────────────────────────────
      const _GuideSectionData(
        title: 'Loans & Credit Cards',
        icon: Icons.account_balance_rounded,
        items: [
          _GuideItem(
            title: 'Loan Tracking',
            body: 'Add loans with amount, interest rate, EMI, and tenure. '
                'Record installment payments and track remaining balance. '
                'SpendX calculates paid vs. remaining automatically.',
          ),
          _GuideItem(
            title: 'Credit Cards',
            body: 'Track credit card spending limits, outstanding balance, and EMI plans. '
                'Credit cards appear as payment methods when adding transactions.',
          ),
          _GuideItem(
            title: 'Lend & Borrow',
            body: 'Record money you\'ve lent to others or borrowed. '
                'Track partial repayments and see who owes what at a glance.',
          ),
        ],
      ),

      // ── Goals ───────────────────────────────────────────
      const _GuideSectionData(
        title: 'Savings Goals',
        icon: Icons.flag_rounded,
        items: [
          _GuideItem(
            title: 'Creating Goals',
            body: 'Set a target amount and optional deadline. '
                'Examples: Emergency fund, vacation, new phone, wedding.',
          ),
          _GuideItem(
            title: 'Tracking Progress',
            body: 'Log contributions as you save. '
                'The progress bar and percentage update in real-time. '
                'Completed goals earn +20 XP.',
          ),
        ],
      ),

      // ── Backup & Sync ──────────────────────────────────
      const _GuideSectionData(
        title: 'Backup & Sync',
        icon: Icons.backup_rounded,
        items: [
          _GuideItem(
            title: 'Google Drive Backup',
            body: 'Sign in with Google in the Backup Hub (More > Backup & Sync). '
                'Your data is encrypted on-device with AES-256 before upload. '
                'Backups go to your personal Drive appData folder.',
          ),
          _GuideItem(
            title: 'Auto Backup',
            body: 'Enable auto-backup to save automatically when you add or edit data. '
                'Choose interval: 1 hour, 6 hours, or 24 hours. '
                'Runs silently in the background.',
          ),
          _GuideItem(
            title: 'Multi-Device Sync',
            body: 'Sign into the same Google account on multiple devices. '
                'Enable auto-restore to pull the latest backup on launch. '
                'The encryption key is derived from your Google email, so it works across devices.',
          ),
          _GuideItem(
            title: 'Force Restore',
            body: 'If auto-restore skips (because local data is newer), '
                'use "Force Restore" in the Backup Hub to overwrite local data with the cloud backup.',
          ),
        ],
      ),

      // ── Export & Database Tools ─────────────────────────
      const _GuideSectionData(
        title: 'Export & Database Tools',
        icon: Icons.import_export_rounded,
        items: [
          _GuideItem(
            title: 'Export Options',
            body: 'Settings > Database Tools offers:\n'
                '  \u2022  Full backup (JSON) — complete app data\n'
                '  \u2022  Transactions CSV — spreadsheet-ready\n'
                '  \u2022  Transactions JSON — structured data\n'
                '  \u2022  Salary Report CSV/PDF — payment history\n'
                '  \u2022  Reminders CSV — due reminders',
          ),
          _GuideItem(
            title: 'Import Options',
            body: '  \u2022  Smart Import — auto-detect from any format\n'
                '  \u2022  Manual CSV Import — map columns yourself\n'
                '  \u2022  Full Backup Restore — from spendx_backup.json',
          ),
        ],
      ),

      // ── Gamification ────────────────────────────────────
      const _GuideSectionData(
        title: 'Levels & Rewards',
        icon: Icons.emoji_events_rounded,
        items: [
          _GuideItem(
            title: 'XP System',
            body: 'Earn XP by using SpendX:\n'
                '  \u2022  +2 XP per transaction logged\n'
                '  \u2022  +5 XP per day of current streak\n'
                '  \u2022  +20 XP per completed goal\n'
                '  \u2022  +8 XP per budget respected\n'
                '  \u2022  +10 XP per clean day',
          ),
          _GuideItem(
            title: 'Tiers',
            body: 'Bronze: Level 1-4\n'
                'Silver: Level 5-9\n'
                'Gold: Level 10-14\n'
                'Platinum: Level 15-19\n'
                'Diamond: Level 20+\n\n'
                'Your tier updates automatically in the Insights tab.',
          ),
          _GuideItem(
            title: 'Wrapped Summaries',
            body: 'SpendX generates Spotify-style financial summaries:\n'
                '  \u2022  Weekly: Top categories, total spent, highlights\n'
                '  \u2022  Monthly: Full month breakdown with comparisons\n'
                '  \u2022  Yearly: Annual trends with 12-month chart\n\n'
                'Wrapped bubbles appear on the Home dashboard and auto-dismiss after 5 days.',
          ),
        ],
      ),

      // ── Settings ────────────────────────────────────────
      const _GuideSectionData(
        title: 'Settings & Customization',
        icon: Icons.settings_rounded,
        items: [
          _GuideItem(
            title: 'Theme & Appearance',
            body: 'Choose light/dark/system mode and pick a theme color. '
                'Multiple color themes available (blue, teal, purple, orange, etc.).',
          ),
          _GuideItem(
            title: 'Currency',
            body: 'Change your display currency from Settings > Currency. '
                'Supports INR, USD, EUR, GBP, and many regional formats.',
          ),
          _GuideItem(
            title: 'Notifications',
            body: 'Configure reminders for recurring payments, loan EMIs, '
                'and custom alerts from Settings > Notifications.',
          ),
          _GuideItem(
            title: 'Clear Data',
            body: 'Selectively clear individual data types (expenses, income, salary, '
                'loans, goals, accounts) or clear everything from Settings > Clear Data.',
          ),
        ],
      ),

      // ── Troubleshooting ─────────────────────────────────
      const _GuideSectionData(
        title: 'Troubleshooting',
        icon: Icons.build_circle_rounded,
        items: [
          _GuideItem(
            title: 'Balance Shows Wrong Amount',
            body: 'The dashboard shows the last 30 days of income and expenses. '
                'If you recently imported old data, it may not reflect in the summary. '
                'Check the Accounts tab for your actual account balances.',
          ),
          _GuideItem(
            title: 'Backup Not Working',
            body: 'Ensure you\'re signed into Google in the Backup Hub. '
                'Check your internet connection and Drive storage. '
                'Try "Force Backup" if auto-backup seems stuck.',
          ),
          _GuideItem(
            title: 'SMS Import Missing Transactions',
            body: 'SpendX looks for specific bank SMS patterns. '
                'Some banks use non-standard formats. '
                'You can manually add missing transactions or use Smart Import with a bank CSV export.',
          ),
          _GuideItem(
            title: 'Smart Import Shows 0 Rows',
            body: 'Check that your file has a header row with recognizable column names '
                '(like "Amount", "Date", "Category"). For Notion ZIP exports, '
                'SpendX automatically extracts the CSV from nested ZIP archives.',
          ),
          _GuideItem(
            title: 'App Feels Slow',
            body: 'If you have thousands of transactions, pagination keeps the Home tab fast. '
                'Scroll down to load more. If the app is still sluggish, '
                'try clearing build cache or reinstalling.',
          ),
        ],
      ),
    ];

    return Scaffold(
      appBar: const SpendXAppBar(title: 'Help & User Guide'),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const _GuideBanner();
            }

            final section = sections[index - 1];
            return _GuideSection(section: section);
          },
          separatorBuilder: (_, index) => SizedBox(height: index == 0 ? 24 : 0),
          itemCount: sections.length + 1,
        ),
      ),
    );
  }
}

class _GuideBanner extends StatelessWidget {
  const _GuideBanner();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primary.withValues(alpha: 0.22),
            colorScheme.tertiary.withValues(alpha: 0.18),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.menu_book_rounded, color: colorScheme.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SpendX User Guide',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Complete guide covering all features — transactions, salary tracking, '
                  'smart import, backup, gamification, and more.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideSection extends StatelessWidget {
  final _GuideSectionData section;

  const _GuideSection({required this.section});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(section.icon, color: colorScheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          for (var index = 0; index < section.items.length; index++) ...[
            _GuideTile(item: section.items[index]),
            if (index < section.items.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _GuideTile extends StatelessWidget {
  final _GuideItem item;

  const _GuideTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            item.body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideSectionData {
  final String title;
  final IconData icon;
  final List<_GuideItem> items;

  const _GuideSectionData({
    required this.title,
    required this.icon,
    required this.items,
  });
}

class _GuideItem {
  final String title;
  final String body;

  const _GuideItem({required this.title, required this.body});
}
