import 'package:flutter/material.dart';

import '../../core/constants/category_meta.dart';
import '../../models/category.dart';

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

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => onCategorySelected(category.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? tintColor.withValues(alpha: isDark ? 0.22 : 0.16)
                  : (isDark ? const Color(0x14FFFFFF) : const Color(0x40FFFFFF)),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected
                    ? tintColor.withValues(alpha: isDark ? 0.60 : 0.45)
                    : (isDark ? const Color(0x24FFFFFF) : const Color(0x18000000)),
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
                      : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                ),
                const SizedBox(width: 6),
                Text(
                  category.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? (isDark ? Colors.white : const Color(0xFF0F172A))
                        : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155)),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
