import 'package:flutter/material.dart';

class CategoryColorPicker extends StatelessWidget {
  final String selectedColor;
  final Function(String) onColorSelected;

  const CategoryColorPicker({
    super.key,
    required this.selectedColor,
    required this.onColorSelected,
  });

  static const List<Map<String, String>> palette = [
    {'name': 'Green', 'hex': '#22C55E'},
    {'name': 'Blue', 'hex': '#3B82F6'},
    {'name': 'Purple', 'hex': '#A855F7'},
    {'name': 'Orange', 'hex': '#F97316'},
    {'name': 'Red', 'hex': '#EF4444'},
    {'name': 'Teal', 'hex': '#14B8A6'},
    {'name': 'Yellow', 'hex': '#EAB308'},
    {'name': 'Pink', 'hex': '#EC4899'},
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Pick a Color', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey)),
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: palette.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = palette[index];
              final hex = item['hex']!;
              final color = Color(int.parse(hex.replaceAll('#', '0xFF')));
              final isSelected = selectedColor.toUpperCase() == hex.toUpperCase();

              return GestureDetector(
                onTap: () => onColorSelected(hex),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.white : Colors.transparent,
                      width: 3,
                    ),
                    boxShadow: isSelected ? [
                      BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8, spreadRadius: 2)
                    ] : null,
                  ),
                  child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
