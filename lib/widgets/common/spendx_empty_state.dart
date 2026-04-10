import 'package:flutter/material.dart';

import '../../shared/widgets/empty_state_widget.dart';

class SpendXEmptyState extends StatelessWidget {
  const SpendXEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onActionPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onActionPressed;

  @override
  Widget build(BuildContext context) {
    return EmptyStateWidget(
      icon: icon,
      title: title,
      description: description,
      ctaLabel: actionLabel,
      onCtaTap: onActionPressed,
    );
  }
}
