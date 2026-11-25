import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../screens/expense/add_expense_screen.dart';
import '../../../screens/financial_health_screen.dart';
import '../../../services/haptic_service.dart';
import '../../../shared/widgets/playful/spendx_playful.dart';
import '../../../theme/app_theme.dart';
import '../../streak/streak_provider.dart';
import '../../transactions/providers/transaction_providers.dart';

/// Tactile Action Hub & Seamless Mindful Tracking Rhythm.
///
/// Features:
/// 1. Primary [ + Log activity ] hero trigger with direct chips (Spent, Received, Moved).
/// 2. Cardless, canvas-integrated Tracking Rhythm path (○ ── ◉ ── ○) with custom SpendX vector tokens.
/// 3. Zero emojis; 100% custom vector identity.
class QuickActionsRow extends ConsumerWidget {
  const QuickActionsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final streakAsync = ref.watch(evaluateStreakProvider);
    final paginatedTxns = ref.watch(paginatedTransactionsProvider);
    final txnsAsync = ref.watch(transactionsProvider);

    final streak = streakAsync.valueOrNull?.current ?? 0;
    final allTxns = txnsAsync.valueOrNull ?? paginatedTxns.items;

    // Build rolling 5-day rhythm window (Day -2, Day -1, Today, Day +1, Day +2)
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    int countActivityOnDay(DateTime day) {
      return allTxns.where((t) {
        if (t.isDeleted) return false;
        final local = t.date.toLocal();
        return local.year == day.year &&
            local.month == day.month &&
            local.day == day.day;
      }).length;
    }

    final rhythmDays = [
      _RhythmDayData(
        date: today.subtract(const Duration(days: 2)),
        isCompleted:
            countActivityOnDay(today.subtract(const Duration(days: 2))) > 0,
        isToday: false,
        isFuture: false,
        count: countActivityOnDay(today.subtract(const Duration(days: 2))),
      ),
      _RhythmDayData(
        date: today.subtract(const Duration(days: 1)),
        isCompleted:
            countActivityOnDay(today.subtract(const Duration(days: 1))) > 0,
        isToday: false,
        isFuture: false,
        count: countActivityOnDay(today.subtract(const Duration(days: 1))),
      ),
      _RhythmDayData(
        date: today,
        isCompleted: countActivityOnDay(today) > 0,
        isToday: true,
        isFuture: false,
        count: countActivityOnDay(today),
      ),
      _RhythmDayData(
        date: today.add(const Duration(days: 1)),
        isCompleted: false,
        isToday: false,
        isFuture: true,
        count: 0,
      ),
      _RhythmDayData(
        date: today.add(const Duration(days: 2)),
        isCompleted: false,
        isToday: false,
        isFuture: true,
        count: 0,
      ),
    ];

