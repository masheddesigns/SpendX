import 'package:flutter/material.dart';

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16.0),
    this.gradient,
    this.backgroundColor,
    this.color,
    this.borderRadius = 16.0,
    this.border,
    this.onTap,
    this.onLongPress,
    this.margin,
    this.index,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Gradient? gradient;
  final Color? backgroundColor;
  final Color? color;
  final dynamic borderRadius;
  final dynamic border;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry? margin;
  final int? index;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;
    
    final BorderRadius resolvedInkRadius = switch (borderRadius) {
      BorderRadius radius => radius,
      BorderRadiusGeometry _ => BorderRadius.circular(16.0),
      double radius => BorderRadius.circular(radius),
      _ => BorderRadius.circular(16.0),
    };
    final BorderRadiusGeometry resolvedRadius = switch (borderRadius) {
      BorderRadiusGeometry radius => radius,
      double radius => BorderRadius.circular(radius),
      _ => BorderRadius.circular(16.0),
    };
    final Border? resolvedBorder = switch (border) {
      null => null,
      Border value => value,
      BorderSide side => Border.fromBorderSide(side),
      _ => null,
    };

    Widget card = Container(
      margin: margin,
      decoration: BoxDecoration(
        color: gradient == null
            ? (backgroundColor ?? color ?? cs.surfaceContainer)
            : null,
        gradient: gradient,
        borderRadius: resolvedRadius,
        border:
            resolvedBorder ??
            Border.all(
              color: isDark ? cs.outline : cs.outline.withValues(alpha: 0.5),
              width: 1,
            ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: resolvedInkRadius,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    return card;
  }
}
