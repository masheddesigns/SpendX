import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../screens/expense/add_expense_screen.dart';
import '../../../screens/financial_health_screen.dart';
import '../../../services/haptic_service.dart';
import '../../../shared/widgets/app_page_route.dart';
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

    final streak = streakAsync.valueOrNull?.current ?? 1;

    // Check if transactions have been logged today
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayCount = paginatedTxns.items
        .where((t) => !t.date.isBefore(todayStart))
        .length;

    final String rhythmCaption = todayCount > 0
        ? "Today's money story has started"
        : "Keep your money story up to date";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          // ── Prominent Tactile Action: "[ + Log activity ]" ──
          _HeroLogButton(
            isDark: isDark,
            onTap: () => _openScreen(context, 'expense'),
          ),

          const SizedBox(height: 8),

          // ── Fast-path Direct Chips: Spent, Received, Moved ──
          Row(
            children: [
              Expanded(
                child: _QuickChip(
                  label: 'Spent',
                  iconData: Icons.arrow_outward_rounded,
                  accentColor: const Color(0xFFE11D48),
                  isDark: isDark,
                  onTap: () => _openScreen(context, 'expense'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickChip(
                  label: 'Received',
                  iconData: Icons.arrow_downward_rounded,
                  accentColor: const Color(0xFF16A34A),
                  isDark: isDark,
                  onTap: () => _openScreen(context, 'income'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickChip(
                  label: 'Moved',
                  iconData: Icons.swap_horiz_rounded,
                  accentColor: const Color(0xFF4F46E5),
                  isDark: isDark,
                  onTap: () => _openScreen(context, 'transfer'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          // ── Seamless Canvas Tracking Rhythm (Cardless, Organic) ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticService.instance.tap();
              Navigator.push(
                context,
                AppPageRoute(builder: (_) => const FinancialHealthScreen()),
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
                        color: isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF78716C),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SpendXRhythmVectorToken(streak: streak, isDark: isDark),
                        const SizedBox(width: 6),
                        Text(
                          '$streak ${streak == 1 ? 'DAY' : 'DAYS'}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // Rhythm Path: ○ ─── ◉ ─── ○ ─── ○ ─── ○
                _buildRhythmTrack(isDark, todayLogged: todayCount > 0),

                const SizedBox(height: 8),

                // Supportive, Clean Subtitle
                Center(
                  child: Text(
                    rhythmCaption,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// The 5-day rolling rhythm track (○ ─── ◉ ─── ○ ─── ○)
  Widget _buildRhythmTrack(bool isDark, {required bool todayLogged}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // Connecting hairline
            Container(
              height: 1.2,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              color: isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : const Color(0xFFE2DDD2),
            ),

            // 5 Rolling Rhythm Nodes
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Day -2
                _RhythmNode(isCompleted: true, isToday: false, isDark: isDark),
                // Day -1
                _RhythmNode(isCompleted: true, isToday: false, isDark: isDark),
                // Today
                _RhythmNode(
                  isCompleted: todayLogged,
                  isToday: true,
                  isDark: isDark,
                ),
                // Day +1
                _RhythmNode(isCompleted: false, isToday: false, isDark: isDark),
                // Day +2
                _RhythmNode(isCompleted: false, isToday: false, isDark: isDark),
              ],
            ),
          ],
        );
      },
    );
  }

  void _openScreen(BuildContext context, String type) {
    HapticService.instance.tap();
    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => AddExpenseScreen(initialType: type),
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
  final bool isDark;

  const _SpendXRhythmVectorToken({
    required this.streak,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(18, 18),
      painter: _RhythmTokenPainter(streak: streak, isDark: isDark),
    );
  }
}

class _RhythmTokenPainter extends CustomPainter {
  final int streak;
  final bool isDark;

  _RhythmTokenPainter({required this.streak, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);

    final color = isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706);

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
        ..color = isDark ? const Color(0xFF161922) : Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 2.0, innerPaint);
    } else if (streak >= 3) {
      // ○╱╲ Growing Rhythm: Dual climbing sprout mark
      final strokePaint = Paint()
        ..color = isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A)
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
        ..color = isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, size.height - 2), 1.8, baseDot);
    } else {
      // ○╱ Starting Rhythm: Emerging seed & diagonal trail mark
      final circlePaint = Paint()
        ..color = isDark ? const Color(0xFFFB923C) : const Color(0xFFEA580C)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx - 3, cy + 3), 3.0, circlePaint);

      final ascentPaint = Paint()
        ..color = isDark ? const Color(0xFFFB923C) : const Color(0xFFEA580C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(cx - 1, cy + 1), Offset(cx + 5, cy - 5), ascentPaint);
      canvas.drawCircle(Offset(cx + 5, cy - 5), 1.5, circlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RhythmTokenPainter oldDelegate) {
    return oldDelegate.streak != streak || oldDelegate.isDark != isDark;
  }
}

class _RhythmNode extends StatelessWidget {
  final bool isCompleted;
  final bool isToday;
  final bool isDark;

  const _RhythmNode({
    required this.isCompleted,
    required this.isToday,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    if (isToday) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: isCompleted ? const Color(0xFF4F46E5) : (isDark ? const Color(0xFF1E2330) : Colors.white),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF818CF8),
                width: 2.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4F46E5).withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: isCompleted
                ? const Center(
                    child: Icon(Icons.check, size: 9, color: Colors.white),
                  )
                : null,
          ),
          const SizedBox(height: 4),
          Text(
            'TODAY',
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
            ),
          ),
        ],
      );
    }

    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: isCompleted
            ? (isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8))
            : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2DDD2)),
        shape: BoxShape.circle,
        border: Border.all(
          color: isCompleted
              ? (isDark ? const Color(0xFF94A3B8) : const Color(0xFFCBD5E1))
              : (isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFD6CEBF)),
          width: 1.2,
        ),
      ),
    );
  }
}

class _HeroLogButton extends StatefulWidget {
  final bool isDark;
  final VoidCallback onTap;

  const _HeroLogButton({
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_HeroLogButton> createState() => _HeroLogButtonState();
}

class _HeroLogButtonState extends State<_HeroLogButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark
        ? const Color(0xFF1E2330)
        : const Color(0xFF1C1917);
    final fg = Colors.white;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          height: 48,
          width: double.infinity,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: widget.isDark
                    ? Colors.black.withValues(alpha: 0.35)
                    : const Color(0x201C1917),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.add_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Log activity',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatefulWidget {
  final String label;
  final IconData iconData;
  final Color accentColor;
  final bool isDark;
  final VoidCallback onTap;

  const _QuickChip({
    required this.label,
    required this.iconData,
    required this.accentColor,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_QuickChip> createState() => _QuickChipState();
}

class _QuickChipState extends State<_QuickChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark
        ? const Color(0xFF161922)
        : const Color(0xFFFFFFFF);
    final border = widget.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFECE5D8);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border, width: 0.9),
            boxShadow: [
              BoxShadow(
                color: widget.isDark
                    ? Colors.black.withValues(alpha: 0.18)
                    : const Color(0x061C1917),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: widget.accentColor.withValues(alpha: widget.isDark ? 0.20 : 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.iconData,
                  size: 12,
                  color: widget.accentColor,
                ),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: widget.isDark
                        ? Colors.white.withValues(alpha: 0.95)
                        : const Color(0xFF1C1917),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
