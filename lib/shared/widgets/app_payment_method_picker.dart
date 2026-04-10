import 'package:flutter/material.dart';

class PaymentMethodItem {
  const PaymentMethodItem({
    required this.id,
    required this.name,
    required this.type,
    required this.icon,
  });

  final String id;
  final String name;
  final String type;
  final IconData icon;
}

class AppPaymentMethodPicker extends StatelessWidget {
  const AppPaymentMethodPicker({
    super.key,
    required this.availableMethods,
    required this.selectedMethodId,
    required this.onMethodSelected,
    this.activeColor,
  });

  final List<PaymentMethodItem> availableMethods;
  final String? selectedMethodId;
  final ValueChanged<String?> onMethodSelected;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final highlight = activeColor ?? cs.primary;

    return Wrap(
      spacing: 12.0,
      runSpacing: 12.0,
      children: availableMethods.map((method) {
        final selected = method.id == selectedMethodId;
        return ChoiceChip(
          avatar: Icon(
            method.icon,
            size: 16,
            color: selected ? Colors.white : cs.onSurfaceVariant,
          ),
          label: Text(method.name),
          selected: selected,
          onSelected: (_) => onMethodSelected(method.id),
          selectedColor: highlight,
          backgroundColor: cs.surfaceContainer,
          labelStyle: TextStyle(
            color: selected ? Colors.white : cs.onSurface,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12.0),
          ),
        );
      }).toList(),
    );
  }
}

