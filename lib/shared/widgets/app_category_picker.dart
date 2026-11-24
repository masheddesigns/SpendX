import 'package:flutter/material.dart';

import '../../core/constants/category_meta.dart';
import '../../models/category.dart';
import '../../theme/app_theme.dart';

class AppCategoryPicker extends StatelessWidget {
  const AppCategoryPicker({
    super.key,
    required this.availableCategories,
    required this.selectedCategoryId,
    required this.onCategorySelected,
    this.activeColor,
  });

  final List<Category> availableCategories;
  final String? selectedCategoryId;
  final ValueChanged<String> onCategorySelected;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: availableCategories.map((category) {
        final selected = category.id == selectedCategoryId;
        final meta = CategoryMetaMap.resolve(category.name, category.type);
        final tintColor = activeColor ?? meta.color;

        return Semantics(
          button: true,
          selected: selected,
          label: 'Category ${category.name}',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onCategorySelected(category.id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Center(
                widthFactor: 1,
                child: AnimatedContainer(
                  duration: context.motionDuration(const Duration(milliseconds: 180)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: selected
                        ? tintColor.withValues(alpha: isDark ? 0.22 : 0.16)
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected
                          ? tintColor.withValues(alpha: isDark ? 0.60 : 0.45)
                          : Theme.of(context).colorScheme.outline,
                      width: selected ? 1.0 : 0.75,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        meta.icon,
                        size: 16,
                        color: selected
                            ? tintColor
                            : (Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          category.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            color: selected
                                ? (Theme.of(context).colorScheme.onSurface)
                                : (Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
