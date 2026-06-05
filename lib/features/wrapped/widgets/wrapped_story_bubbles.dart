import '../../../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/wrapped_providers.dart';
import '../screens/wrapped_screen.dart';
import '../../../shared/widgets/app_page_route.dart';

/// Horizontal scrollable story-style bubbles for the home screen.
/// Shows available Wrapped periods (latest first).
class WrappedStoryBubbles extends ConsumerWidget {
  const WrappedStoryBubbles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periodsAsync = ref.watch(availableWrappedPeriodsProvider);

    return periodsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (periods) {
        if (periods.isEmpty) return const SizedBox.shrink();

        return SizedBox(
          height: 80,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: periods.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final period = periods[index];
              final isYearly = !period.contains('-');
              final isWeekly = period.contains('-W');
              final label = isYearly
                  ? period
                  : isWeekly
                      ? 'Week ${period.split('-W').last}'
                      : _shortLabel(period);

              return GestureDetector(
                onTap: () { HapticService.instance.tap(); Navigator.push(
                  context,
                  AppPageRoute(
                      builder: (_) => WrappedScreen(period: period)),
                ); },
                child: Container(
                  width: 80,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isYearly
                          ? [Colors.deepPurple.shade700, Colors.deepPurple.shade400]
                          : isWeekly
                              ? [Colors.teal.shade700, Colors.teal.shade400]
                              : [Colors.blueAccent.shade700, Colors.blueAccent.shade200],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.15)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isYearly
                            ? Icons.auto_awesome_rounded
                            : isWeekly
                                ? Icons.date_range_rounded
                                : Icons.insights_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Text(
                        'Wrapped',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  String _shortLabel(String period) {
    final parts = period.split('-');
    if (parts.length != 2) return period;
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final m = int.tryParse(parts[1]) ?? 0;
    return months[m.clamp(1, 12)];
  }
}
