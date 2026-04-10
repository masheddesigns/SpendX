import 'package:flutter/material.dart';
import 'common/spendx_empty_state.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String? buttonText;
  final VoidCallback? onButtonPressed;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.buttonText,
    this.onButtonPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SpendXEmptyState(
      icon: icon,
      title: title,
      description: description,
      actionLabel: buttonText,
      onActionPressed: onButtonPressed,
    );
  }
}
