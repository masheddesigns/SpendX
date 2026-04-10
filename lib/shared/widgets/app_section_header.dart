import 'package:flutter/material.dart';

/// Standardized section header with optional action button.
///
/// Use for: "Recent Transactions [View All]", "Accounts [+ Add]", etc.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.padding = EdgeInsets.zero,
    this.actionText,
    this.onAction,
  });

  final String title;
  final EdgeInsetsGeometry padding;
  final String? actionText;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (actionText != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionText!),
            ),
        ],
      ),
    );
  }
}
