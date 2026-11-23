import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../features/home/screens/home_screen.dart';
import '../models/calibration_progress.dart';
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
  State<OnboardingSmsSyncScreen> createState() =>
      _OnboardingSmsSyncScreenState();
}

class _OnboardingSmsSyncScreenState extends State<OnboardingSmsSyncScreen>
    with TickerProviderStateMixin {
  late final AnimationController _radarController;
  late final AnimationController _pulseController;
  late final AnimationController _orbitController;

  int _currentStepIndex = 0;
  CalibrationProgress _progress = const CalibrationProgress();
  bool _isResumed = false;
  bool _isFinished = false;
  bool _isRunning = false;
  bool _isError = false;
  bool _motionConfigured = false;
  String? _errorMessage;

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
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _orbitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8000),
    );

    _startSyncProcess();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionConfigured) return;
    _motionConfigured = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _radarController.value = 0.5;
      _pulseController.value = 0.5;
      _orbitController.value = 0.5;
    } else {
      _radarController.repeat();
      _pulseController.repeat(reverse: true);
      _orbitController.repeat();
    }
  }

  @override
  void dispose() {
    _radarController.dispose();
    _pulseController.dispose();
    _orbitController.dispose();
    super.dispose();
  }

  Future<void> _startSyncProcess() async {
    if (_isRunning) return;
    _isRunning = true;

    // Step 0: Permission & initial scan
    setState(() {
      _currentStepIndex = 0;
      _isError = false;
      _isFinished = false;
      _isResumed = false;
      _errorMessage = null;
      _progress = const CalibrationProgress();
    });
    HapticService.instance.tap();

    try {
      final permitted = await SmsImportService.instance.requestPermission();
      if (!permitted) {
        // The user explicitly declined SMS access; continuing onboarding is
        // intentional, but this is not a "successful sync".
        await _finishAndNavigate();
        return;
      }

      await Future.delayed(const Duration(milliseconds: 300));

      // Step 1: Historical SMS inbox scan with real-time live progress
      if (mounted) {
        setState(() => _currentStepIndex = 1);
      }
      HapticService.instance.tap();

      final outcome = await LiveSmsService.instance.calibrateFromInbox(
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progress = p;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _progress = outcome.progress;
          _isResumed = outcome.resumed;
        });
      }

      if (!outcome.completed) {
        _fail(outcome.error ?? 'The SMS import did not finish.');
        return;
      }

      if (mounted) {
        setState(() => _currentStepIndex = 2);
      }
      HapticService.instance.tap();

      // Step 2: Consolidate
      await EntityConsolidationService.instance.consolidate();

      if (mounted) {
        setState(() => _currentStepIndex = 3);
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
      await _finishAndNavigate();
    } catch (e) {
      _fail('Setup could not finish: $e');
    } finally {
      if (mounted) {
        setState(() => _isRunning = false);
      }
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _isError = true;
      _errorMessage = message;
    });
    HapticService.instance.critical();
  }

  Future<void> _finishAndNavigate() async {
    await SettingsService.instance.setOnboardingComplete(true);
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(AppPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
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

              const SizedBox(height: 12),

              // Animated Radar Hologram Core
              _buildRadarHologram(isDark),

              const SizedBox(height: 24),

              // Title and Subtitle
              Text(
                _isFinished
                    ? 'Financial Vault Initialized'
                    : (_isError
                          ? 'Import Needs Attention'
                          : 'Calibrating SpendX'),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _isFinished
                    ? 'All bank accounts, cards, and balances are ready.'
                    : (_isError
                          ? 'Your existing data is safe. Retry to finish scanning, or skip and import later from settings.'
                          : 'Analyzing transaction SMS to set up your accounts and safe-to-spend.'),
                style: TextStyle(
                  fontSize: 14,
                  color: isDark
                      ? Colors.white70
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 28),

              // Live Stat Pills
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildStatCard(
                    icon: Icons.mark_email_read_rounded,
                    label: 'Scanned',
                    value: _progress.messagesScanned,
                    color: Theme.of(context).colorScheme.primary,
                    isDark: isDark,
                    explanation:
                        'Total SMS messages processed from your inbox history.',
                  ),
                  _buildStatCard(
                    icon: Icons.account_balance_rounded,
                    label: 'Financial',
                    value: _progress.financialIdentified,
                    color: const Color(0xFF60A5FA),
                    isDark: isDark,
                    explanation:
                        'Verified bank alerts, debits, credits, and card notifications.',
                  ),
                  _buildStatCard(
                    icon: Icons.credit_card_rounded,
                    label: 'Accounts',
                    value: _progress.accountsDiscovered,
                    color: Theme.of(context).colorScheme.primary,
                    isDark: isDark,
                    explanation:
                        'Bank accounts, credit cards, and digital wallets discovered.',
                  ),
                  _buildStatCard(
                    icon: Icons.check_circle_rounded,
                    label: 'Imported',
                    value: _progress.transactionsImported,
                    color: Theme.of(context).colorScheme.secondary,
                    isDark: isDark,
                    explanation:
                        'Verified transactions posted to your double-entry ledger.',
                  ),
                  _buildStatCard(
                    icon: Icons.sync_rounded,
                    label: 'Matched',
                    value: _progress.existingMatched,
                    color: const Color(0xFF14B8A6),
                    isDark: isDark,
                    explanation:
                        'Duplicate transactions identified to prevent double-counting.',
                  ),
                  _buildStatCard(
                    icon: Icons.rate_review_rounded,
                    label: 'Review',
                    value: _progress.reviewRequired,
                    color: Theme.of(context).colorScheme.tertiary,
                    isDark: isDark,
                    explanation:
                        'Ambiguous items safely waiting for your 1-tap confirmation.',
                  ),
                  _buildStatCard(
                    icon: Icons.event_note_rounded,
                    label: 'Bills/Dues',
                    value: _progress.obligationsDetected,
                    color: const Color(0xFFA855F7),
                    isDark: isDark,
                    explanation:
                        'Upcoming credit card statements, due dates, and mandate alerts.',
                  ),
                  _buildStatCard(
                    icon: Icons.filter_alt_off_rounded,
                    label: 'Ignored',
                    value: _progress.nonFinancialIgnored,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    isDark: isDark,
                    explanation:
                        'OTPs, spam, and non-financial messages safely skipped.',
                  ),
                ],
              ),

              if (_isResumed) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 14,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Resumed from previous scan checkpoint',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (_isError) ...[
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.error.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Import incomplete',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _errorMessage ??
                            'Some messages could not be processed.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _isRunning ? null : _startSyncProcess,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Retry import'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 28),

              // Step by Step Progress List
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(
                      alpha: isDark ? 0.5 : 1,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.25 : 0.04,
                      ),
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
                                fontWeight: isCurrent
                                    ? FontWeight.w700
                                    : (isDone
                                          ? FontWeight.w500
                                          : FontWeight.w400),
                                color: isDone
                                    ? (Theme.of(context).colorScheme.onSurface)
                                    : (isCurrent
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : (isDark
                                                ? Colors.white38
                                                : Colors.black38)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),

              const SizedBox(height: 24),
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
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondary,
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
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).colorScheme.primary,
                ),
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
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
    );
  }

  void _showStatExplanation(String label, String description, Color color) {
    HapticService.instance.tap();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.inverseSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color.withValues(alpha: 0.5)),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: color,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required int value,
    required Color color,
    required bool isDark,
    required String explanation,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showStatExplanation(label, explanation, color),
        splashColor: color.withValues(alpha: 0.2),
        highlightColor: color.withValues(alpha: 0.1),
        child: Container(
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
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CountUpText(
                      value: value,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white60 : Colors.black54,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRadarHologram(bool isDark) {
    return Semantics(
      button: true,
      label: _isRunning ? 'SMS sync in progress' : 'Start SMS sync',
      child: GestureDetector(
        onTap: () {
          HapticService.instance.tap();
          _pulseController.forward(from: 0.0);
          if (!_isRunning && !_isFinished) {
            _startSyncProcess();
          }
        },
        child: SizedBox(
          width: 170,
          height: 170,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _radarController,
              _pulseController,
              _orbitController,
            ]),
            builder: (context, _) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Concentric Ripple Rings
                  for (int i = 0; i < 3; i++) ...[
                    Builder(
                      builder: (context) {
                        final progress =
                            (_radarController.value + (i * 0.33)) % 1.0;
                        final size = 70.0 + (progress * 130.0);
                        final opacity = (1.0 - progress).clamp(0.0, 1.0);
                        return Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary
                                  .withValues(alpha: opacity * 0.5),
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
                      gradient: RadialGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary,
                          Theme.of(context).colorScheme.primary,
                          Theme.of(context).colorScheme.primaryContainer,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: 0.60 * _pulseController.value),
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
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  _buildOrbitingSatellite(
                    angle:
                        (_orbitController.value * 2 * math.pi) +
                        (math.pi * 2 / 3),
                    radius: 80,
                    icon: Icons.credit_card_rounded,
                    color: const Color(0xFFA855F7),
                  ),
                  _buildOrbitingSatellite(
                    angle:
                        (_orbitController.value * 2 * math.pi) +
                        (math.pi * 4 / 3),
                    radius: 80,
                    icon: Icons.security_rounded,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ],
              );
            },
          ),
        ),
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
            BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 10),
          ],
        ),
        child: Icon(icon, color: color, size: 16),
      ),
    );
  }
}
