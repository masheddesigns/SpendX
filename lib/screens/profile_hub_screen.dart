import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../widgets/spendx_app_bar.dart';
import '../widgets/app_button.dart';
import 'package:flutter/services.dart';
import '../services/database_helper.dart';
import 'settings/currency_selection_screen.dart';
import 'package:provider/provider.dart';
import '../widgets/custom_snackbar.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';

import '../services/gamification_service.dart';
import '../utils/app_format.dart';
import 'ai_chat_screen.dart';
import 'net_worth_screen.dart';
import 'settings/notification_settings_screen.dart';
import 'settings/feature_toggles_screen.dart';
import 'settings/category_management_screen.dart';
import 'expense/add_expense_screen.dart';
import 'reports/monthly_report_screen.dart';
import '../services/transaction_service.dart';
import '../widgets/analytics/daily_spending_heatmap.dart';
import 'help_screen.dart';
import 'reports_screen.dart';
import 'settings/backup_hub_screen.dart';
import 'settings/budget_management_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'about_screen.dart';
import '../widgets/settings_tile.dart';
import '../widgets/animated_widgets.dart';
import '../utils/page_transitions.dart';
import 'gamification_detail_screen.dart';
import '../services/financial_health_service.dart';
import 'financial_health_screen.dart';

class ProfileHubScreen extends StatefulWidget {
  const ProfileHubScreen({super.key});

  @override
  State<ProfileHubScreen> createState() => _ProfileHubScreenState();
}

