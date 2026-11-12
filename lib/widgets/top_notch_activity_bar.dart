import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/haptic_service.dart';
import '../services/sync_activity_service.dart';

/// A sleek Dynamic Island / Top-Notch status pill that animates from the camera notch
/// whenever background data loading, SMS ingestion, or account reconciliation occurs.
class TopNotchActivityBar extends StatefulWidget {
  const TopNotchActivityBar({super.key});

  @override
  State<TopNotchActivityBar> createState() => _TopNotchActivityBarState();
}

class _TopNotchActivityBarState extends State<TopNotchActivityBar>
    with TickerProviderStateMixin {
  late final AnimationController _slideController;
  late final Animation<double> _slideAnimation;
  late final Animation<double> _scaleAnimation;

  late final AnimationController _pulseController;
  late final AnimationController _rotationController;

  SyncStage _lastStage = SyncStage.idle;

  @override
  void initState() {
    super.initState();

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    _slideAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInBack,
    );

    _scaleAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _slideController,
        curve: Curves.easeOutCubic,
      ),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    SyncActivityService.instance.addListener(_handleSyncChange);
  }

  @override
  void dispose() {
    SyncActivityService.instance.removeListener(_handleSyncChange);
    _slideController.dispose();
    _pulseController.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  void _handleSyncChange() {
    final state = SyncActivityService.instance.state;
    if (state.isVisible && !_slideController.isCompleted && !_slideController.isAnimating) {
      HapticService.instance.tap();
      _slideController.forward();
    } else if (!state.isVisible && _slideController.value > 0) {
      _slideController.reverse();
    }

    if (state.stage == SyncStage.completed && _lastStage != SyncStage.completed) {
      HapticService.instance.success();
    }
    _lastStage = state.stage;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _slideController,
        _pulseController,
        _rotationController,
        SyncActivityService.instance,
      ]),
      builder: (context, _) {
        final state = SyncActivityService.instance.state;
        if (_slideController.value == 0 && !state.isVisible) {
          return const SizedBox.shrink();
        }

        final isCompleted = state.stage == SyncStage.completed;
        final isError = state.stage == SyncStage.error;

        final primaryGlow = isCompleted
            ? const Color(0xFF10B981) // Emerald
            : isError
                ? const Color(0xFFEF4444) // Red
                : const Color(0xFF6366F1); // Indigo / Violet

        final accentGlow = isCompleted
            ? const Color(0xFF34D399)
            : isError
                ? const Color(0xFFF87171)
                : const Color(0xFF38BDF8); // Sky blue

        return Transform.translate(
          offset: Offset(0, (1.0 - _slideAnimation.value) * -65),
          child: Opacity(
            opacity: _slideAnimation.value.clamp(0.0, 1.0),
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6.0, left: 16.0, right: 16.0),
                  child: GestureDetector(
                    onTap: () {
                      HapticService.instance.tap();
                      SyncActivityService.instance.dismiss();
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(26),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A).withValues(alpha: 0.90), // Deep obsidian
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                              color: primaryGlow.withValues(alpha: 0.35 + (_pulseController.value * 0.2)),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: primaryGlow.withValues(alpha: 0.25 * _pulseController.value),
                                blurRadius: 18,
                                spreadRadius: 1,
                                offset: const Offset(0, 4),
                              ),
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.6),
                                blurRadius: 12,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 160,
                              maxWidth: 360,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Left Icon / Indicator
                                _buildStatusIndicator(isCompleted, isError, primaryGlow, accentGlow),
                                const SizedBox(width: 10),

                                // Center Content
                                Flexible(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              state.title.isNotEmpty ? state.title : 'Live Ingestion',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 0.2,
                                              ),
                                            ),
                                          ),
                                          if (state.itemsCount > 0 && !isCompleted) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: primaryGlow.withValues(alpha: 0.2),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: Text(
                                                '${state.itemsCount}',
                                                style: TextStyle(
                                                  color: accentGlow,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      if (state.subtitle.isNotEmpty) ...[
                                        const SizedBox(height: 1),
                                        Text(
                                          state.subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.70),
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),

                                const SizedBox(width: 10),

                                // Right Progress / Wave Indicator
                                _buildRightTrailing(state, isCompleted, primaryGlow),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusIndicator(
    bool isCompleted,
    bool isError,
    Color primaryGlow,
    Color accentGlow,
  ) {
    if (isCompleted) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: primaryGlow.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.check_rounded,
          color: Color(0xFF10B981),
          size: 18,
        ),
      );
    }

    if (isError) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: primaryGlow.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.error_outline_rounded,
          color: Color(0xFFEF4444),
          size: 18,
        ),
      );
    }

    // Active live sync: Dual spinning ring around glowing core
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Rotating outer gradient ring
          RotationTransition(
            turns: _rotationController,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    primaryGlow.withValues(alpha: 0.0),
                    accentGlow.withValues(alpha: 0.6),
                    primaryGlow,
                  ],
                ),
              ),
            ),
          ),
          // Inner core mask
          Container(
            width: 21,
            height: 21,
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              shape: BoxShape.circle,
            ),
          ),
          // Inner glowing pulsing dot / icon
          ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1.15).animate(
              CurvedAnimation(
                parent: _pulseController,
                curve: Curves.easeInOut,
              ),
            ),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: accentGlow,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: accentGlow.withValues(alpha: 0.8),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightTrailing(SyncActivityState state, bool isCompleted, Color primaryGlow) {
    if (isCompleted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: primaryGlow.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: primaryGlow.withValues(alpha: 0.3), width: 0.8),
        ),
        child: const Text(
          'Done',
          style: TextStyle(
            color: Color(0xFF34D399),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    // If explicit progress provided
    if (state.progress != null && state.progress! > 0) {
      return SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          value: state.progress,
          strokeWidth: 2.2,
          backgroundColor: Colors.white.withValues(alpha: 0.1),
          valueColor: AlwaysStoppedAnimation<Color>(primaryGlow),
        ),
      );
    }

    // Mini animated Equalizer / Audio Wave Bars (3 bars bouncing smoothly)
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        final phaseOffset = i * (math.pi / 3);
        final heightFactor = 0.3 + 0.7 * (0.5 + 0.5 * math.sin(_rotationController.value * 2 * math.pi + phaseOffset));
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 1.2),
          width: 2.5,
          height: 5 + (heightFactor * 11),
          decoration: BoxDecoration(
            color: primaryGlow.withValues(alpha: 0.7 + (heightFactor * 0.3)),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}
