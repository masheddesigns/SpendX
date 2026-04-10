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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: availableCategories.map((category) {
        final selected = category.id == selectedCategoryId;
        final meta = CategoryMetaMap.resolve(category.name, category.type);
        return ChoiceChip(
          avatar: Icon(
            meta.icon,
            size: 18,
            color: selected ? (activeColor ?? meta.color) : meta.color,
          ),
          label: Text(category.name),
          selected: selected,
          selectedColor: (activeColor ?? Theme.of(context).colorScheme.primary)
              .withValues(alpha: 0.18),
          onSelected: (_) => onCategorySelected(category.id),
        );
      }).toList(),
    );
  }
}
