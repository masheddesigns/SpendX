import 'package:flutter/material.dart';
import '../../../shared/theme/app_theme.dart';

enum SalaryFilterTab { all, received, pending, partial }

class SalaryStatusTabs extends StatelessWidget {
  const SalaryStatusTabs({
    super.key,
    required this.selectedTab,
    required this.onTabChanged,
  });

  final SalaryFilterTab selectedTab;
  final Function(SalaryFilterTab) onTabChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m, vertical: AppSpacing.s),
      child: Row(
        children: SalaryFilterTab.values.map((tab) {
          final isSelected = selectedTab == tab;
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s),
            child: ChoiceChip(
              label: Text(_getTabLabel(tab)),
              selected: isSelected,
              onSelected: (selected) {
                if (selected) onTabChanged(tab);
              },
              selectedColor: cs.primaryContainer,
              labelStyle: TextStyle(
                color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _getTabLabel(SalaryFilterTab tab) {
    switch (tab) {
      case SalaryFilterTab.all:
        return 'All';
      case SalaryFilterTab.received:
        return 'Received';
      case SalaryFilterTab.pending:
        return 'Pending';
      case SalaryFilterTab.partial:
        return 'Partial';
    }
  }
}
