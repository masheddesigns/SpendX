import 'package:flutter/material.dart';
import 'common/spendx_bottom_sheet.dart';

class QuickAddBottomSheet extends StatelessWidget {
  final bool isIncomeDisabled;
  final VoidCallback onAddExpense;
  final VoidCallback? onAddIncome;
  final VoidCallback onScanBill;
  final VoidCallback? onTransfer;
  final VoidCallback? onLend;

  const QuickAddBottomSheet({
    super.key,
    required this.isIncomeDisabled,
    required this.onAddExpense,
    this.onAddIncome,
    required this.onScanBill,
    this.onTransfer,
    this.onLend,
  });

  static Future<void> show(
    BuildContext context, {
    required bool isIncomeDisabled,
    required VoidCallback onAddExpense,
    VoidCallback? onAddIncome,
    required VoidCallback onScanBill,
    VoidCallback? onTransfer,
    VoidCallback? onLend,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SpendXBottomSheet(
        child: QuickAddBottomSheet(
          isIncomeDisabled: isIncomeDisabled,
          onAddExpense: onAddExpense,
          onAddIncome: onAddIncome,
          onScanBill: onScanBill,
          onTransfer: onTransfer,
          onLend: onLend,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final actions = <_QuickAddAction>[
      _QuickAddAction(
        label: 'Expense',
        icon: Icons.remove_circle_outline,
        color: cs.error,
        onTap: onAddExpense,
      ),
      if (!isIncomeDisabled && onAddIncome != null)
        _QuickAddAction(
          label: 'Income',
          icon: Icons.add_circle_outline,
          color: cs.primary,
          onTap: onAddIncome!,
        ),
      _QuickAddAction(
        label: 'Scan Bill',
        icon: Icons.document_scanner_outlined,
        color: cs.tertiary,
        onTap: onScanBill,
      ),
      if (onTransfer != null)
        _QuickAddAction(
          label: 'Transfer',
          icon: Icons.swap_horiz_rounded,
          color: cs.secondary,
          onTap: onTransfer!,
        ),
      if (onLend != null)
        _QuickAddAction(
          label: 'Lend',
          icon: Icons.handshake_outlined,
          color: cs.primary,
          onTap: onLend!,
        ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Add',
          style: TextStyle(
            color: cs.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Choose what you want to add right now.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
        const SizedBox(height: 24),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: actions.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            mainAxisExtent: 82,
          ),
          itemBuilder: (context, index) {
            return _QuickAddActionTile(action: actions[index]);
          },
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _QuickAddAction {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickAddAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class _QuickAddActionTile extends StatelessWidget {
  final _QuickAddAction action;

  const _QuickAddActionTile({required this.action});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        Navigator.pop(context);
        action.onTap();
      },
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: action.color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: action.color.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: action.color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(action.icon, color: action.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                action.label,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
