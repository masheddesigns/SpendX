import 'package:flutter/material.dart';
import 'glass/spendx_states.dart';

class EmptyStateWidget extends StatelessWidget {
  const EmptyStateWidget({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.ctaLabel,
    this.onCtaTap,
  });

  final IconData icon;
  final String title;
  final String? description;
  final String? ctaLabel;
  final VoidCallback? onCtaTap;

  @override
  Widget build(BuildContext context) {
    return SpendXEmptyState(
      icon: icon,
      title: title,
      subtitle: description ?? '',
      actionLabel: ctaLabel,
      onAction: onCtaTap,
    );
  }
}
