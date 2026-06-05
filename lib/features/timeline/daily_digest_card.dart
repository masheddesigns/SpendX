import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/decision_engine.dart';
import '../../services/retention_events.dart';
import '../../services/retention_service.dart';
import '../review_queue/providers/review_providers.dart';

/// Daily Loop card — the one card that defines today's state.
///
/// Strict priority (one signal only, never multiple CTAs):
///   1. Critical insight (overspend risk)
///   2. Pending reviews (action required)
///   3. High insight (goal delay)
///   4. Recovery prompt (returned after 2+ day absence)
///   5. All set (calm state)
///
/// Subtle UX:
///   - 250ms reveal delay → feels smooth
///   - Streak shown only when ≥2 days
///   - Accuracy trend shown only when delta ≥ 3%
class DailyDigestCard extends ConsumerStatefulWidget {
  final DecisionInsight? topInsight;
  final VoidCallback? onActionTap;

  const DailyDigestCard({
    super.key,
    this.topInsight,
    this.onActionTap,
  });

  @override
  ConsumerState<DailyDigestCard> createState() => _DailyDigestCardState();
}

class _DailyDigestCardState extends ConsumerState<DailyDigestCard> {
  int _streak = 0;
  (int, int)? _accuracyDelta;
  bool _isReturning = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Smooth reveal — prevents visual jump on app open
    Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  Future<void> _load() async {
    final retention = RetentionService.instance;
    final results = await Future.wait([
      retention.getStreak(),
      retention.accuracyDelta(),
      retention.isReturningAfterBreak(),
    ]);
    if (!mounted) return;
    setState(() {
      _streak = results[0] as int;
      _accuracyDelta = results[1] as (int, int)?;
      _isReturning = results[2] as bool;
    });
    // Observation: digest shown — once per session
    RetentionEvents.instance
        .log(RetentionEvent.dailyDigestShown, dedupeKey: 'digest');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reviewCount = ref.watch(reviewQueueCountProvider).valueOrNull ?? 0;
    final insight = widget.topInsight;

    // Strict priority — ONE state only
    final state = _resolveState(insight, reviewCount);
    _logStateOnce(state.kind);

    // Smooth reveal
    return AnimatedOpacity(
      opacity: _ready ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: AnimatedSlide(
        offset: _ready ? Offset.zero : const Offset(0, 0.05),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: state.color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: state.color.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(state.icon, color: state.color, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.title,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_streak >= 2)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('🔥', style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 4),
                          Text(
                            '$_streak',
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              if (state.body.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  state.body,
                  style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 13,
                      height: 1.4),
                ),
              ],
              if (state.actionLabel != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: state.color),
                    onPressed: () {
                      RetentionEvents.instance
                          .log(RetentionEvent.dailyDigestCtaClicked);
                      widget.onActionTap?.call();
                    },
                    child: Text(state.actionLabel!),
                  ),
                ),
              ] else if (state.kind == _StateKind.allSet &&
                  _shouldShowAccuracyTrend()) ...[
                const SizedBox(height: 10),
                _AccuracyTrendStrip(
                    oldest: _accuracyDelta!.$1,
                    latest: _accuracyDelta!.$2),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Log sub-state once per session (per-session dedupe in RetentionEvents).
  void _logStateOnce(_StateKind kind) {
    if (kind == _StateKind.allSet) {
      RetentionEvents.instance
          .log(RetentionEvent.allSetShown, dedupeKey: 'allset');
    } else if (kind == _StateKind.recovery) {
      RetentionEvents.instance
          .log(RetentionEvent.recoveryStateShown, dedupeKey: 'recovery');
    }
  }

  /// Strict priority resolver — ONE state, never multiple CTAs.
  _DigestState _resolveState(DecisionInsight? insight, int reviewCount) {
    final cs = Theme.of(context).colorScheme;

    // 1. CRITICAL — overspend risk dominates everything
    if (insight?.priority == InsightPriority.critical) {
      return _DigestState(
        kind: _StateKind.critical,
        color: cs.error,
        icon: Icons.priority_high_rounded,
        title: insight!.title,
        body: insight.body,
        actionLabel: insight.actionLabel ?? 'View',
      );
    }

    // 2. RECOVERY — returned after a break (more empathetic than reviews)
    if (_isReturning) {
      final friendly = reviewCount > 0
          ? 'Let\'s get things back in sync — $reviewCount transaction${reviewCount == 1 ? '' : 's'} to review.'
          : 'Welcome back. Things look calm right now.';
      return _DigestState(
        kind: _StateKind.recovery,
        color: cs.tertiary,
        icon: Icons.refresh_rounded,
        title: 'Welcome back',
        body: friendly,
        actionLabel: reviewCount > 0 ? 'Catch up' : null,
      );
    }

    // 3. PENDING REVIEWS — action required
    if (reviewCount > 0) {
      return _DigestState(
        kind: _StateKind.review,
        color: Colors.orange,
        icon: Icons.rate_review_outlined,
        title:
            '$reviewCount transaction${reviewCount == 1 ? '' : 's'} need your review',
        body: 'Quick taps to confirm or dismiss.',
        actionLabel: 'Review now',
      );
    }

    // 4. HIGH — goal delays etc.
    if (insight?.priority == InsightPriority.high) {
      return _DigestState(
        kind: _StateKind.high,
        color: Colors.orange,
        icon: Icons.flag_outlined,
        title: insight!.title,
        body: insight.body,
        actionLabel: insight.actionLabel ?? 'View',
      );
    }

    // 5. ALL SET — silence as success
    return _DigestState(
      kind: _StateKind.allSet,
      color: Colors.green,
      icon: Icons.check_circle_rounded,
      title: 'You\'re all set',
      body: _allSetMessage(),
    );
  }

  /// Rotating positive messages — silence should feel like success.
  String _allSetMessage() {
    final messages = [
      'Your money is on track.',
      'No action needed today — that\'s a good sign.',
      'Everything looks calm. Keep going.',
      'Steady habits are doing the work.',
    ];
    final index = DateTime.now().day % messages.length;
    return messages[index];
  }

  /// Only show accuracy trend when delta is meaningful (≥ 3%).
  bool _shouldShowAccuracyTrend() {
    if (_accuracyDelta == null) return false;
    return (_accuracyDelta!.$2 - _accuracyDelta!.$1) >= 3;
  }
}

class _AccuracyTrendStrip extends StatelessWidget {
  final int oldest;
  final int latest;
  const _AccuracyTrendStrip({required this.oldest, required this.latest});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.trending_up_rounded,
              color: Colors.green, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tracking improved from $oldest% → $latest%',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _StateKind { critical, recovery, review, high, allSet }

class _DigestState {
  final _StateKind kind;
  final Color color;
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;

  const _DigestState({
    required this.kind,
    required this.color,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
  });
}
