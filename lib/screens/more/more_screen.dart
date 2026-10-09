import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/alerts/providers/alert_providers.dart';
import '../../shared/widgets/app_page_route.dart';
import '../../shared/widgets/spendx_glass.dart';
import '../../theme/app_theme.dart';
import '../ai_chat_screen.dart';
import '../data_health_screen.dart';
import '../feedback_screen.dart';
import '../gamification_detail_screen.dart';
import '../insights/insights_tab.dart';
import '../notifications_inbox_screen.dart';
import '../reports_screen.dart';
import '../settings/backup_hub_screen.dart';
import '../settings/profile_settings_screen.dart';
import '../smart_import_screen.dart';

/// SpendX 2.0 System & Intelligence Workspace (More Screen).
///
/// Implements Section 7 of C15-B:
/// - Cohesive grouped Liquid Glass surfaces for related functional areas
/// - Direct canvas headers with strong typography
/// - Preserves 100% of existing Intelligence, Insights, and System actions
/// - Translucent icon pills, clear subtitles, and interactive feedback
/// - Generous bottom clearance above floating navigation bar
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertCount = ref.watch(activeAlertsProvider).valueOrNull?.length ?? 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // ── Group 1: Intelligence & Ingestion ──────────────────────
        const SliverToBoxAdapter(
          child: SpendXSectionHeader(
            title: 'Intelligence & Import',
            padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _MoreGlassRow(
                    icon: Icons.auto_awesome_rounded,
                    iconColor: AppTheme.primaryBlue,
                    title: 'AI Financial Assistant',
                    subtitle: 'Ask questions about your finances & trends',
                    isDark: isDark,
                    onTap: () => _push(context, const AiChatScreen()),
                  ),
                  _buildDivider(isDark),
                  _MoreGlassRow(
                    icon: Icons.notifications_rounded,
                    iconColor: const Color(0xFFF59E0B),
                    title: 'Notifications & Alerts',
                    subtitle: 'Due reminders, recurring bills, and alerts',
                    badgeCount: alertCount > 0 ? alertCount : null,
                    badgeColor: AppTheme.semanticExpense,
                    isDark: isDark,
                    onTap: () => _push(context, const NotificationsInboxScreen()),
                  ),
                  _buildDivider(isDark),
                  _MoreGlassRow(
                    icon: Icons.upload_file_rounded,
                    iconColor: const Color(0xFF0EA5E9),
                    title: 'Smart Import',
                    subtitle: 'Import CSV bank statements or shared receipts',
                    isDark: isDark,
                    onTap: () => _push(context, const SmartImportScreen()),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 14)),

        // ── Group 2: Insights & Engagement ─────────────────────────
        const SliverToBoxAdapter(
          child: SpendXSectionHeader(
            title: 'Insights & Activity',
            padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _MoreGlassRow(
                    icon: Icons.auto_graph_rounded,
                    iconColor: AppTheme.primaryBlue,
                    title: 'Financial Insights',
                    subtitle: 'Health score, net worth evolution, category breakdown',
                    isDark: isDark,
                    onTap: () => _push(context, const _InsightsScreen()),
                  ),
                  _buildDivider(isDark),
                  _MoreGlassRow(
                    icon: Icons.bar_chart_rounded,
                    iconColor: const Color(0xFF0D9488),
                    title: 'Reports & Cash Flow',
                    subtitle: 'Income vs expense breakdown, monthly cash flow analysis',
                    isDark: isDark,
                    onTap: () => _push(context, const ReportsScreen()),
                  ),
                  _buildDivider(isDark),
                  _MoreGlassRow(
                    icon: Icons.emoji_events_rounded,
                    iconColor: const Color(0xFFF59E0B),
                    title: 'Rewards & Daily Streaks',
                    subtitle: 'Financial consistency milestones and achievements',
                    isDark: isDark,
                    onTap: () => _push(context, const GamificationDetailScreen()),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 14)),

        // ── Group 3: System & Safety ───────────────────────────────
        const SliverToBoxAdapter(
          child: SpendXSectionHeader(
            title: 'System & Safety',
            padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SpendXGlassSurface(
              level: SpendXGlassLevel.base,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _MoreGlassRow(
                    icon: Icons.settings_rounded,
                    iconColor: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    title: 'App Settings',
                    subtitle: 'Categories, theme preferences, currency, notifications',
                    isDark: isDark,
                    onTap: () => _push(context, const ProfileSettingsScreen()),
                  ),
                  _buildDivider(isDark),
                  _MoreGlassRow(
                    icon: Icons.cloud_sync_rounded,
                    iconColor: const Color(0xFF3B82F6),
                    title: 'Backup & Cloud Sync',
                    subtitle: 'Encrypted Google Drive and local JSON backups',
                    isDark: isDark,
                    onTap: () => _push(context, const BackupHubScreen()),
                  ),
                  _buildDivider(isDark),
                  _MoreGlassRow(
                    icon: Icons.health_and_safety_outlined,
                    iconColor: const Color(0xFF10B981),
                    title: 'Data Health & Integrity',
                    subtitle: 'Audit ledger balance parity and schema diagnostics',
                    isDark: isDark,
                    onTap: () => _push(context, const DataHealthScreen()),
                  ),
                  _buildDivider(isDark),
                  _MoreGlassRow(
                    icon: Icons.chat_bubble_outline_rounded,
                    iconColor: Colors.teal,
                    title: 'Feedback & Support',
                    subtitle: 'Share feedback, report issues, or rate the app',
                    isDark: isDark,
                    onTap: () => _push(context, const FeedbackScreen()),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Generous bottom clearance above floating navigation bar
        const SliverToBoxAdapter(child: SizedBox(height: 110)),
      ],
    );
  }

  static Widget _buildDivider(bool isDark) {
    return Container(
      margin: const EdgeInsets.only(left: 64, right: 16),
      height: 0.5,
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.push(
      context,
      AppPageRoute(builder: (_) => screen),
    );
  }
}

// ── More Glass Row Item ──────────────────────────────────────────

class _MoreGlassRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final int? badgeCount;
  final Color? badgeColor;
  final bool isDark;
  final VoidCallback onTap;

  const _MoreGlassRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.badgeCount,
    this.badgeColor,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            // Translucent Glass Icon Pill
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: isDark ? 0.16 : 0.12),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: iconColor.withValues(alpha: isDark ? 0.28 : 0.20),
                  width: 0.5,
                ),
              ),
              child: Icon(icon, size: 19, color: iconColor),
            ),
            const SizedBox(width: 12),

            // Title & Subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w400,
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),

            // Optional Badge Pill or Chevron
            if (badgeCount != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                decoration: BoxDecoration(
                  color: (badgeColor ?? AppTheme.primaryBlue).withValues(alpha: isDark ? 0.25 : 0.15),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: (badgeColor ?? AppTheme.primaryBlue).withValues(alpha: isDark ? 0.5 : 0.3),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  '$badgeCount',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: badgeColor ?? AppTheme.primaryBlue,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],

            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Standalone Insights Screen wrapper ───────────────────────────

class _InsightsScreen extends StatelessWidget {
  const _InsightsScreen();

  @override
  Widget build(BuildContext context) {
    return SpendXScaffold(
      extendBody: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Insights',
          style: AppTextStyles.heading.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [InsightsTab(embedded: true)],
      ),
    );
  }
}
