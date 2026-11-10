import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/providers.dart';
import '../../../screens/net_worth_screen.dart';
import '../../../services/settings_service.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../utils/app_format.dart';

/// Clean Atmospheric Greeting Header.
///
/// Welcomes the user with human warmth, current date, and an ambient net worth anchor.
class DashboardGreetingHeader extends ConsumerWidget {
  const DashboardGreetingHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final netWorth = ref.watch(netWorthProvider);

    final now = DateTime.now();
    final greeting = _getGreeting(now.hour);
    final dateStr = DateFormat('EEEE, d MMMM').format(now);

    final email = SettingsService.instance.googleEmail;
    String displayName = '';
    if (email != null && email.isNotEmpty) {
      final namePart = email.split('@').first;
      if (namePart.isNotEmpty) {
        displayName = namePart[0].toUpperCase() + namePart.substring(1);
      }
    }

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Date & Minimal Net Worth Anchor
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Minimalist Date with warm indicator
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      dateStr.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.9,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF78716C),
                      ),
                    ),
                  ],
                ),

                // Net Worth Pebble (Minimalist)
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      AppPageRoute(builder: (_) => const NetWorthScreen()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E2330) : const Color(0xFFEEF2FF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : const Color(0xFFC7D2FE),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 13,
                          color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF4F46E5),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Net · ${AppFormat.compact(netWorth)}',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: isDark ? const Color(0xFFA5B4FC) : const Color(0xFF3730A3),
                            letterSpacing: -0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Expressive, Human Greeting
            Text(
              displayName.isNotEmpty ? '$greeting, $displayName' : greeting,
              style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.7,
                color: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF1C1917),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getGreeting(int hour) {
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }
}
