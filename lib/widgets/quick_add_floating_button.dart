import 'package:flutter/material.dart';
import 'package:spend_x/widgets/common/spendx_fab.dart';

class QuickAddFloatingButton extends StatelessWidget {
  final VoidCallback onPressed;

  const QuickAddFloatingButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SpendXFAB(
      icon: Icons.add_rounded,
      label: 'Quick Add',
      onPressed: onPressed,
    );
  }
}
