import 'package:flutter/material.dart';

class CategoryIconPicker extends StatelessWidget {
  final String selectedIcon;
  final Function(String) onIconSelected;

  const CategoryIconPicker({
    super.key,
    required this.selectedIcon,
    required this.onIconSelected,
  });

  static const List<String> defaultIcons = [
    // Food & Dining
    '🍔', '🍕', '🍜', '🍗', '🍣', '🍦', '☕', '🍺', '🍱',
    // Shopping
    '🛍️', '👕', '👟', '🎁', '💄', '⌚',
    // Transport
    '🚗', '🚌', '🚕', '🚆', '🚲', '✈️', '⛽', '🚢',
    // Health & Wellness
    '🏥', '💊', '🧘', '🏃', '🦷', '💪',
    // Entertainment
    '🎬', '🎮', '🎧', '🎟️', '🎤', '🎲',
    // Bills & Utilities
    '💡', '📱', '🌐', '🚿', '🔥', '🏢',
    // Finance
    '💰', '📈', '💳', '🏧', '🏦', '💎',
    // Travel & Leisure
    '🏖️', '🧳', '⛺', '📸', '🎡', '⛰️',
    // Education
    '📚', '📝', '🎓', '📓', '✏️',
    // Groceries
    '🛒', '🥦', '🍎', '🥕', '🥩', '🥛',
    // Home
    '🏠', '🔨', '📦', '🧹', '🛋️',
    // Pets
    '🐶', '🐱', '🦜',
    // Misc
    '🌲', '🔋', '📫'
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Pick an Icon', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey)),
        const SizedBox(height: 12),
        Container(
          height: 200,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
          ),
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: defaultIcons.length,
            itemBuilder: (context, index) {
              final icon = defaultIcons[index];
              final isSelected = selectedIcon == icon;
              return GestureDetector(
                onTap: () => onIconSelected(icon),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      isSelected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
                      BlendMode.srcIn,
                    ),
                    child: Text(icon, style: const TextStyle(fontSize: 24)),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
