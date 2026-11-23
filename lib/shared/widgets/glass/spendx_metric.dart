import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import 'spendx_financial_amount.dart';

/// Financial metric tile displaying label, formatted value, and optional indicator.
class SpendXMetric extends StatelessWidget {
  final String label;
  final double amount;
  final FinancialSemanticType semanticType;
  final FinancialAmountSize size;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SpendXMetric({
    super.key,
    required this.label,
    required this.amount,
    this.semanticType = FinancialSemanticType.neutral,
    this.size = FinancialAmountSize.standard,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTextStyles.caption.copyWith(color: context.textMuted),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SpendXFinancialAmount(
              amount: amount,
              semanticType: semanticType,
              size: size,
            ),
            if (trailing != null) ...[const SizedBox(width: 6), trailing!],
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: TextStyle(fontSize: 11, color: context.textSecondary),
          ),
        ],
      ],
    );

    if (onTap == null) return content;
    return Semantics(
      button: true,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}
