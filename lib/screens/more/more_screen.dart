import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/review_queue/providers/review_providers.dart';
import '../../features/salary/screens/salary_screen.dart';
import '../ai_chat_screen.dart';
import '../credit_card_screen.dart';
import '../goals/goals_screen.dart';
import '../lending/lending_screen.dart';
import '../loans/loans_screen.dart';
import '../recurring/recurring_payments_screen.dart';
import '../reports_screen.dart';
import '../review/review_queue_screen.dart';
import '../financial_health_screen.dart';
import '../gamification_detail_screen.dart';
import '../settings/profile_settings_screen.dart';
import '../settings/backup_hub_screen.dart';
import '../feedback_screen.dart';
import '../data_health_screen.dart';
import '../../shared/widgets/app_page_route.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewCount = ref.watch(reviewQueueCountProvider);
    final cs = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // ── AI & Intelligence ─────────────────────────────────────────
        _SectionHeader(title: 'Intelligence'),
        _MoreTile(
          icon: Icons.auto_awesome_rounded,
          title: 'AI Assistant',
          subtitle: 'Ask about your finances',
          iconColor: cs.primary,
          onTap: () => _push(context, const AiChatScreen()),
        ),
        _MoreTile(
          icon: Icons.rate_review_rounded,
          title: 'Review Queue',
          subtitle: 'Approve imported transactions',
          iconColor: cs.tertiary,
          badge: reviewCount.when(
            data: (count) => count > 0 ? count : null,
            loading: () => null,
            error: (_, _) => null,
          ),
          onTap: () => _push(context, const ReviewQueueScreen()),
        ),

        const Divider(height: 32, indent: 16, endIndent: 16),

        // ── Financial Tools ───────────────────────────────────────────
        _SectionHeader(title: 'Financial Tools'),
        _MoreTile(
          icon: Icons.account_balance_wallet_rounded,
          title: 'Income & Salary',
          subtitle: 'Track salary, employer reliability',
          iconColor: const Color(0xFF3B82F6),
          onTap: () => _push(context, const SalaryScreen()),
        ),
        _MoreTile(
          icon: Icons.repeat_rounded,
          title: 'Recurring Payments',
          subtitle: 'Rent, subscriptions, auto-logged',
          iconColor: const Color(0xFF8B5CF6),
          onTap: () => _push(context, const RecurringPaymentsScreen()),
        ),
        _MoreTile(
          icon: Icons.flag_rounded,
          title: 'Goals',
          subtitle: 'Savings targets, spending limits',
          iconColor: const Color(0xFF22C55E),
          onTap: () => _push(context, const GoalsScreen()),
        ),
        _MoreTile(
          icon: Icons.credit_card_rounded,
          title: 'Credit Cards',
          subtitle: 'Cards, EMI, outstanding',
          iconColor: const Color(0xFF8B5CF6),
          onTap: () => _push(context, const CreditCardScreen()),
        ),
        _MoreTile(
          icon: Icons.account_balance_rounded,
          title: 'Loans',
          subtitle: 'Track loan repayments',
          iconColor: const Color(0xFFF59E0B),
          onTap: () => _push(context, const LoansScreen()),
        ),
        _MoreTile(
          icon: Icons.swap_horiz_rounded,
          title: 'Lend & Borrow',
          subtitle: 'Track money given & owed',
          iconColor: const Color(0xFF10B981),
          onTap: () => _push(context, const LendingScreen()),
        ),
        _MoreTile(
          icon: Icons.bar_chart_rounded,
          title: 'Reports',
          subtitle: 'Monthly & category reports',
          iconColor: const Color(0xFF0EA5E9),
          onTap: () => _push(context, const ReportsScreen()),
        ),

        const Divider(height: 32, indent: 16, endIndent: 16),

        // ── Insights & Rewards ───────────────────────────────────────
        _SectionHeader(title: 'Insights & Rewards'),
        _MoreTile(
          icon: Icons.favorite_rounded,
          title: 'Financial Health',
          subtitle: 'Your discipline score & breakdown',
          iconColor: const Color(0xFF22C55E),
          onTap: () => _push(context, const FinancialHealthScreen()),
        ),
        _MoreTile(
          icon: Icons.emoji_events_rounded,
          title: 'Rewards & Activity',
          subtitle: 'Achievements, levels, daily streaks',
          iconColor: const Color(0xFFF59E0B),
          onTap: () => _push(context, const GamificationDetailScreen()),
        ),

        const Divider(height: 32, indent: 16, endIndent: 16),

        // ── App Settings ──────────────────────────────────────────────
        _SectionHeader(title: 'Settings'),
        _MoreTile(
          icon: Icons.settings_rounded,
          title: 'Settings',
          subtitle: 'Categories, budgets, notifications',
          iconColor: cs.onSurfaceVariant,
          onTap: () => _push(context, const ProfileSettingsScreen()),
        ),
        _MoreTile(
          icon: Icons.cloud_sync_rounded,
          title: 'Backup & Sync',
          subtitle: 'Google Drive backup',
          iconColor: const Color(0xFF3B82F6),
          onTap: () => _push(context, const BackupHubScreen()),
        ),
        _MoreTile(
          icon: Icons.chat_bubble_outline_rounded,
          title: 'Feedback & Support',
          subtitle: 'Rate, share, report bugs',
          iconColor: Colors.teal,
          onTap: () => _push(context, const FeedbackScreen()),
        ),
        _MoreTile(
          icon: Icons.health_and_safety_outlined,
          title: 'Data Health',
          subtitle: 'Audit data accuracy',
          iconColor: const Color(0xFF22C55E),
          onTap: () => _push(context, const DataHealthScreen()),
        ),
      ],
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.push(
      context,
      AppPageRoute(builder: (_) => screen),
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color iconColor;
  final VoidCallback onTap;
  final int? badge;

  const _MoreTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.iconColor,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: badge != null
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$badge',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onError,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : Icon(
              Icons.chevron_right_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      onTap: onTap,
    );
  }
}
