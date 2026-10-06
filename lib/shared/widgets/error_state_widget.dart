import 'package:flutter/material.dart';
import 'glass/spendx_states.dart';

class ErrorStateWidget extends StatelessWidget {
  const ErrorStateWidget({
    super.key,
    required this.error,
    this.onRetry,
    this.icon = Icons.error_outline_rounded,
    this.title = 'Something went wrong',
  });

  final Object error;
  final VoidCallback? onRetry;
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return SpendXErrorState(
      message: error.toString(),
      onRetry: onRetry,
    );
  }
}
