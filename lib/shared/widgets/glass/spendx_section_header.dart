import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';

/// Clean, high-density section header for SpendX.
class SpendXSectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const SpendXSectionHeader({
    super.key,
    required this.title,
    this.count,
    this.actionLabel,
    this.onAction,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sectionTitle = Row(
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: MediaQuery.textScalerOf(context).scale(1) > 1.1 ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.sectionHeading.copyWith(
              color: context.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: context.textMuted,
              ),
            ),
          ),
        ],
      ],
    );

    final trailingWidget = actionLabel != null && onAction != null
        ? Semantics(
            button: true,
            label: actionLabel,
            child: GestureDetector(
              onTap: onAction,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(
                  child: Text(
                    actionLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryBlue,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
              ),
            ),
          )
        : trailing;

    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: sectionTitle),
          ?trailingWidget,
        ],
      ),
    );
  }
}
