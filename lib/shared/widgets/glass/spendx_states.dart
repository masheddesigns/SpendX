import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'spendx_glass_button.dart';
import 'spendx_glass_surface.dart';

/// Standardized Liquid Glass Loading Skeleton State.
class SpendXLoadingState extends StatefulWidget {
  final int count;
  final double itemHeight;

  const SpendXLoadingState({
    super.key,
    this.count = 4,
    this.itemHeight = 64,
  });

  @override
  State<SpendXLoadingState> createState() => _SpendXLoadingStateState();
}

class _SpendXLoadingStateState extends State<SpendXLoadingState>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final opacity = 0.3 + (_controller.value * 0.4);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: List.generate(widget.count, (index) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SpendXGlassSurface(
                  height: widget.itemHeight,
                  borderRadius: BorderRadius.circular(AppRadius.m),
                  color: isDark
                      ? AppTheme.darkElevated.withValues(alpha: opacity)
                      : AppTheme.lightElevated.withValues(alpha: opacity),
                  child: const SizedBox.expand(),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

/// Standardized Empty State.
class SpendXEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SpendXEmptyState({
    super.key,
    this.icon = Icons.inbox_rounded,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.darkElevated.withValues(alpha: 0.6)
                    : AppTheme.lightElevated.withValues(alpha: 0.8),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark ? AppTheme.glassDarkBorder : AppTheme.glassLightBorder,
                  width: 0.5,
                ),
              ),
              child: Icon(
                icon,
                size: 28,
                color: isDark ? AppTheme.darkTextMuted : AppTheme.lightTextMuted,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              SpendXGlassButton(
                variant: SpendXGlassButtonVariant.tonal,
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Standardized Error State with Retry Button.
class SpendXErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const SpendXErrorState({
    super.key,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppTheme.semanticExpense.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 24,
                color: AppTheme.semanticExpense,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Unable to load',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              SpendXGlassButton(
                variant: SpendXGlassButtonVariant.secondary,
                onPressed: onRetry,
                child: const Text('Try Again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Staged Review Warning Banner.
class SpendXReviewBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const SpendXReviewBanner({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warningColor = AppTheme.semanticWarning;

    return SpendXGlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      borderRadius: BorderRadius.circular(AppRadius.m),
      color: warningColor.withValues(alpha: isDark ? 0.14 : 0.10),
      border: Border.all(
        color: warningColor.withValues(alpha: 0.35),
        width: 0.5,
      ),
      onTap: onTap,
      child: Row(
        children: [
          Icon(Icons.rate_review_rounded, size: 20, color: warningColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count transaction${count == 1 ? '' : 's'} awaiting review',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFFB45309),
                letterSpacing: -0.1,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: isDark ? Colors.white70 : const Color(0xFFB45309),
          ),
        ],
      ),
    );
  }
}
