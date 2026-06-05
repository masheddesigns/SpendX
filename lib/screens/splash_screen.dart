import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:permission_handler/permission_handler.dart';
import '../data/repositories/category_repo.dart';
import '../data/repositories/review_repo.dart';
import '../services/app_session_service.dart';
import '../services/retention_events.dart';
import '../services/retention_service.dart';
import '../services/notification_service.dart';
import '../services/recurring_engine.dart';
import '../services/settings_service.dart';
import '../services/snapshot_trigger.dart';
import '../services/spending_insights_service.dart';
import '../features/home/screens/home_screen.dart';
import 'onboarding_screen.dart';
import '../shared/widgets/app_page_route.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;
  late Animation<double> _textFade;
  late Animation<double> _subtitleFade;
  late Animation<double> _glowOpacity;

  /// Init work has finished — we just need a moment when splash is
  /// the topmost route to actually navigate. Set after
  /// [_checkInitialState] completes; gates the home-nav recheck loop.
  bool _initWorkDone = false;

  /// Recheck timer used when share flow is on top of splash. Polls
  /// every 400ms until splash becomes the visible route again, then
  /// fires the home navigation that was deferred.
  Timer? _navRecheck;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _checkInitialState();
  }

  void _setupAnimations() {
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack),
      ),
    );

    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
      ),
    );

    _textFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.3, 0.7, curve: Curves.easeIn),
      ),
    );

    _subtitleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.5, 0.9, curve: Curves.easeIn),
      ),
    );

    _glowOpacity = Tween<double>(begin: 0.0, end: 0.6).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.2, 0.8, curve: Curves.easeInOut),
      ),
    );

    _ctrl.forward();
  }

  @override
  void dispose() {
    _navRecheck?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _checkInitialState() async {
    await Future.delayed(const Duration(milliseconds: 1400));

    if (!mounted) return;

    // ALWAYS seed categories first
    debugPrint('\u{1F331} Seeding categories');
    await CategoryRepo().ensureDefaults();
    debugPrint('\u2705 Categories seeded');

    if (!mounted) return;

    final onboardingComplete = SettingsService.instance.isOnboardingComplete;

    if (!onboardingComplete) {
      // Defensive guard: only replace if splash is still the topmost
      // route. A share intent received during the splash delay can
      // push ImportProcessingScreen on top; replacing in that state
      // would silently destroy the share flow.
      if (ModalRoute.of(context)?.isCurrent != true) {
        debugPrint('[Splash] Share flow on top — skipping onboarding nav');
        return;
      }
      Navigator.of(context).pushReplacement(
        AppPageRoute(builder: (_) => const OnboardingScreen()),
      );
      return;
    }

    // Start session tracking
    AppSessionService.instance.init();

    // Mark today as active (streak + last-active timestamp)
    await RetentionService.instance.markActiveToday();
    // Observation: app open event
    await RetentionEvents.instance.log(RetentionEvent.appOpen);
    // Re-arm the 24h re-engagement notification — only if actionable.
    // Empty "just checking in" notifications degrade trust.
    final pendingReviews = await ReviewRepo().getPendingCount();
    await RetentionService.instance.scheduleReengagementCheck(
      pendingReviews: pendingReviews,
    );

    // Schedule wrapped notifications
    _scheduleWrappedNotifications();

    // Schedule daily/weekly spending insights
    _scheduleSpendingInsights();

    // Request permissions (non-blocking)
    _requestPermissions();

    // Generate recurring transactions (non-blocking)
    RecurringEngine.checkAndGenerate().then((changed) {
      if (changed) debugPrint('\u{1F501} Recurring transactions generated');
    }).catchError((e) {
      debugPrint('\u26A0\uFE0F Recurring engine error (non-fatal): $e');
    });

    // Daily net worth snapshot
    SnapshotTrigger.instance.onAppOpen();

    _initWorkDone = true;
    _attemptHomeNavigation();
  }

  /// Push HomeScreen IF splash is currently the visible route.
  /// Otherwise schedule a recheck — needed because:
  ///   * A share intent during cold start pushes ImportProcessingScreen
  ///     on top of splash before this method is called, so we'd
  ///     stomp the share flow if we pushReplaced unconditionally.
  ///   * After the share flow ends (user saves/cancels) the user
  ///     pops back to splash. Without a recheck loop they'd be stuck
  ///     on the splash logo with no way to advance.
  /// The 400ms cadence is fast enough to feel instant on user pop-back
  /// without burning CPU during the share window.
  void _attemptHomeNavigation() {
    if (!mounted || !_initWorkDone) return;
    if (ModalRoute.of(context)?.isCurrent != true) {
      _navRecheck?.cancel();
      _navRecheck = Timer(
        const Duration(milliseconds: 400),
        _attemptHomeNavigation,
      );
      return;
    }
    _navRecheck?.cancel();
    _navRecheck = null;
    Navigator.of(context).pushReplacement(
      AppPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  Future<void> _requestPermissions() async {
    try {
      final notifStatus = await Permission.notification.status;
      if (!notifStatus.isGranted) await Permission.notification.request();

      await NotificationService.instance.requestPermissions();
    } catch (e) {
      debugPrint('\u26A0\uFE0F Permission request error (non-fatal): $e');
    }
  }

  void _scheduleWrappedNotifications() {
    try {
      final now = DateTime.now();

      // Weekly: next Monday 9am
      final daysUntilMonday = (DateTime.monday - now.weekday + 7) % 7;
      final nextMonday = DateTime(now.year, now.month,
          now.day + (daysUntilMonday == 0 ? 7 : daysUntilMonday), 9, 0);
      NotificationService.instance.scheduleNotification(
        id: 90000,
        title: 'Your Weekly Wrapped is ready!',
        body: 'See how you spent this week',
        scheduledDate: nextMonday,
      );

      // Monthly: 1st of next month 9am
      final nextMonth = DateTime(now.year, now.month + 1, 1, 9, 0);
      NotificationService.instance.scheduleNotification(
        id: 90001,
        title: 'Your ${_monthName(now.month)} Wrapped is ready!',
        body: 'See your monthly financial summary',
        scheduledDate: nextMonth,
      );

      // Yearly: Jan 1 10am
      final nextYear = DateTime(now.year + 1, 1, 1, 10, 0);
      NotificationService.instance.scheduleNotification(
        id: 90002,
        title: 'Your ${now.year} Year in Review is here!',
        body: 'Tap to see your yearly financial wrapped',
        scheduledDate: nextYear,
      );
    } catch (e) {
      debugPrint('Wrapped notification scheduling failed (non-fatal): $e');
    }
  }

  /// Schedule daily (9pm) and weekly (Monday 8am) spending insights.
  void _scheduleSpendingInsights() {
    try {
      final now = DateTime.now();

      // Daily: schedule for 9pm today (or tomorrow if already past 9pm)
      var dailyTime = DateTime(now.year, now.month, now.day, 21, 0);
      if (dailyTime.isBefore(now)) {
        dailyTime = dailyTime.add(const Duration(days: 1));
      }
      NotificationService.instance.scheduleNotification(
        id: 42001,
        title: 'Daily Spending Summary',
        body: 'Tap to see today\'s summary',
        scheduledDate: dailyTime,
      );

      // Also run it now if it's evening and hasn't been sent today
      if (now.hour >= 20) {
        SpendingInsightsService.instance.checkDailySummary();
      }

      // Weekly: next Monday at 8am
      final daysUntilMon = (DateTime.monday - now.weekday + 7) % 7;
      final nextMon = DateTime(now.year, now.month,
          now.day + (daysUntilMon == 0 ? 7 : daysUntilMon), 8, 0);
      NotificationService.instance.scheduleNotification(
        id: 42002,
        title: 'Weekly Spending Report',
        body: 'Tap to see this week\'s comparison',
        scheduledDate: nextMon,
      );

      // If it's Monday, also send the weekly summary now
      if (now.weekday == DateTime.monday) {
        SpendingInsightsService.instance.checkWeeklySummary();
      }
    } catch (e) {
      debugPrint('Spending insight scheduling failed (non-fatal): $e');
    }
  }

  static String _monthName(int month) {
    const names = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return names[month.clamp(1, 12)];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF060D1B),
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Stack(
            children: [
              // ── Background gradient circles ─────────────
              // Background glow orbs (SpendX green)
              Positioned(
                top: -120,
                right: -80,
                child: Opacity(
                  opacity: _glowOpacity.value * 0.3,
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Color(0x6623BE62),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: -100,
                left: -60,
                child: Opacity(
                  opacity: _glowOpacity.value * 0.2,
                  child: Container(
                    width: 250,
                    height: 250,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          cs.tertiary.withValues(alpha: 0.3),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Center content ──────────────────────────
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Logo
                    Opacity(
                      opacity: _logoFade.value,
                      child: Transform.scale(
                        scale: _logoScale.value,
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(32),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF23BE62).withValues(
                                    alpha: _glowOpacity.value * 0.5),
                                blurRadius: 50,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          child: Center(
                            child: SvgPicture.asset(
                              'assets/logo.svg',
                              width: 72,
                              height: 72,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // App name
                    Opacity(
                      opacity: _textFade.value,
                      child: const Text(
                        'SpendX',
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 3,
                          shadows: [
                            Shadow(
                              color: Color(0x8023BE62),
                              blurRadius: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Tagline
                    Opacity(
                      opacity: _subtitleFade.value,
                      child: Text(
                        'Finance, Simplified.',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          color: Colors.white.withValues(alpha: 0.5),
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),

                    const SizedBox(height: 48),

                    // Loading indicator
                    Opacity(
                      opacity: _subtitleFade.value,
                      child: const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0x6623BE62),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
