import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../screens/review/review_queue_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../review_queue/providers/review_providers.dart';

/// Mindful Pending Review indicator banner displayed on the Home Dashboard.
///
/// Prominently alerts the user when transactions or instrument matches require manual verification.
/// Updates reactively when items arrive and when items are resolved.
class HomeReviewIndicator extends ConsumerWidget {
  const HomeReviewIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewCountAsync = ref.watch(reviewQueueCountProvider);
    final reviewCount = reviewCountAsync.value ?? 0;
    if (reviewCount <= 0) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('home_review_queue_indicator'),
          onTap: () async {
            await Navigator.push(
              context,
              AppPageRoute(builder: (_) => const ReviewQueueScreen()),
            );
            ref.invalidate(reviewQueueCountProvider);
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDark
                    ? [const Color(0x33F59E0B), const Color(0x1AF59E0B)]
                    : [const Color(0xFFFEF3C7), const Color(0xFFFFFBEB)],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.4 : 0.6),
                width: 1.0,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.pending_actions_rounded,
                    color: Color(0xFFD97706),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reviewCount == 1
                            ? '1 transaction needs review'
                            : '$reviewCount transactions need review',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Tap to verify instrument and details',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? const Color(0xFFD1D5DB) : const Color(0xFFB45309),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$reviewCount',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
