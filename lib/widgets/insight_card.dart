import 'package:flutter/material.dart';
import '../models/insight.dart';

class InsightCard extends StatelessWidget {
  final Insight insight;

  const InsightCard({
    super.key,
    required this.insight,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Color accentColor;
    switch (insight.type) {
      case InsightType.warning: accentColor = cs.error; break;
      case InsightType.success: accentColor = Colors.green; break;
      case InsightType.info: accentColor = cs.primary; break;
      case InsightType.tip: accentColor = cs.tertiary; break;
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accentColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(insight.icon, color: accentColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  insight.type.name.toUpperCase(),
                  style: TextStyle(color: accentColor, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1),
                ),
                const SizedBox(height: 4),
                Text(
                  insight.title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  insight.description,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
