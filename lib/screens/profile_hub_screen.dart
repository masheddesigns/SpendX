import 'package:flutter/material.dart';
import '../services/gamification_service.dart';
import '../services/financial_health_service.dart';
import '../services/auth_service.dart';
import '../utils/page_transitions.dart';
import 'financial_health_hub_screen.dart';
import 'progress_rewards_screen.dart';
import 'settings/profile_settings_screen.dart';
import 'insights_activity_screen.dart';
import '../services/games_integration_service.dart';
import '../services/insights_activity_service.dart';
import '../widgets/financial_report_card.dart';
import '../shared/widgets/app_page_route.dart';
import '../shared/widgets/app_tap_scale.dart';

class ProfileHubScreen extends StatefulWidget {
  const ProfileHubScreen({super.key});

  @override
  State<ProfileHubScreen> createState() => _ProfileHubScreenState();
}

class _ProfileHubScreenState extends State<ProfileHubScreen> {
  // Profile data
  String _userLevel = 'Bronze Saver 🥉';
  int _streakDays = 0;
  double _financialHealthScore = 0;
  double _healthScoreChange = 0;
  String _healthChangeReason = 'Initial calculation';
  String _bestCategory = 'Scanning...';
  String _worstCategory = 'Scanning...';
  String _dailyQuote =
      '"Beware of little expenses. A small leak will sink a great ship." — Benjamin Franklin';
  double _xpProgress = 0.0;
  double _projectedSavings = 0;
  double _projectedScore = 0;
  String _confidence = 'Low';
  bool _isBudgetAtRisk = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
    GamesIntegrationService.instance.signIn();
  }

  Future<void> _loadProfileData() async {
    try {
      final results = await Future.wait([
        GamificationService.instance.getUserLevel(),
        GamificationService.instance.getCurrentStreak(),
        GamificationService.instance.getDailyQuote(),
        FinancialHealthService.instance.calculateMetrics(),
        GamificationService.instance.getXPProgressToNextLevel(),
      ]);

      final metrics = results[3] as Map<String, dynamic>;
      final forecast = await InsightsActivityService.instance
          .getMonthlyForecast();

      if (!mounted) return;
      setState(() {
        _userLevel = results[0] as String;
        _streakDays = results[1] as int;
        _dailyQuote = results[2] as String;

        _financialHealthScore = (metrics['score'] as num?)?.toDouble() ?? 0.0;
        _healthScoreChange = (metrics['change'] as num?)?.toDouble() ?? 0.0;
        _healthChangeReason = metrics['reason'] as String? ?? 'Calculating...';
        _bestCategory = metrics['bestCategory'] as String? ?? 'N/A';
        _worstCategory = metrics['worstCategory'] as String? ?? 'N/A';

        _xpProgress = (results[4] as num?)?.toDouble() ?? 0.0;

        // Read from the new stable forecast contract.
        _projectedSavings =
            (forecast['monthlySpend'] as num?)?.toDouble() ?? 0.0;
        _isBudgetAtRisk =
            false; // Will be reintroduced once income data is stable.
        _confidence = 'Stable';

        _isLoading = false;
      });

      final projScore = await FinancialHealthService.instance
          .getProjectedMonthEndScore();
      if (!mounted) return;
      setState(() => _projectedScore = projScore);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final authService = AuthService.instance;
    final userEmail = authService.currentUser?.email ?? 'Offline Mode';
    final userName =
        authService.currentUser?.displayName ??
        (userEmail != 'Offline Mode'
            ? userEmail.split('@').first
            : 'Guest User');
    final memberSince = authService.memberSinceLabel ?? '';
    final isOnline = authService.isSignedIn;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Profile',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 24),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              AppPageRoute(builder: (_) => const ProfileSettingsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadProfileData,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  // 1. User Info Header
                  _ProfileHeader(
                    userName: userName,
                    userEmail: userEmail,
                    memberSince: memberSince,
                    isOnline: isOnline,
                  ),

                  const SizedBox(height: 24),

                  // 2. Financial Report Card (New Habit Anchor)
                  FinancialReportCard(
                    scoreChange: _healthScoreChange,
                    changeReason: _healthChangeReason,
                    bestCategory: _bestCategory,
                    worstCategory: _worstCategory,
                    onTap: () => Navigator.push(
                      context,
                      SlideFadeTransition(page: const InsightsActivityScreen()),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 3. Financial Health (Clickable Detailed Module)
                  _SectionHeader(
                    title: 'Health Breakdown',
                    onTap: () => Navigator.push(
                      context,
                      SlideFadeTransition(
                        page: const FinancialHealthHubScreen(),
                      ),
                    ),
                  ),
                  _FinancialHealthCard(
                    score: _financialHealthScore,
                    projectedScore: _projectedScore,
                    projectedSavings: _projectedSavings,
                    change: _healthScoreChange,
                    reason: _healthChangeReason,
                    onTap: () => Navigator.push(
                      context,
                      SlideFadeTransition(
                        page: const FinancialHealthHubScreen(),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 4. Intelligence & Insights
                  _SectionHeader(
                    title: 'Intelligence Hub',
                    onTap: () => Navigator.push(
                      context,
                      SlideFadeTransition(page: const InsightsActivityScreen()),
                    ),
                  ),
                  _InsightsCard(
                    onTap: () => Navigator.push(
                      context,
                      SlideFadeTransition(page: const InsightsActivityScreen()),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 4. Progress & Rewards (Gamification Hub)
                  _SectionHeader(
                    title: 'Progress & Rewards',
                    onTap: () => Navigator.push(
                      context,
                      SlideFadeTransition(page: const ProgressRewardsScreen()),
                    ),
                  ),
                  _ProgressCard(
                    level: _userLevel,
                    streak: _streakDays,
                    progress: _xpProgress,
                    onTap: () => Navigator.push(
                      context,
                      SlideFadeTransition(page: const ProgressRewardsScreen()),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 5. Daily Sustainability
                  _SustainabilityCard(
                    projectedSavings: _projectedSavings,
                    isAtRisk: _isBudgetAtRisk,
                    confidence: _confidence,
                  ),

                  const SizedBox(height: 16),

                  // 6. Daily Vision
                  _DailyVisionCard(quote: _dailyQuote),

                  const SizedBox(height: 48),
                ],
              ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  const _SectionHeader({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.2,
            ),
          ),
          TextButton(
            onPressed: onTap,
            child: const Text('View All', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final String userName;
  final String userEmail;
  final String memberSince;
  final bool isOnline;

  const _ProfileHeader({
    required this.userName,
    required this.userEmail,
    required this.memberSince,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 34,
          backgroundColor: cs.primaryContainer,
          child: Text(
            userName.isNotEmpty ? userName[0].toUpperCase() : 'S',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: cs.primary,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                userName,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                userEmail,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FinancialHealthCard extends StatelessWidget {
  final double score;
  final double change;
  final String reason;
  final double projectedScore;
  final double projectedSavings;
  final VoidCallback onTap;

  const _FinancialHealthCard({
    required this.score,
    required this.projectedScore,
    required this.projectedSavings,
    required this.change,
    required this.reason,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final daysRemaining =
        DateTime(now.year, now.month + 1, 0).day - now.day + 1;
    final dailyCap = (projectedSavings / daysRemaining).clamp(
      0.0,
      double.infinity,
    );

    return AppTapScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Financial Health Details',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        reason,
                        style: TextStyle(
                          fontSize: 12,
                          color: change >= 0 ? Colors.green : Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.primary,
                  ),
                  child: Center(
                    child: Text(
                      '${score.toInt()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _PredictiveMetric(
                  label: 'Projected (Month-End)',
                  value: projectedScore.toStringAsFixed(0),
                  color: cs.primary,
                ),
                _PredictiveMetric(
                  label: 'Daily Spend Cap',
                  value: '₹${dailyCap.toStringAsFixed(0)}',
                  color: cs.onSurface,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Helper widget for specific metrics
class _PredictiveMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _PredictiveMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _InsightsCard extends StatelessWidget {
  final VoidCallback onTap;
  const _InsightsCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppTapScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: cs.primary),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI Insights & Activity',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Analyze your behavior patterns',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: cs.primary.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final String level;
  final int streak;
  final double progress;
  final VoidCallback onTap;

  const _ProgressCard({
    required this.level,
    required this.streak,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppTapScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.stars_rounded, color: Colors.orange, size: 28),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        level,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '$streak day streak',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: cs.outlineVariant.withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SustainabilityCard extends StatelessWidget {
  final double projectedSavings;
  final bool isAtRisk;
  final String confidence;
  const _SustainabilityCard({
    required this.projectedSavings,
    required this.isAtRisk,
    required this.confidence,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isAtRisk ? Colors.red.withValues(alpha: 0.05) : cs.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: (isAtRisk ? Colors.red : cs.outlineVariant).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                isAtRisk ? Icons.warning_amber_rounded : Icons.eco_rounded,
                color: isAtRisk ? Colors.red : Colors.green,
                size: 24,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Sustainability Forecast',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: isAtRisk ? Colors.red : cs.primary,
                          ),
                        ),
                        _ConfidenceBadgeSmall(level: confidence),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isAtRisk
                          ? 'At this rate, you\'ll overspend this month.'
                          : 'On track to save ₹${projectedSavings.toStringAsFixed(0)} this month.',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConfidenceBadgeSmall extends StatelessWidget {
  final String level;
  const _ConfidenceBadgeSmall({required this.level});

  @override
  Widget build(BuildContext context) {
    Color color = Colors.grey;
    if (level == 'High') color = Colors.green;
    if (level == 'Medium') color = Colors.orange;
    if (level == 'Low') color = Colors.red;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        level,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// PROFILE CARD
// ═══════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════
// DAILY VISION QUOTE
// ═══════════════════════════════════════════════════════════════

class _DailyVisionCard extends StatelessWidget {
  final String quote;
  const _DailyVisionCard({required this.quote});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.format_quote_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                'Daily Vision',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '🔥 $quote',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: cs.onSurface.withValues(alpha: 0.85),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// STAT CARD (Streak / Level / Logs / Spent)
// ═══════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════
// FINANCIAL HEALTH CARD
// ═══════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════
// Insights & Activity Card (formerly AI Chat)
// ═══════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════
// Progress & Rewards CARD
// ═══════════════════════════════════════════════════════════════


// ═══════════════════════════════════════════════════════════════
// QUICK SETTINGS ROW
// ═══════════════════════════════════════════════════════════════

