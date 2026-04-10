import 'package:flutter/material.dart';

enum StatusChipType {
  received,
  pending,
  delayed,
  hold,
  neutral,
  danger,
  success,
  warning,
  error,
  info,
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.type});

  final String label;
  final StatusChipType type;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final (background, foreground) = switch (type) {
      StatusChipType.received || StatusChipType.success => (
        Colors.green.withValues(alpha: 0.15),
        Colors.green,
      ),
      StatusChipType.pending || StatusChipType.warning => (
        Colors.orange.withValues(alpha: 0.15),
        Colors.orange,
      ),
      StatusChipType.delayed ||
      StatusChipType.danger ||
      StatusChipType.error => (cs.error.withValues(alpha: 0.15), cs.error),
      StatusChipType.hold || StatusChipType.neutral || StatusChipType.info => (
        cs.secondary.withValues(alpha: 0.15),
        cs.secondary,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(30.0),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
