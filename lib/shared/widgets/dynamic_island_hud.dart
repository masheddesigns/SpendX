import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../services/dynamic_island_service.dart';

class DynamicIslandHUD extends StatefulWidget {
  final Widget child;

  const DynamicIslandHUD({super.key, required this.child});

  @override
  State<DynamicIslandHUD> createState() => _DynamicIslandHUDState();
}

class _DynamicIslandHUDState extends State<DynamicIslandHUD>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _expandAnimation;
  late final Animation<double> _fadeAnimation;

  StreamSubscription<DynamicIslandEvent>? _subscription;
  DynamicIslandEvent? _currentEvent;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      reverseDuration: const Duration(milliseconds: 250),
    );

    _expandAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    _subscription = DynamicIslandService.instance.events.listen(_onEvent);
  }

  void _onEvent(DynamicIslandEvent event) {
    _dismissTimer?.cancel();
    setState(() {
      _currentEvent = event;
    });

    _controller.forward(from: 0.0);

    _dismissTimer = Timer(const Duration(milliseconds: 3800), () {
      if (mounted) {
        _controller.reverse().then((_) {
          if (mounted) {
            setState(() {
              _currentEvent = null;
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _subscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final topOffset = topPadding > 0 ? topPadding - 2 : 12.0;

    return Stack(
      children: [
        widget.child,
        if (_currentEvent != null)
          Positioned(
            top: topOffset,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final prog = _expandAnimation.value;
                if (prog <= 0.01) return const SizedBox.shrink();

                final width = lerpDouble(60.0, 310.0, prog)!;
                final height = lerpDouble(24.0, 50.0, prog)!;
                final isExpense = _currentEvent!.isExpense;
                final accentColor = isExpense ? const Color(0xFFF43F5E) : const Color(0xFF10B981);
                final amountColor = isExpense ? const Color(0xFFFCA5A5) : const Color(0xFF34D399);

                return Center(
                  child: GestureDetector(
                    onVerticalDragEnd: (details) {
                      if (details.primaryVelocity != null && details.primaryVelocity! < 0) {
                        _dismissTimer?.cancel();
                        _controller.reverse();
                      }
                    },
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: Container(
                        width: width,
                        height: height,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D0D12),
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(
                            color: accentColor.withValues(alpha: 0.35 * prog),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.6 * prog),
                              blurRadius: 18,
                              spreadRadius: 1,
                              offset: const Offset(0, 4),
                            ),
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.18 * prog),
                              blurRadius: 12,
                              spreadRadius: 0,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: prog < 0.6
                            ? const SizedBox.shrink()
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // SpendX Micro Flame / Gem
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: accentColor.withValues(alpha: 0.15),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      isExpense ? Icons.arrow_outward_rounded : Icons.south_west_rounded,
                                      size: 16,
                                      color: accentColor,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  // Text Column
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${isExpense ? "-" : "+"} ${_currentEvent!.amount}',
                                          maxLines: 1,
                                          style: TextStyle(
                                            color: amountColor,
                                            fontSize: 14.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -0.2,
                                            fontFeatures: const [FontFeature.tabularFigures()],
                                          ),
                                        ),
                                        Text(
                                          _currentEvent!.subtitle.isNotEmpty
                                              ? _currentEvent!.subtitle
                                              : (isExpense ? 'Spent' : 'Received'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xFF9CA3AF),
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Direction Badge
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: accentColor.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      isExpense ? 'EXPENSE' : 'INCOME',
                                      style: TextStyle(
                                        color: accentColor,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