    final isTodayLogged = rhythmDays[2].isCompleted;
    final String rhythmCaption;
    if (isTodayLogged) {
      rhythmCaption = streak > 1
          ? "$streak-day rhythm active • Momentum is strong"
          : "Today's money story has started";
    } else if (streak > 0) {
      rhythmCaption =
          "Keep your $streak-day rhythm alive — log today's activity";
    } else {
      rhythmCaption = "Log your first activity to start your financial rhythm";
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          // ── Prominent 3D Tactile Action: "[ + Log activity ]" ──
          _HeroLogButton(onTap: () => _openScreen(context, 'expense')),

          const SizedBox(height: 10),

          // ── Fast-path 3D Tactile Chips: Spent, Received, Moved ──
          Row(
            children: [
              Expanded(
                child: _QuickChip(
                  label: 'Spent',
                  iconData: Icons.arrow_outward_rounded,
                  accentColor: PlayfulTokens.sunsetCoral,
                  lipColor: PlayfulTokens.sunsetCoralLip,
                  onTap: () => _openScreen(context, 'expense'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickChip(
                  label: 'Received',
                  iconData: Icons.arrow_downward_rounded,
                  accentColor: PlayfulTokens.neoMint,
                  lipColor: PlayfulTokens.neoMintLip,
                  onTap: () => _openScreen(context, 'income'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickChip(
                  label: 'Moved',
                  iconData: Icons.swap_horiz_rounded,
                  accentColor: PlayfulTokens.cyberCyan,
                  lipColor: PlayfulTokens.cyberCyanLip,
                  onTap: () => _openScreen(context, 'transfer', ref: ref),
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          // ── Seamless Canvas Tracking Rhythm (Cardless, Organic) ──
          Semantics(
            button: true,
            label: 'Your rhythm and financial health',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Navigator.push(
                    context,
                    PlayfulPageRoute(builder: (_) => const FinancialHealthScreen()),
                  );
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header: YOUR RHYTHM  &  STREAK TOKEN
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'YOUR RHYTHM',
                          style: TextStyle(
                            fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SpendXRhythmVectorToken(streak: streak),
                        const SizedBox(width: 6),
                        Text(
                          '$streak ${streak == 1 ? 'DAY' : 'DAYS'}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // Rhythm Path: ○ ─── ◉ ─── ○ ─── ○ ─── ○
                _buildRhythmTrack(context, isDark, rhythmDays: rhythmDays),

                const SizedBox(height: 8),

                // Supportive, Clean Subtitle
                Center(
                  child: Text(
                    rhythmCaption,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),

          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// The 5-day rolling rhythm track (○ ─── ◉ ─── ○ ─── ○)
  Widget _buildRhythmTrack(
    BuildContext context,
    bool isDark, {
    required List<_RhythmDayData> rhythmDays,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          alignment: Alignment.topCenter,
          children: [
            // Connecting hairline running at circle center (y = 10)
            Container(
              height: 1.2,
              margin: const EdgeInsets.only(top: 9, left: 24, right: 24),
              color: context.borderColor,
            ),

            // 5 Rolling Rhythm Nodes
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: rhythmDays.map((day) {
                return _RhythmNode(
                  day: day,
                  onTap: () => _onTapNode(context, day),
                );
              }).toList(),
            ),
          ],
        );
      },
    );
  }

  void _onTapNode(BuildContext context, _RhythmDayData day) {
    HapticService.instance.tap();
    if (day.isToday) {
      if (day.isCompleted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Today: ${day.count} transaction${day.count > 1 ? 's' : ''} logged ✓',
            ),
            duration: const Duration(milliseconds: 1800),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        _openScreen(context, 'expense');
      }
    } else if (day.isFuture) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${DateFormat('EEEE').format(day.date)}: Upcoming day in your rhythm',
          ),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            day.isCompleted
                ? '${DateFormat('EEEE').format(day.date)}: ${day.count} transaction${day.count > 1 ? 's' : ''} logged'
                : '${DateFormat('EEEE').format(day.date)}: No transactions logged',
          ),
          duration: const Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openScreen(BuildContext context, String type, {WidgetRef? ref}) {
    Navigator.push(
      context,
      PlayfulPageRoute(builder: (_) => AddExpenseScreen(initialType: type)),
    );
  }
}

class _RhythmDayData {
  final DateTime date;
  final bool isCompleted;
  final bool isToday;
  final bool isFuture;
  final int count;

  const _RhythmDayData({
    required this.date,
    required this.isCompleted,
    required this.isToday,
    required this.isFuture,
    required this.count,
  });
}

class _RhythmNode extends StatelessWidget {
  final _RhythmDayData day;
  final VoidCallback? onTap;

  const _RhythmNode({required this.day, this.onTap});

  @override
  Widget build(BuildContext context) {
    final weekdayLabel = day.isToday
        ? 'TODAY'
        : DateFormat('E').format(day.date).toUpperCase();

    Widget nodeCircle;
    if (day.isToday) {
      nodeCircle = Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: day.isCompleted
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surface,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.primary,
            width: 2.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.35),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: day.isCompleted
            ? Center(
                child: Icon(
                  Icons.check,
                  size: 10,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              )
            : null,
      );
    } else if (day.isCompleted) {
      nodeCircle = Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.secondary.withValues(alpha: 0.30),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Center(
          child: Icon(
            Icons.check_rounded,
            size: 10,
            color: Theme.of(context).colorScheme.onSecondary,
          ),
        ),
      );
    } else {
      nodeCircle = Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            width: 1.2,
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: 'Tracking for ${day.isToday ? "Today, " : ""}$weekdayLabel',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: 20, child: Center(child: nodeCircle)),
                const SizedBox(height: 5),
                Text(
                  weekdayLabel,
                  style: AppTextStyles.caption.copyWith(
                    fontSize: day.isToday ? 10.5 : 10.0,
                    fontWeight: day.isToday ? FontWeight.w800 : FontWeight.w600,
                    letterSpacing: 0.5,
                    color: day.isToday
                        ? (Theme.of(context).colorScheme.primary)
                        : (Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// SpendX Custom Vector Rhythm Token (Zero Emojis).
///
/// Distinctive geometric states:
/// Day 1–2: Emerging spark token (○╱)
/// Day 3–6: Dual climbing sprout token (○╱╲)
/// Day 7+: Radiant constellation token (✦╱╲✦)
class _SpendXRhythmVectorToken extends StatelessWidget {
  final int streak;

  const _SpendXRhythmVectorToken({required this.streak});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(18, 18),
      painter: _RhythmTokenPainter(
        streak: streak,
        warningColor: Theme.of(context).colorScheme.tertiary,
        successColor: Theme.of(context).colorScheme.secondary,
        surfaceColor: Theme.of(context).colorScheme.surface,
      ),
    );
  }
}

class _RhythmTokenPainter extends CustomPainter {
  final int streak;
  final Color warningColor;
  final Color successColor;
  final Color surfaceColor;

  _RhythmTokenPainter({
    required this.streak,
    required this.warningColor,
    required this.successColor,
    required this.surfaceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);

    final color = warningColor;

    if (streak >= 7) {
      // ✦ Established Rhythm: Radiant 4-point constellation mark
      final starPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      final star = Path()
        ..moveTo(cx, 1)
        ..quadraticBezierTo(cx + 1.5, cy - 1.5, size.width - 1, cy)
        ..quadraticBezierTo(cx + 1.5, cy + 1.5, cx, size.height - 1)
        ..quadraticBezierTo(cx - 1.5, cy + 1.5, 1, cy)
        ..quadraticBezierTo(cx - 1.5, cy - 1.5, cx, 1)
        ..close();
      canvas.drawPath(star, starPaint);

      // Inner dot
      final innerPaint = Paint()
        ..color = surfaceColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 2.0, innerPaint);
    } else if (streak >= 3) {
      // ○╱╲ Growing Rhythm: Dual climbing sprout mark
      final strokePaint = Paint()
        ..color = successColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;

      final leftLeaf = Path()
        ..moveTo(cx, size.height - 2)
        ..cubicTo(cx - 5, cy, cx - 6, cy - 4, cx - 1, cy - 6);
      canvas.drawPath(leftLeaf, strokePaint);

      final rightLeaf = Path()
        ..moveTo(cx, size.height - 2)
        ..cubicTo(cx + 5, cy + 2, cx + 6, cy - 3, cx + 2, cy - 7);
      canvas.drawPath(rightLeaf, strokePaint);

      final baseDot = Paint()
        ..color = successColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, size.height - 2), 1.8, baseDot);
    } else {
      // ○╱ Starting Rhythm: Emerging seed & diagonal trail mark
      final circlePaint = Paint()
        ..color = warningColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx - 3, cy + 3), 3.0, circlePaint);

      final ascentPaint = Paint()
        ..color = warningColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(cx - 1, cy + 1),
        Offset(cx + 5, cy - 5),
        ascentPaint,
      );
      canvas.drawCircle(Offset(cx + 5, cy - 5), 1.5, circlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RhythmTokenPainter oldDelegate) {
    return oldDelegate.streak != streak ||
        oldDelegate.warningColor != warningColor ||
        oldDelegate.successColor != successColor ||
        oldDelegate.surfaceColor != surfaceColor;
  }
}

class _HeroLogButton extends StatelessWidget {
  final VoidCallback onTap;

  const _HeroLogButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SpendXPlayfulButton(
      onPressed: onTap,
      variant: PlayfulButtonVariant.primary,
      height: 52,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_rounded, size: 22, color: Colors.white),
          SizedBox(width: 8),
          Text(
            'Log Activity',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickChip extends StatefulWidget {
  final String label;
  final IconData iconData;
  final Color accentColor;
  final Color lipColor;
  final VoidCallback onTap;

  const _QuickChip({
    required this.label,
    required this.iconData,
    required this.accentColor,
    required this.lipColor,
    required this.onTap,
  });

  @override
  State<_QuickChip> createState() => _QuickChipState();
}

class _QuickChipState extends State<_QuickChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  bool _isDown = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: PlayfulTokens.durationPress,
      reverseDuration: PlayfulTokens.durationBounce,
    );
    _anim = CurvedAnimation(
      parent: _ctrl,
      curve: PlayfulTokens.curveSquish,
      reverseCurve: PlayfulTokens.curveBounce,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    _isDown = true;
    _ctrl.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    if (!_isDown) return;
    _isDown = false;
    _ctrl.reverse();
    widget.onTap();
  }

  void _handleTapCancel() {
    if (!_isDown) return;
    _isDown = false;
    _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final double depression = _anim.value * 2.5;
            final double scale = 1.0 - (_anim.value * 0.03);

            return Transform.scale(
              scale: scale,
              child: SizedBox(
                height: 44,
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    // Bottom 3D Lip
                    Positioned(
                      top: 3.5,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: widget.lipColor.withValues(alpha: isDark ? 0.35 : 0.25),
                          borderRadius: BorderRadius.circular(PlayfulTokens.radiusPill),
                        ),
                      ),
                    ),

                    // Top Surface
                    Positioned(
                      top: depression,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF1E2230) : Colors.white,
                          borderRadius: BorderRadius.circular(PlayfulTokens.radiusPill),
                          border: Border.all(
                            color: widget.accentColor.withValues(alpha: isDark ? 0.40 : 0.35),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: widget.accentColor.withValues(alpha: isDark ? 0.15 : 0.08),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: widget.accentColor.withValues(alpha: isDark ? 0.22 : 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                widget.iconData,
                                size: 13,
                                color: widget.accentColor,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                widget.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
