import 'package:flutter/material.dart';
import '../../shared/widgets/primary_button.dart';
import '../../services/haptic_service.dart';

class PrimaryActionButton extends StatelessWidget {
  const PrimaryActionButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.expand = false,
    this.hapticType = SpendXHapticType.tap,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;
  final bool expand;
  final SpendXHapticType hapticType;

  @override
  Widget build(BuildContext context) {
    return PrimaryButton(
      label: label,
      onPressed: onPressed,
      icon: icon,
      isLoading: isLoading,
      expand: expand,
      hapticType: hapticType,
    );
  }
}
