import 'package:flutter/material.dart';
import '../../../screens/expense/add_expense_screen.dart';
import '../../../shared/widgets/app_page_route.dart';
import '../../../shared/widgets/spendx_glass.dart';
import '../../../theme/app_theme.dart';

/// Restrained Liquid Glass Quick Actions Row.
///
/// Implements Section 9 of C15-A-R1:
/// - Fast one-tap access to Expense, Income, Transfer
/// - Floating glass pill controls with subtle accent tinting
/// - Dynamic pressed-state tactile scale (0.96)
/// - Directional specular rim highlight
/// - Restrained visual weight; avoids heavy opaque filled buttons
class QuickActionsRow extends StatelessWidget {
  const QuickActionsRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: SpendXGlassButton(
              height: 42,
              accentColor: AppTheme.semanticExpense,
              icon: Icons.remove_circle_outline_rounded,
              onPressed: () => _openExpense(context),
              child: const Text('Expense'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SpendXGlassButton(
              height: 42,
              accentColor: AppTheme.semanticIncome,
              icon: Icons.add_circle_outline_rounded,
              onPressed: () => _openIncome(context),
              child: const Text('Income'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SpendXGlassButton(
              height: 42,
              accentColor: AppTheme.primaryBlue,
              icon: Icons.swap_horiz_rounded,
              onPressed: () => _openTransfer(context),
              child: const Text('Transfer'),
            ),
          ),
        ],
      ),
    );
  }

  void _openExpense(BuildContext context) {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => const AddExpenseScreen(initialType: 'expense'),
      ),
    );
  }

  void _openIncome(BuildContext context) {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => const AddExpenseScreen(initialType: 'income'),
      ),
    );
  }

  void _openTransfer(BuildContext context) {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => const AddExpenseScreen(initialType: 'transfer'),
      ),
    );
  }
}
