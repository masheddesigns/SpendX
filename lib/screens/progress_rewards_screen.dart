import 'package:flutter/material.dart';
import '../../services/gamification_service.dart';
import '../../shared/widgets/skeleton_loader.dart';

class ProgressRewardsScreen extends StatefulWidget {
  const ProgressRewardsScreen({super.key});

  @override
  State<ProgressRewardsScreen> createState() => _ProgressRewardsScreenState();
}

class _ProgressRewardsScreenState extends State<ProgressRewardsScreen> {
  bool _isLoading = true;
  int _xp = 0;
  double _progress = 0.0;
  int _streak = 0;
  int _totalTxns = 0;
  String _level = '';
  List<Achievement> _achievements = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final results = await Future.wait([
      GamificationService.instance.getXP(),
      GamificationService.instance.getLevelProgress(),
      GamificationService.instance.getCurrentStreak(),
      GamificationService.instance.getTotalTransactionCount(),
      GamificationService.instance.getUserLevel(),
      GamificationService.instance.getAchievements(),
    ]);

    if (mounted) {
      setState(() {
        _xp = results[0] as int;
        _progress = results[1] as double;
        _streak = results[2] as int;
        _totalTxns = results[3] as int;
        _level = results[4] as String;
        _achievements = results[5] as List<Achievement>;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Progress & Rewards'),
        centerTitle: true,
      ),
      body: _isLoading
          ? const SkeletonLoader(itemCount: 3, itemHeight: 100)
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // --- Overview Block ---
                _buildOverview(cs),

                const SizedBox(height: 32),

                // --- Achievements Grid ---
                Text(
                  'Achievements',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 16),
                _buildAchievementsGrid(cs),

                const SizedBox(height: 32),

                // --- Activity Timeline ---
                Text(
                  'Recent Activity',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 16),
                _buildActivityTimeline(cs),
              ],
            ),
    );
  }

  Widget _buildOverview(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Text(
            _level,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$_xp XP TOTAL',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.primary,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 20),
          // XP Bar
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 12,
              backgroundColor: cs.primary.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMetric('🔥', '$_streak', 'Streak'),
              _buildMetric('🗒️', '$_totalTxns', 'Transactions'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(String emoji, String value, String label) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 24)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildAchievementsGrid(ColorScheme cs) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 1, // Changed to 1 for better labels/progress bar space
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 2.8,
      ),
      itemCount: _achievements.length,
      itemBuilder: (context, index) {
        final ach = _achievements[index];
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ach.isUnlocked
                ? cs.primary.withValues(alpha: 0.08)
                : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: ach.isUnlocked
                  ? cs.primary.withValues(alpha: 0.3)
                  : cs.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              Text(
                ach.icon,
                style: TextStyle(
                  fontSize: 32,
                  color: Colors.black.withValues(alpha: ach.isUnlocked ? 1.0 : 0.4),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          ach.title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: ach.isUnlocked ? cs.onSurface : cs.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          ach.progressLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ach.description,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: ach.progress,
                        minHeight: 6,
                        backgroundColor: cs.outlineVariant.withValues(alpha: 0.3),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          ach.isUnlocked ? Colors.green : cs.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActivityTimeline(ColorScheme cs) {
    // Simplified timeline
    return Column(
      children: [
        _buildTimelineTile(
          cs,
          'Achievement Unlocked',
          'You reached a 7-day streak! 🔥',
          Icons.emoji_events_rounded,
          true,
        ),
        _buildTimelineTile(
          cs,
          'Budget Exceeded',
          'Food category went over budget yesterday.',
          Icons.warning_amber_rounded,
          false,
        ),
      ],
    );
  }

  Widget _buildTimelineTile(
    ColorScheme cs,
    String title,
    String subtitle,
    IconData icon,
    bool isPositive,
  ) {
    final color = isPositive ?Colors.green : Colors.orange;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
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
