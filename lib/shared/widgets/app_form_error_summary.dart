import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

/// An accessible, top-of-form error summary banner.
///
/// Complies with accessibility guidelines (WCAG / ui-ux-pro-max):
/// - Uses [Semantics] with `liveRegion: true` to immediately announce validation failures.
/// - Lists all invalid fields in one consolidated place so users and assistive tech
///   do not need to hunt through a long form to find why submission was rejected.
/// - Respects reduced-motion settings when expanding.
class AppFormErrorSummary extends StatelessWidget {
  final List<String> errors;
  final VoidCallback? onDismiss;
  final EdgeInsetsGeometry margin;

  const AppFormErrorSummary({
    super.key,
    required this.errors,
    this.onDismiss,
    this.margin = const EdgeInsets.only(bottom: 16),
  });

  @override
  Widget build(BuildContext context) {
    if (errors.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final bannerContent = Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: cs.error.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                color: cs.onErrorContainer,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  errors.length == 1
                      ? 'Please correct the error below:'
                      : 'Please correct the following errors:',
                  style: TextStyle(
                    color: cs.onErrorContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: cs.onErrorContainer,
                  tooltip: 'Dismiss errors',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: onDismiss,
                ),
            ],
          ),
          const SizedBox(height: 8),
          ...errors.map(
            (err) => Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '• ',
                    style: TextStyle(
                      color: cs.onErrorContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      err,
                      style: TextStyle(
                        color: cs.onErrorContainer,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    final accessibilityLabel =
        'Form errors: ${errors.join('. ')}.';

    final widgetTree = Semantics(
      liveRegion: true,
      label: accessibilityLabel,
      child: bannerContent,
    );

    if (reduceMotion) {
      return widgetTree;
    }

    return AnimatedSize(
      duration: AppMotion.normal,
      curve: Curves.easeOutCubic,
      child: widgetTree,
    );
  }
}
