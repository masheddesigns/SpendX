import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/haptic_service.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_format.dart';
import '../models/wrapped_summary.dart';
import '../../../shared/widgets/error_state_widget.dart';
import '../../../shared/widgets/skeleton_loader.dart';
import '../providers/wrapped_providers.dart';

/// Full-screen Wrapped experience — Stack-based with Instagram-style progress bars.
///
/// 5 slides: Identity → Personality → Behavior → Comparison → Verdict
class WrappedScreen extends ConsumerStatefulWidget {
  final String period;
  const WrappedScreen({super.key, required this.period});

  @override
  ConsumerState<WrappedScreen> createState() => _WrappedScreenState();
}

class _WrappedScreenState extends ConsumerState<WrappedScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late PageController _ctrl;
  late AnimationController _timerCtrl;
  int _page = 0;
  int _totalPages = 5;
  static const _slideDuration = Duration(seconds: 6);
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ctrl = PageController();
    _timerCtrl = AnimationController(vsync: this, duration: _slideDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_paused) _goNext();
      });
    // Slight delay before starting — prevents instant motion shock
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _timerCtrl.forward();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timerCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause timer when app goes background, resume when foreground
    if (state == AppLifecycleState.paused) {
      _timerCtrl.stop();
    } else if (state == AppLifecycleState.resumed && !_paused) {
      _timerCtrl.forward();
    }
  }

  void _goNext() {
    if (_page < _totalPages - 1) {
      _ctrl.nextPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _goPrev() {
    if (_page > 0) {
      _ctrl.previousPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  void _pauseTimer() {
    _paused = true;
    _timerCtrl.stop();
  }

  void _resumeTimer() {
    _paused = false;
    _timerCtrl.forward();
  }

  void _restartTimer() {
    _paused = false;
    _timerCtrl.reset();
    _timerCtrl.forward();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(wrappedSummaryProvider(widget.period));

    return Scaffold(
      backgroundColor: CinematicTheme.bg,
      body: async.when(
        loading: () => const SkeletonLoader.summary(),
        error: (e, _) => ErrorStateWidget(error: e, onRetry: () => ref.invalidate(wrappedSummaryProvider(widget.period))),
        data: (summary) {
          if (summary == null) {
            return const Center(
                child: Text('No data for this period',
                    style: TextStyle(color: Colors.grey)));
          }

          final hasComparison = summary.prevExpense != null;
          _totalPages = hasComparison ? 5 : 4;

          final pages = [
            _IdentitySlide(summary: summary),
            _PersonalitySlide(summary: summary),
            _BehaviorSlide(summary: summary),
            if (hasComparison) _ComparisonSlide(summary: summary),
            _VerdictSlide(summary: summary),
          ];

          return SafeArea(
            child: Stack(
              children: [
                // ── PageView ─────────────────────────────
                PageView(
                  controller: _ctrl,
                  onPageChanged: (i) {
                    HapticService.instance.selection();
                    setState(() => _page = i);
                    _restartTimer();
                  },
                  children: pages,
                ),

                // ── Tap zones: left(0-40%) | dead(40-60%) | right(60-100%) ──
                // Long-press pauses timer, release resumes
                Positioned.fill(
                  top: 60,
                  bottom: 80,
                  child: GestureDetector(
                    onLongPressStart: (_) => _pauseTimer(),
                    onLongPressEnd: (_) => _resumeTimer(),
                    child: Row(
                      children: [
                        // Left zone: 40% → previous
                        Flexible(
                          flex: 40,
                          child: GestureDetector(
                            onTap: _goPrev,
                            behavior: HitTestBehavior.translucent,
                            child: const SizedBox.expand(),
                          ),
                        ),
                        // Dead zone: 20% center → no action (prevents accidental taps)
                        const Flexible(
                          flex: 20,
                          child: SizedBox.expand(),
                        ),
                        // Right zone: 40% → next
                        Flexible(
                          flex: 40,
                          child: GestureDetector(
                            onTap: _goNext,
                            behavior: HitTestBehavior.translucent,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Progress bars with timer fill ─────────
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: AnimatedBuilder(
                    animation: _timerCtrl,
                    builder: (_, _) => Row(
                      children: List.generate(_totalPages, (i) {
                        double fill;
                        if (i < _page) {
                          fill = 1.0; // completed
                        } else if (i == _page) {
                          fill = _timerCtrl.value; // current — animating
                        } else {
                          fill = 0.0; // upcoming
                        }
                        return Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            height: 3,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: fill,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ),

                // ── Close button ─────────────────────────
                Positioned(
                  top: 24,
                  right: 12,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54, size: 22),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),

                // ── Done button (last page only) ─────────
                if (_page == _totalPages - 1)
                  Positioned(
                    bottom: 32,
                    left: 48,
                    right: 48,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Done',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// =========================================================================
// BASE SLIDE
// =========================================================================

class _BaseSlide extends StatelessWidget {
  final Widget child;
  const _BaseSlide({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(child: child),
    );
  }
}

// =========================================================================
// SLIDE 1: IDENTITY
// =========================================================================

class _IdentitySlide extends StatelessWidget {
  final WrappedSummary summary;
  const _IdentitySlide({required this.summary});

  @override
  Widget build(BuildContext context) {
    final net = summary.totalIncome - summary.totalExpense;
    final isPositive = net >= 0;

    return _BaseSlide(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(summary.label,
              style: TextStyle(color: CinematicTheme.textMuted,
                  fontSize: 14, letterSpacing: 3, fontWeight: FontWeight.w500)),
          const SizedBox(height: 40),
          Text('You handled',
              style: TextStyle(color: CinematicTheme.textSecondary, fontSize: 18)),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: summary.totalIncome),
            duration: const Duration(milliseconds: 1500),
            curve: Curves.easeOutExpo,
            builder: (_, v, _) => Text(
              AppFormat.currency(v),
              style: const TextStyle(color: Colors.white, fontSize: 44,
                  fontWeight: FontWeight.w800, letterSpacing: -1),
            ),
          ),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _MiniStat('Spent', AppFormat.currency(summary.totalExpense), Colors.redAccent),
              const SizedBox(width: 40),
              _MiniStat('Saved', AppFormat.currency(net.abs()),
                  isPositive ? Colors.greenAccent : Colors.redAccent),
            ],
          ),
          const SizedBox(height: 28),
          if (summary.prevExpense != null)
            Text(
              isPositive ? 'Better than last period' : 'Higher spending than before',
              style: TextStyle(
                color: isPositive ? Colors.greenAccent : Colors.orangeAccent,
                fontSize: 13, fontWeight: FontWeight.w500),
            ),
        ],
      ),
    );
  }
}

// =========================================================================
// SLIDE 2: PERSONALITY
// =========================================================================

class _PersonalitySlide extends StatelessWidget {
  final WrappedSummary summary;
  const _PersonalitySlide({required this.summary});

  String _quip(String topCat) {
    final l = topCat.toLowerCase();
    if (l.contains('food')) return 'Food was your weakness this time';
    if (l.contains('shopping')) return 'Shopping took the biggest slice';
    if (l.contains('transport') || l.contains('travel')) return 'You were on the move a lot';
    if (l.contains('entertainment') || l.contains('subscription')) return 'Entertainment kept you going';
    if (l.contains('bill')) return 'Bills kept the lights on';
    return '$topCat dominated your spending';
  }

  @override
  Widget build(BuildContext context) {
    final cats = summary.topCategories.take(5).toList();
    final colors = [Colors.blueAccent, Colors.redAccent, Colors.tealAccent,
        Colors.orangeAccent, Colors.purpleAccent];

    return _BaseSlide(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('You spent mostly on',
              style: TextStyle(color: CinematicTheme.textSecondary, fontSize: 16)),
          const SizedBox(height: 28),
          ...cats.asMap().entries.map((e) {
            final c = e.value;
            final color = colors[e.key % colors.length];
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                children: [
                  SizedBox(width: 90, child: Text(c.categoryName,
                      style: const TextStyle(color: Colors.white, fontSize: 14,
                          fontWeight: FontWeight.w600))),
                  Expanded(child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: c.percentage / 100,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation(color), minHeight: 8),
                  )),
                  const SizedBox(width: 10),
                  SizedBox(width: 36, child: Text('${c.percentage.toStringAsFixed(0)}%',
                      style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.right)),
                ],
              ),
            );
          }),
          const SizedBox(height: 20),
          if (cats.isNotEmpty)
            Text(_quip(cats.first.categoryName),
                style: TextStyle(color: CinematicTheme.textSecondary,
                    fontSize: 13, fontStyle: FontStyle.italic),
                textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

// =========================================================================
// SLIDE 3: BEHAVIOR
// =========================================================================

class _BehaviorSlide extends StatelessWidget {
  final WrappedSummary summary;
  const _BehaviorSlide({required this.summary});

  @override
  Widget build(BuildContext context) {
    return _BaseSlide(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Insight('\u{1F4B0}', 'Biggest Expense', AppFormat.currency(summary.biggestExpense)),
          const SizedBox(height: 14),
          if (summary.biggestCategory != null)
            _Insight('\u{1F3AF}', 'Top Category', summary.biggestCategory!),
          const SizedBox(height: 14),
          _Insight('\u{1F4CA}', 'Transactions', '${summary.transactionCount}'),
          const SizedBox(height: 14),
          _Insight('\u{1F4B5}', 'Savings Rate', '${summary.savingsRate.toStringAsFixed(0)}%'),
        ],
      ),
    );
  }
}

// =========================================================================
// SLIDE 4: COMPARISON
// =========================================================================

class _ComparisonSlide extends StatelessWidget {
  final WrappedSummary summary;
  const _ComparisonSlide({required this.summary});

  @override
  Widget build(BuildContext context) {
    final change = summary.expenseChange;
    final savedMore = change < 0;
    final diff = summary.prevExpense != null
        ? (summary.totalExpense - summary.prevExpense!).abs() : 0.0;

    return _BaseSlide(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(savedMore ? Icons.trending_down_rounded : Icons.trending_up_rounded,
              size: 56, color: savedMore ? Colors.greenAccent : Colors.orangeAccent),
          const SizedBox(height: 28),
          Text(
            savedMore
                ? 'You spent ${AppFormat.currency(diff)} less'
                : 'You spent ${AppFormat.currency(diff)} more',
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('than last period',
              style: TextStyle(color: CinematicTheme.textMuted, fontSize: 15)),
          const SizedBox(height: 28),
          Text(
            '${change > 0 ? "+" : ""}${change.toStringAsFixed(0)}%',
            style: TextStyle(
              color: savedMore ? Colors.greenAccent : Colors.orangeAccent,
              fontSize: 32, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 20),
          Text(savedMore ? 'Keep this momentum going!' : 'Let\'s work on this next month.',
              style: TextStyle(color: CinematicTheme.textSecondary,
                  fontSize: 13, fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}

// =========================================================================
// SLIDE 5: VERDICT
// =========================================================================

class _VerdictSlide extends StatelessWidget {
  final WrappedSummary summary;
  const _VerdictSlide({required this.summary});

  (String, String, Color) _verdict(double rate) {
    if (rate >= 30) return ('DISCIPLINED', '\u{1F4AA}', Colors.greenAccent);
    if (rate >= 15) return ('STABLE', '\u{1F44D}', Colors.blueAccent);
    if (rate >= 0) return ('IMPROVING', '\u{1F4C8}', Colors.orangeAccent);
    return ('IMPULSIVE', '\u{1F62C}', Colors.redAccent);
  }

  String _tip(WrappedSummary s) {
    if (s.topCategories.isEmpty) return 'Start tracking to see insights!';
    final top = s.topCategories.first;
    final weekly = (top.amount / 4).round();
    return 'Cut 1 ${top.categoryName} expense/week \u2192 save ${AppFormat.currency(weekly.toDouble())}/month';
  }

  @override
  Widget build(BuildContext context) {
    final (label, emoji, color) = _verdict(summary.savingsRate);

    return _BaseSlide(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 56)),
          const SizedBox(height: 12),
          Text('Your money habit',
              style: TextStyle(color: CinematicTheme.textMuted, fontSize: 14)),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: color, fontSize: 34,
              fontWeight: FontWeight.w900, letterSpacing: 3)),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: CinematicTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: CinematicTheme.border),
            ),
            child: Row(
              children: [
                const Text('\u{1F4A1}', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 12),
                Expanded(child: Text(_tip(summary),
                    style: TextStyle(color: CinematicTheme.textSecondary,
                        fontSize: 12, height: 1.4))),
              ],
            ),
          ),
          const SizedBox(height: 80), // space for bottom Done button
        ],
      ),
    );
  }
}

// =========================================================================
// SHARED ATOMS
// =========================================================================

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(label, style: TextStyle(color: CinematicTheme.textMuted, fontSize: 11)),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(color: color, fontSize: 17, fontWeight: FontWeight.bold)),
    ]);
  }
}

class _Insight extends StatelessWidget {
  final String emoji;
  final String title;
  final String value;
  const _Insight(this.emoji, this.title, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: CinematicTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CinematicTheme.border),
      ),
      child: Row(children: [
        Text(emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 14),
        Expanded(child: Text(title, style: TextStyle(
            color: CinematicTheme.textSecondary, fontSize: 13))),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 15,
            fontWeight: FontWeight.bold)),
      ]),
    );
  }
}