class _ProfileHubScreenState extends State<ProfileHubScreen> {


  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Text(
                'Profile & Settings',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Habit Stats
                  _buildHighlightsRow(context),
                  const SizedBox(height: 16),
                  
                  // Daily Quote & Join Date
                  FutureBuilder<Map<String, dynamic>>(
                    future: _fetchExtendedStats(),
                    builder: (context, snapshot) {
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 600),
                        transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                        child: !snapshot.hasData
                          ? const SizedBox.shrink(key: ValueKey('empty_quote'))
                          : Container(
                              key: const ValueKey('loaded_quote'),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainer,
                                border: Border.all(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05)),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.calendar_today, color: Theme.of(context).colorScheme.primary, size: 16),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Tracking since ${snapshot.data!["joinDate"]}',
                                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w600),
                                      ),
                                      const Spacer(),
                                      Text(
                                        '${snapshot.data!["activeDays"]} Active Days',
                                        style: TextStyle(color: Theme.of(context).colorScheme.tertiary, fontSize: 13, fontWeight: FontWeight.w600),
                                      ),
                                    ],
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Divider(color: Colors.white12),
                                  ),
                                    Text(
                                      snapshot.data!['quote'] as String,
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurface,
                                        fontSize: 14,
                                        height: 1.5,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),

                  // AI Tools section
                  _sectionHeader(context, 'AI Tools'),
                  SettingsTile(
                    icon: Icons.auto_awesome,
                    color: Theme.of(context).colorScheme.primary,
                    title: 'AI Chat Assistant',
                    subtitle: 'Ask about your spending, budgets & saving tips',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiChatScreen())),
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.analytics,
                    color: Theme.of(context).colorScheme.tertiary,
                    title: 'Monthly Financial Report',
                    subtitle: 'Your contextual financial analysis',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MonthlyReportScreen())),
                  ),
                  const SizedBox(height: 10),
                  _sectionHeader(context, 'Financial Reports'),
                  SettingsTile(
                    icon: Icons.bar_chart_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    title: 'Detailed Reports',
                    subtitle: 'Income, expense, credit & fuel charts',
                    onTap: () => Navigator.push(context, SlideFadeTransition(page: const ReportsScreen())),
                  ),
                  const SizedBox(height: 10),
                  const SizedBox(height: 10),

                  // Wealth section
                  _sectionHeader(context, 'Wealth & Accounts'),
                  SettingsTile(
                    icon: Icons.add_circle_outline,
                    color: Theme.of(context).colorScheme.primary,
                    title: 'Quick Add Transaction',
                    subtitle: 'Manually log a new expense or income',
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AddExpenseScreen(initialType: 'expense'),
                        ),
                      );
                      if (result == true) {
                        setState(() {}); // Refresh stats if needed
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.account_balance,
                    color: Theme.of(context).colorScheme.primary,
                    title: 'Net Worth',
                    subtitle: 'Bank accounts, investments & liabilities',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NetWorthScreen())),
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.account_balance_wallet_rounded,
                    color: Theme.of(context).colorScheme.secondary,
                    title: 'Category Budgets',
                    subtitle: 'Set monthly limits for food, fuel & more',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetManagementScreen())),
                  ),
                  const SizedBox(height: 10),

                  // Data & Backup section
                  _sectionHeader(context, 'Data & Backups'),
                  SettingsTile(
                    icon: Icons.history_edu_outlined,
                    color: Theme.of(context).colorScheme.secondary,
                    title: 'Backup & Restore Hub',
                    subtitle: 'Local snapshots & Cloud sync',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupHubScreen())),
                  ),
                  const SizedBox(height: 10),

                  const SizedBox(height: 10),

                  // Settings section
                  _sectionHeader(context, 'Settings'),
                  SettingsTile(
                    icon: Icons.dashboard_customize,
                    color: Theme.of(context).colorScheme.tertiary,
                    title: 'Customize Modules',
                    subtitle: 'Show/hide features like Vehicles & Lending',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FeatureTogglesScreen())),
                  ),
                  const SizedBox(height: 10),
                  // Lending tile removed — now accessible via the bottom nav tab

                  SettingsTile(
                    icon: Icons.help_outline,
                    color: Theme.of(context).colorScheme.secondary,
                    title: 'Help & User Guide',
                    subtitle: 'How-to for every feature in SpendX',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpScreen())),
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.category,
                    color: Theme.of(context).colorScheme.error,
                    title: 'Category Management',
                    subtitle: 'Add, edit, or remove expense categories',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CategoryManagementScreen())),
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.notifications_active,
                    color: Theme.of(context).colorScheme.tertiary,
                    title: 'Notification Settings',
                    subtitle: 'Reminders, summaries & alert preferences',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationSettingsScreen())),
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.color_lens,
                    color: Theme.of(context).colorScheme.secondary,
                    title: 'App Theme Color',
                    subtitle: 'Personalize your SpendX experience',
                    onTap: () => _showThemePicker(context),
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.notifications_active,
                    color: Theme.of(context).colorScheme.primary,
                    title: 'Reminders',
                    subtitle: 'Daily, Weekly, Monthly',
                    onTap: () => _showReminderPicker(context),
                  ),
                  const SizedBox(height: 10),
                  SettingsTile(
                    icon: Icons.attach_money,
                    color: Theme.of(context).colorScheme.primary,
                    title: 'Display Currency',
                    subtitle: 'Change your main money format',
                    onTap: () => Navigator.push(context, SlideFadeTransition(page: CurrencySelectionScreen())),
                  ),
                  const SizedBox(height: 10),
                   FutureBuilder<PackageInfo>(
                    future: PackageInfo.fromPlatform(),
                    builder: (context, snapshot) {
                      final version = snapshot.data?.version ?? '1.2.0';
                       return SettingsTile(
                         icon: Icons.info_outline,
                         color: Theme.of(context).colorScheme.tertiary,
                         title: 'About SpendX',
                         subtitle: 'v$version',
                         onTap: () {
                           Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen()));
                         },
                       );
                    },
                  ),
                  const SizedBox(height: 16),

                  // Contact Developer Section
                  _sectionHeader(context, 'Feedback & Support'),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.mail_outline, color: Theme.of(context).colorScheme.primary, size: 20),
                            const SizedBox(width: 10),
                            Text('Contact Developer', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 15)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Have a bug to report or a feature idea? We\'d love to hear from you! Tap below to copy our email and drop us a message.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13, height: 1.5),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('mashingdesigns@gmail.com', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontFamily: 'monospace', fontSize: 13)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: Icon(Icons.copy, color: Theme.of(context).colorScheme.primary, size: 20),
                              tooltip: 'Copy email',
                              onPressed: () {
                                Clipboard.setData(const ClipboardData(text: 'mashingdesigns@gmail.com'));
                                CustomSnackBar.show(context, message: 'Email copied to clipboard!');                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '🐛 Bug reports  ·  💡 Feature suggestions  ·  🤝 Partnerships',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 0, 8),
    child: Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
  );





  void _showThemePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) {
        return Consumer2<AppTheme, SettingsService>(
          builder: (context, themeNotifier, settings, _) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Theme Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Accent Color', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 1.1)),
                  const SizedBox(height: 16),
                  
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: AppTheme.availableThemes.map((theme) {
                      final Color color = theme['color'];
                      final String name = theme['name'];
                      final isSelected = color == themeNotifier.seedColor;
                      
                      return GestureDetector(
                        onTap: () {
                          themeNotifier.setPrimaryColor(color);
                        },
                        child: Column(
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: isSelected ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
                                boxShadow: [
                                  if (isSelected) BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 12, spreadRadius: 2),
                                ],
                              ),
                              child: isSelected ? Icon(Icons.check, color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white) : null,
                            ),
                            const SizedBox(height: 8),
                            Text(name, style: TextStyle(
                              fontSize: 12, 
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                              color: isSelected ? Theme.of(context).colorScheme.primary : null,
                            )),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showReminderPicker(BuildContext context) {
    final cur = SettingsService.instance.periodicReminderFrequency;
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(
        builder: (context, setDs) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 20),
            const Text('Notification Reminders', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            _radioTile(context, 'Off', 'off', cur, setDs),
            _radioTile(context, 'Daily', 'daily', cur, setDs),
            _radioTile(context, 'Weekly', 'weekly', cur, setDs),
            _radioTile(context, 'Monthly', 'monthly', cur, setDs),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _radioTile(BuildContext context, String title, String value, String groupValue, StateSetter setDs) {
    return RadioListTile<String>(
      title: Text(title),
      value: value,
      groupValue: groupValue,
      activeColor: Theme.of(context).colorScheme.primary,
      onChanged: (v) async {
        if (v != null) {
          await SettingsService.instance.setPeriodicReminderFrequency(v);
          await NotificationService.instance.schedulePeriodicReminder(v);
          setDs(() {});
          if (context.mounted) Navigator.pop(context);
        }
      },
    );
  }

  Widget _buildHighlightsRow(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _fetchStats(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }
        final data = snapshot.data!;
        
        return AnimatedScaleWrapper(
          onTap: () => Navigator.push(context, SlideFadeTransition(page: const GamificationDetailScreen())),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _statCard('🔥 Streak', '${data["streak"]} Days', Theme.of(context).colorScheme.secondary, onTap: () => Navigator.push(context, SlideFadeTransition(page: const GamificationDetailScreen())))),
                  const SizedBox(width: 8),
                  Expanded(child: _statCard('📌 Level', '${data["level"]}', Theme.of(context).colorScheme.tertiary, onTap: () => Navigator.push(context, SlideFadeTransition(page: const GamificationDetailScreen())))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _statCard('📝 Logs', '${data["logs"]} Txns', Theme.of(context).colorScheme.primary, onTap: () => Navigator.push(context, SlideFadeTransition(page: const GamificationDetailScreen())))),
                  const SizedBox(width: 8),
                  Expanded(child: _statCard('💰 Spent', AppFormat.currency(data["spent"]), Theme.of(context).colorScheme.error, gradient: const LinearGradient(colors: [Color(0xFF451212), Color(0xFF230909)]), onTap: () => Navigator.push(context, SlideFadeTransition(page: const GamificationDetailScreen())))),

                ],
              ),
              const SizedBox(height: 8),
              FutureBuilder<Map<String, dynamic>>(
                future: FinancialHealthService.instance.calculateFinancialHealthScore(),
                builder: (context, healthSnapshot) {
                  final score = healthSnapshot.hasData ? (healthSnapshot.data!['score'] as int) : 0;
                  return Column(
                    children: [
                      _buildFinancialHealthCard(context, score),
                      const SizedBox(height: 24),
                      FutureBuilder<Map<DateTime, double>>(
                        future: TransactionService.instance.getDailySpendingForYear(DateTime.now().year),
                        builder: (context, spendingSnapshot) {
                          if (!spendingSnapshot.hasData) return const SizedBox.shrink();
                          return DailySpendingHeatmap(
                            dailySpending: spendingSnapshot.data!,
                            year: DateTime.now().year,
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<Map<String, dynamic>> _fetchStats() async {
    final streak = await GamificationService.instance.getCurrentStreak();
    final logs = await GamificationService.instance.getTotalTransactionCount();
    final spent = await GamificationService.instance.getTotalSpentAllTime();
    final level = await GamificationService.instance.getUserLevel();
    return {"streak": streak, "logs": logs, "spent": spent, "level": level};
  }

  Future<Map<String, dynamic>> _fetchExtendedStats() async {
    final joinDate = await GamificationService.instance.getJoinDate();
    final activeDays = await GamificationService.instance.getTotalActiveDays();
    final quote = GamificationService.instance.getDailyQuote();
    
    String formattedJoinDate = 'Today';
    if (joinDate != null) {
      formattedJoinDate = '${joinDate.day}/${joinDate.month}/${joinDate.year}';
    }
    
    return {
      "joinDate": formattedJoinDate,
      "activeDays": activeDays,
      "quote": quote,
    };
  }

  Widget _buildFinancialHealthCard(BuildContext context, int score) {
    // For now, using a mock improvement as history is not stored
    const int improvement = 5; 

    return AnimatedScaleWrapper(
      onTap: () => Navigator.push(context, SlideFadeTransition(page: const FinancialHealthScreen())),
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.secondary,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
              blurRadius: 15,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Financial Health',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Score: $score / 100',
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '+$improvement pts this month',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 66,
              height: 66,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 6,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                  Text(
                    '$score',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String title, String value, Color color, {Gradient? gradient, VoidCallback? onTap}) {
    return AnimatedScaleWrapper(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: gradient ?? LinearGradient(
            colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.08)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const Spacer(),
                if (onTap != null)
                  Icon(Icons.chevron_right, color: Colors.white.withValues(alpha: 0.4), size: 14),
              ],
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: FittedBox(
                key: ValueKey(value),
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
