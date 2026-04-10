import 'package:flutter/material.dart';

class QuickActionItemData {
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const QuickActionItemData({
    required this.title,
    required this.icon,
    required this.onTap,
    required this.color,
  });
}

class QuickActionsRow extends StatelessWidget {
  final List<QuickActionItemData> items;

  const QuickActionsRow({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int index = 0; index < items.length; index++) ...[
            _QuickActionItem(item: items[index]),
            if (index != items.length - 1) const SizedBox(width: 16),
          ],
        ],
      ),
    );
  }
}

class _QuickActionItem extends StatelessWidget {
  final QuickActionItemData item;

  const _QuickActionItem({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: item.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: item.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(item.icon, color: item.color, size: 28),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 72,
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
