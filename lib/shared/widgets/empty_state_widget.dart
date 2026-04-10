import 'package:flutter/material.dart';
import 'primary_button.dart';

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
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24.0),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 48, color: cs.primary),
          ),
          const SizedBox(height: 24.0),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onSurface),
          ),
          if (description != null) ...[
            const SizedBox(height: 12.0),
            Text(
              description!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          if (ctaLabel != null && onCtaTap != null) ...[
            const SizedBox(height: 24.0),
            PrimaryButton(
              label: ctaLabel!,
              onPressed: onCtaTap,
            ),
          ],
        ],
      ),
    );
  }
}
