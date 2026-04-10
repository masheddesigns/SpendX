import 'package:flutter/material.dart';
import '../../../models/company.dart';
import '../../../shared/theme/app_theme.dart';

class CompanySelector extends StatelessWidget {
  const CompanySelector({
    super.key,
    required this.companies,
    this.selectedCompanyId,
    required this.onChanged,
    required this.onManagePressed,
  });

  final List<Company> companies;
  final String? selectedCompanyId;
  final Function(String) onChanged;
  final VoidCallback onManagePressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (companies.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.m),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.medium),
                border: Border.all(color: cs.outlineVariant, width: 0.5),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: selectedCompanyId ?? (companies.isNotEmpty ? companies.first.id : null),
                  isExpanded: true,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  items: companies.map((company) {
                    return DropdownMenuItem(
                      value: company.id,
                      child: Text(
                        company.name,
                        style: AppTextStyles.titleMedium.copyWith(color: cs.onSurface),
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) onChanged(value);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.m),
          IconButton.outlined(
            onPressed: onManagePressed,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Manage Companies',
          ),
        ],
      ),
    );
  }
}
