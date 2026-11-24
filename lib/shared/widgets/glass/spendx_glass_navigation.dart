import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';
import 'spendx_glass_surface.dart';

class SpendXNavItem {
  final IconData icon;
  final IconData? activeIcon;
  final String label;
  final String? compactLabel;

  const SpendXNavItem({
    required this.icon,
    this.activeIcon,
    required this.label,
    this.compactLabel,
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
    final compact = MediaQuery.sizeOf(context).width < 360;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final navigationHeight = 66.0 + ((textScale - 1).clamp(0.0, 1.0) * 40.0);

    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            bottomInset > 0 ? bottomInset + 6 : 14,
          ),
          child: SpendXGlassSurface(
            level: SpendXGlassLevel.floating,
            height: navigationHeight,
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
                    compact: compact,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onItemSelected(index);
                    },
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassNavItem extends StatelessWidget {
  final SpendXNavItem item;
  final bool isSelected;
  final bool isDark;
  final bool compact;
  final VoidCallback onTap;

  const _GlassNavItem({
    required this.item,
    required this.isSelected,
    required this.isDark,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final activeColor = AppTheme.primaryBlue;
    final inactiveColor = isDark
        ? const Color(0xFF8896AB)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: isSelected,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 220),
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
                          ? const [Color(0x406558E8), Color(0x255245CC)]
                          : const [Color(0x1F6558E8), Color(0x106558E8)],
                    )
                  : null,
              border: isSelected
                  ? Border.all(
                      color: isDark
                          ? const Color(0x608B82F6)
                          : const Color(0x356558E8),
                      width: 1,
                    )
                  : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: activeColor.withValues(
                          alpha: isDark ? 0.35 : 0.18,
                        ),
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
                      ? (isDark ? const Color(0xFF8B82F6) : activeColor)
                      : inactiveColor,
                ),
                const SizedBox(height: 2),
                Text(
                  compact ? (item.compactLabel ?? item.label) : item.label,
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
        ),
      ),
    );
  }
}
