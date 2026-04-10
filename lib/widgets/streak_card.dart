import '../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/gamification_service.dart';
import '../utils/page_transitions.dart';
import '../screens/gamification_detail_screen.dart';
import 'animated_widgets.dart';

class StreakCard extends StatefulWidget {
// ... (rest remains same)
  const StreakCard({super.key});

  @override
  State<StreakCard> createState() => _StreakCardState();
}

class _StreakCardState extends State<StreakCard> {
// ... (rest remains same)
  int _streak = 0;
  bool _loggedToday = false;
  DateTime? _lastLogDate;
  String _quote = '';
  bool _loading = true;
  bool _isDismissed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final streak = await GamificationService.instance.getCurrentStreak();
    final loggedToday = await GamificationService.instance.hasLoggedToday();
    final lastLog = await GamificationService.instance.getLastLoggedDate();
    final quote = await GamificationService.instance.getDailyQuote();

    final prefs = await SharedPreferences.getInstance();
    final dismissedStr = prefs.getString('streak_dismissed_date');
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    bool dismissed = (dismissedStr == todayStr);

    if (mounted) {
      setState(() {
        _streak = streak;
        _loggedToday = loggedToday;
        _lastLogDate = lastLog;
        _quote = quote;
        _isDismissed = dismissed;
        _loading = false;
      });
    }
  }

  Future<void> _dismiss() async {
    HapticService.instance.success();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('streak_dismissed_date', DateFormat('yyyy-MM-dd').format(DateTime.now()));
    setState(() => _isDismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, -0.1), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: (_loading || _isDismissed)
          ? const SizedBox.shrink()
          : AnimatedScaleWrapper(
              onTap: () => Navigator.push(context, SlideFadeTransition(page: const GamificationDetailScreen())),
              child: _buildCard(),
            ),
    );
  }

  Widget _buildCard() {
    final cs = Theme.of(context).colorScheme;
    final streakColor = _loggedToday ? Colors.orange : cs.onSurfaceVariant;

    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(24),
// ... (rest remains same)
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _loggedToday
                  ? cs.primary.withValues(alpha: 0.4)
                  : cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Streak badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: streakColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: streakColor.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _streak > 0 ? '🔥' : '⭕',
                          style: const TextStyle(fontSize: 16, decoration: TextDecoration.none),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Streak',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$_streak days',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right, color: Colors.white.withValues(alpha: 0.5), size: 18),
                  const SizedBox(width: 8),
                  // Today status
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _loggedToday
                          ? Colors.green.withValues(alpha: 0.15)
                          : Colors.red.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _loggedToday ? '✓ Logged' : '! Log today',
                      style: TextStyle(
                        fontSize: 11,
                        color: _loggedToday ? Colors.green[400] : Colors.red[400],
                        fontWeight: FontWeight.w800,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Quote
              Text(
                _quote,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
              if (_lastLogDate != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Last logged: ${DateFormat('EEE, MMM d').format(_lastLogDate!)}',
                  style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 11, decoration: TextDecoration.none),
                ),
              ],
            ],
          ),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: IconButton(
            onPressed: _dismiss,
            icon: Icon(Icons.close, size: 18, color: cs.onSurfaceVariant),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
          ),
        ),
      ],
    );
  }
}
