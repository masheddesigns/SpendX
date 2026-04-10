import '../../../services/haptic_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/service_providers.dart';
import '../../../shared/theme/app_theme.dart';

class QuickActions extends ConsumerWidget {
  final VoidCallback onAddExpense;
  final VoidCallback onAddIncome;
  final VoidCallback onScanBill;

  const QuickActions({
    super.key,
    required this.onAddExpense,
    required this.onAddIncome,
    required this.onScanBill,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isIncomeDisabled = ref.watch(
      settingsProvider.select((s) => s.isIncomeDisabled),
    );
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick Actions',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 2.2,
            children: [
              _ActionButton(
                icon: Icons.add_circle_outline_rounded,
                label: 'Add Expense',
                color: cs.error,
                onTap: onAddExpense,
              ),
              if (!isIncomeDisabled)
                _ActionButton(
                  icon: Icons.arrow_downward_rounded,
                  label: 'Add Income',
                  color: AppTheme.successColor,
                  onTap: onAddIncome,
                ),
              _ActionButton(
                icon: Icons.notifications_active_outlined,
                label: 'Add Reminder',
                color: AppTheme.warningColor,
                onTap: () {
                  // Haptic handled in _ActionButton
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () {
        HapticService.instance.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
