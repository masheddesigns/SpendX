import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/app_theme.dart';
import 'spendx_glass_surface.dart';

/// Segmented Glass Control for switching views, periods, or modes.
class SpendXGlassSegmentedControl<T> extends StatelessWidget {
  final T selectedValue;
  final ValueChanged<T> onValueChanged;
  final Map<T, String> segments;

  const SpendXGlassSegmentedControl({
    super.key,
    required this.selectedValue,
    required this.onValueChanged,
    required this.segments,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SpendXGlassSurface(
      height: 40,
      blur: AppTheme.glassControlBlur,
      color: isDark ? AppTheme.darkSurface.withValues(alpha: 0.6) : AppTheme.lightSurface.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(AppRadius.full),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: segments.entries.map((entry) {
          final isSelected = entry.key == selectedValue;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (!isSelected) {
                  HapticFeedback.selectionClick();
                  onValueChanged(entry.key);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: isSelected
                      ? (isDark
                          ? AppTheme.primaryBlue.withValues(alpha: 0.30)
                          : AppTheme.primaryBlue.withValues(alpha: 0.15))
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: isSelected
                      ? Border.all(
                          color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.5 : 0.3),
                          width: 0.5,
                        )
                      : null,
                ),
                child: Center(
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected
                          ? (isDark ? Colors.white : AppTheme.primaryBlue)
                          : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Compact Glass Filter Chip.
class SpendXGlassChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final IconData? icon;

  const SpendXGlassChip({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = AppTheme.primaryBlue;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: SpendXGlassSurface(
        height: 32,
        blur: AppTheme.glassControlBlur,
        color: isSelected
            ? (isDark ? activeColor.withValues(alpha: 0.25) : activeColor.withValues(alpha: 0.15))
            : (isDark ? AppTheme.darkSurface.withValues(alpha: 0.5) : AppTheme.lightSurface.withValues(alpha: 0.6)),
        border: Border.all(
          color: isSelected
              ? activeColor.withValues(alpha: 0.5)
              : (isDark ? AppTheme.glassDarkBorderSubtle : AppTheme.glassLightBorderSubtle),
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(AppRadius.full),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: isSelected
                    ? (isDark ? Colors.white : activeColor)
                    : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? (isDark ? Colors.white : activeColor)
                    : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
