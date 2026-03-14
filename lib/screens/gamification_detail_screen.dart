import 'package:flutter/material.dart';
import '../services/gamification_service.dart';
import '../services/app_session_service.dart';
import '../widgets/animated_widgets.dart';
import '../widgets/settings_tile.dart';
import '../widgets/spendx_app_bar.dart';

import '../utils/app_format.dart';
import 'usage_analytics_screen.dart';
import '../utils/page_transitions.dart';

class GamificationDetailScreen extends StatelessWidget {
  const GamificationDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: const SpendXAppBar(
        title: 'Rewards & Activity',
      ),

      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildLevelCard(context),
          const SizedBox(height: 16),
          _sectionHeader(context, '📱 App Activity'),
          _buildActivityCard(context),
          const SizedBox(height: 24),
          _sectionHeader(context, '🏆 Achievements'),
          _buildAchievementsList(context),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _buildLevelCard(BuildContext context) {
    return FutureBuilder<String>(
      future: GamificationService.instance.getUserLevel(),
      builder: (context, snapshot) {
        final level = snapshot.data ?? 'Bronze Saver 🥉';
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,

            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            children: [
              const Icon(Icons.stars, color: Colors.white, size: 48),
              const SizedBox(height: 16),
              Text(
                level,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Keep tracking to unlock higher tiers!',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActivityCard(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _fetchUsageData(),
      builder: (context, snapshot) {
        final data = snapshot.data ?? {
          'totalTime': '---',
          'sessions': 0,
          'avgSession': '---',
          'activeDays': 0,
        };

        return AnimatedScaleWrapper(
          onTap: () {
            Navigator.push(context, SlideFadeTransition(page: const UsageAnalyticsScreen()));
          },
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _activityItem(context, 'Total usage', data['totalTime'], Icons.timer),
                    _activityItem(context, 'Sessions', '${data['sessions']}', Icons.bolt),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(color: Colors.white12),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _activityItem(context, 'Avg session', data['avgSession'], Icons.av_timer),
                    _activityItem(context, 'Usage streak', '${data['longestStreak']} Days', Icons.local_fire_department),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Tap for details',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.primary, size: 16),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _activityItem(BuildContext context, String label, String value, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary, size: 14),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildAchievementsList(BuildContext context) {
    return Column(
      children: [
        SettingsTile(
          icon: Icons.local_fire_department,
          color: Colors.orange,
          title: 'Loyal Tracker',
          subtitle: 'Maintained a 7-day streak',
          onTap: () {},
          trailing: const Icon(Icons.check_circle, color: Colors.green),

        ),
        const SizedBox(height: 10),
        SettingsTile(
          icon: Icons.savings,
          color: Colors.green,

          title: 'Master Saver',
          subtitle: 'Logged 100+ transactions',
          onTap: () {},
          trailing: Icon(Icons.lock, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
        ),
        const SizedBox(height: 10),
        SettingsTile(
          icon: Icons.auto_awesome_motion,
          color: Theme.of(context).colorScheme.secondary,

          title: 'Feature Explorer',
          subtitle: 'Used all SpendX modules',
          onTap: () {},
          trailing: Icon(Icons.lock, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
        ),
        const SizedBox(height: 10),
        SettingsTile(
          icon: Icons.psychology,
          color: Theme.of(context).colorScheme.primary,

          title: 'AI Scholar',
          subtitle: 'Interacted with AI Assistant 10+ times',
          onTap: () {},
          trailing: Icon(Icons.lock, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
        ),
        const SizedBox(height: 10),
        SettingsTile(
          icon: Icons.health_and_safety,
          color: Colors.green,

          title: 'Health Guru',
          subtitle: 'Achieved a Financial Health score of 90+',
          onTap: () {},
          trailing: Icon(Icons.lock, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
        ),
        const SizedBox(height: 10),
        SettingsTile(
          icon: Icons.wb_twilight,
          color: Colors.orange,

          title: 'Early Bird',
          subtitle: 'Logged a transaction before 8 AM',
          onTap: () {},
          trailing: Icon(Icons.lock, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
        ),
      ],
    );
  }

  Future<Map<String, dynamic>> _fetchUsageData() async {
    final totalSec = await AppSessionService.instance.getTotalUsageSeconds();
    final sessions = await AppSessionService.instance.getSessionCount();
    final avgSec = await AppSessionService.instance.getAverageSessionSeconds();
    final activeDays = await AppSessionService.instance.getActiveUsageDays();
    final longestStreak = await AppSessionService.instance.getLongestUsageStreak();

    return {
      'totalTime': _formatDuration(totalSec),
      'sessions': sessions,
      'avgSession': _formatDuration(avgSec.toInt()),
      'activeDays': activeDays,
      'longestStreak': longestStreak,
    };
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${(seconds / 60).floor()}m ${seconds % 60}s';
    return '${(seconds / 3600).floor()}h ${((seconds % 3600) / 60).floor()}m';
  }
}
