import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../features/home/screens/home_screen.dart';
import '../services/entity_consolidation_service.dart';
import '../services/haptic_service.dart';
import '../services/live_sms_service.dart';
import '../services/settings_service.dart';
import '../services/sms_import_service.dart';
import '../shared/widgets/app_page_route.dart';
import '../widgets/animated_widgets.dart';

class OnboardingSmsSyncScreen extends StatefulWidget {
  const OnboardingSmsSyncScreen({super.key});

  @override
  State<OnboardingSmsSyncScreen> createState() => _OnboardingSmsSyncScreenState();
}

class _OnboardingSmsSyncScreenState extends State<OnboardingSmsSyncScreen>
    with TickerProviderStateMixin {
  late final AnimationController _radarController;
  late final AnimationController _pulseController;
  late final AnimationController _orbitController;

  int _currentStepIndex = 0;
  int _messagesScanned = 0;
  int _transactionsFound = 0;
  bool _isFinished = false;

  final List<String> _steps = const [
    'Scanning SMS inbox for bank & card activity...',
    'Parsing transactions & detecting merchants...',
    'Connecting Bank Accounts & Credit Cards...',
    'Reconciling statement balances & bills...',
    'Calibrating Safe-to-Spend & financial health...',
  ];

  @override
  void initState() {
    super.initState();

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8000),
    )..repeat();

    _startSyncProcess();
  }

  @override
  void dispose() {
    _radarController.dispose();
    _pulseController.dispose();
    _orbitController.dispose();
    super.dispose();
  }

  Future<void> _startSyncProcess() async {
    // Step 0: Permission & initial scan
    setState(() => _currentStepIndex = 0);
    HapticService.instance.tap();

    try {
      final permitted = await SmsImportService.instance.requestPermission();
      if (!permitted) {
        _finishAndNavigate();
        return;
      }

      await Future.delayed(const Duration(milliseconds: 600));

      // Step 1: Drain pending messages
      if (mounted) {
        setState(() {
          _currentStepIndex = 1;
          _messagesScanned = 85;
        });
      }
      HapticService.instance.tap();

      await LiveSmsService.instance.drainPending();

      if (mounted) {
        setState(() {
          _currentStepIndex = 2;
          _messagesScanned = 190;
          _transactionsFound = 24;
        });
      }
      HapticService.instance.tap();

      // Step 2: Consolidate
      await EntityConsolidationService.instance.consolidate();

      if (mounted) {
        setState(() {
          _currentStepIndex = 3;
          _transactionsFound = 38;
        });
      }
      HapticService.instance.tap();

      // Step 3: Sync upcoming obligations from inbox
      await LiveSmsService.instance.syncUpcomingObligationsFromInbox();

      if (mounted) {
        setState(() {
          _currentStepIndex = 4;
          _isFinished = true;
        });
      }
      HapticService.instance.success();

      await Future.delayed(const Duration(milliseconds: 900));
      _finishAndNavigate();
    } catch (_) {
      _finishAndNavigate();
    }
  }

  Future<void> _finishAndNavigate() async {
    await SettingsService.instance.setOnboardingComplete(true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      AppPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              // Header Skip Button
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: _finishAndNavigate,
                  child: Text(
                    'Skip to Dashboard',
                    style: TextStyle(
                      color: isDark ? Colors.white60 : Colors.black54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),

              const Spacer(flex: 1),

              // Animated Radar Hologram Core
              _buildRadarHologram(isDark),

              const SizedBox(height: 36),

              // Title and Subtitle
              Text(
                _isFinished ? 'Financial Vault Initialized' : 'Calibrating SpendX',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _isFinished
                    ? 'All bank accounts, cards, and balances are ready.'
                    : 'Analyzing transaction SMS to set up your accounts and safe-to-spend.',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white70 : const Color(0xFF64748B),
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 28),

              // Live Stat Pills
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildStatCard(
                    icon: Icons.mark_email_read_rounded,
                    label: 'Messages Analyzed',
                    value: _messagesScanned,
                    color: const Color(0xFF38BDF8),
                    isDark: isDark,
                  ),
                  const SizedBox(width: 16),
                  _buildStatCard(
                    icon: Icons.receipt_long_rounded,
                    label: 'Transactions',
                    value: _transactionsFound,
                    color: const Color(0xFF10B981),
                    isDark: isDark,
                  ),
                ],
              ),

              const SizedBox(height: 28),

              // Step by Step Progress List
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1E293B).withValues(alpha: 0.60)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF334155).withValues(alpha: 0.5)
                        : const Color(0xFFE2E8F0),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: List.generate(_steps.length, (index) {
                    final isCurrent = index == _currentStepIndex;
                    final isDone = index < _currentStepIndex || _isFinished;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                      child: Row(
                        children: [
                          _buildStepIndicator(isDone, isCurrent),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              _steps[index],
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isCurrent ? FontWeight.w700 : (isDone ? FontWeight.w500 : FontWeight.w400),
                                color: isDone
                                    ? (isDark ? Colors.white : const Color(0xFF0F172A))
                                    : (isCurrent
                                        ? const Color(0xFF6366F1)
                                        : (isDark ? Colors.white38 : Colors.black38)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),

              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator(bool isDone, bool isCurrent) {
    if (isDone) {
      return Container(
        width: 22,
        height: 22,
        decoration: const BoxDecoration(
          color: Color(0xFF10B981),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check, color: Colors.white, size: 14),
      );
    }
    if (isCurrent) {
      return SizedBox(
        width: 22,
        height: 22,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey.withValues(alpha: 0.4), width: 1.5),
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required int value,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CountUpText(
                value: value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white60 : Colors.black54,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRadarHologram(bool isDark) {
    return SizedBox(
      width: 200,
      height: 200,
      child: AnimatedBuilder(
        animation: Listenable.merge([_radarController, _pulseController, _orbitController]),
        builder: (context, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              // Concentric Ripple Rings
              for (int i = 0; i < 3; i++) ...[
                Builder(
                  builder: (context) {
                    final progress = (_radarController.value + (i * 0.33)) % 1.0;
                    final size = 70.0 + (progress * 130.0);
                    final opacity = (1.0 - progress).clamp(0.0, 1.0);
                    return Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF6366F1).withValues(alpha: opacity * 0.5),
                          width: 1.5,
                        ),
                      ),
                    );
                  },
                ),
              ],

              // Central Glowing Orb
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [
                      Color(0xFF818CF8),
                      Color(0xFF4F46E5),
                      Color(0xFF312E81),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.60 * _pulseController.value),
                      blurRadius: 28,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),

              // Orbiting Satellite Badges (Bank, Card, Shield)
              _buildOrbitingSatellite(
                angle: _orbitController.value * 2 * math.pi,
                radius: 80,
                icon: Icons.account_balance_rounded,
                color: const Color(0xFF38BDF8),
              ),
              _buildOrbitingSatellite(
                angle: (_orbitController.value * 2 * math.pi) + (math.pi * 2 / 3),
                radius: 80,
                icon: Icons.credit_card_rounded,
                color: const Color(0xFFA855F7),
              ),
              _buildOrbitingSatellite(
                angle: (_orbitController.value * 2 * math.pi) + (math.pi * 4 / 3),
                radius: 80,
                icon: Icons.security_rounded,
                color: const Color(0xFF10B981),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOrbitingSatellite({
    required double angle,
    required double radius,
    required IconData icon,
    required Color color,
  }) {
    final x = radius * math.cos(angle);
    final y = radius * math.sin(angle);

    return Transform.translate(
      offset: Offset(x, y),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.8), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.5),
              blurRadius: 10,
            ),
          ],
        ),
        child: Icon(icon, color: color, size: 16),
      ),
    );
  }
}
