import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';
import 'spendx_glass_surface.dart';

class SpendXNavItem {
  final IconData icon;
  final IconData? activeIcon;
  final String label;

  const SpendXNavItem({
    required this.icon,
    this.activeIcon,
    required this.label,
  });
}

/// Floating Liquid Glass Navigation Bar.
///
/// Implements Section 10 of C15-A-R1:
/// - Visibly floats above scrolling environmental content
/// - Multi-layer backdrop blur (sigma 28)
/// - Ambient floating drop shadow (Material 3 — Floating Glass)
/// - Top specular edge sheen
/// - Selected item has an elevated glass pill material change
/// - Maximum legibility and crisp icons
/// - Respects Android system gesture navigation insets
class SpendXGlassNavigation extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final List<SpendXNavItem> items;

  const SpendXGlassNavigation({
    super.key,
    required this.selectedIndex,
    required this.onItemSelected,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        bottomInset > 0 ? bottomInset + 6 : 14,
      ),
      child: SpendXGlassSurface(
        level: SpendXGlassLevel.floating,
        height: 66,
        borderRadius: BorderRadius.circular(AppRadius.full),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(items.length, (index) {
            final item = items[index];
            final isSelected = selectedIndex == index;
            return Expanded(
              child: _GlassNavItem(
                item: item,
                isSelected: isSelected,
                isDark: isDark,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onItemSelected(index);
                },
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _GlassNavItem extends StatelessWidget {
  final SpendXNavItem item;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _GlassNavItem({
    required this.item,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = AppTheme.primaryBlue;
    final inactiveColor =
        isDark ? const Color(0xFF8896AB) : const Color(0xFF64748B);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.full),
          gradient: isSelected
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? const [
                          Color(0x403B82F6), // Elevated blue glass pill
                          Color(0x241D4ED8),
                        ]
                      : const [
                          Color(0x283B82F6),
                          Color(0x181D4ED8),
                        ],
                )
              : null,
          border: isSelected
              ? Border.all(
                  color: isDark
                      ? const Color(0x6060A5FA)
                      : const Color(0x403B82F6),
                  width: 0.75,
                )
              : null,
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: activeColor.withValues(alpha: isDark ? 0.35 : 0.20),
                    blurRadius: 10,
                    spreadRadius: -1,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSelected ? (item.activeIcon ?? item.icon) : item.icon,
              size: 21,
              color: isSelected
                  ? (isDark ? const Color(0xFF60A5FA) : activeColor)
                  : inactiveColor,
            ),
            const SizedBox(height: 2),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? (isDark ? Colors.white : activeColor)
                    : inactiveColor,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
