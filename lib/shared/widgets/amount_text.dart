import 'package:flutter/material.dart';
import '../../utils/app_format.dart';
import '../../theme/app_theme.dart';

/// Standardized amount display for finance data.
///
/// Ensures consistent formatting, coloring, and sizing across the entire app.
/// Use this instead of manually formatting currency + choosing colors.
class AmountText extends StatelessWidget {
  final double amount;
  final bool isIncome;
  final bool emphasize;
  final bool showSign;
  final double? fontSize;

  const AmountText(
    this.amount, {
    super.key,
    required this.isIncome,
    this.emphasize = false,
    this.showSign = true,
    this.fontSize,
  });

  /// Auto-detect direction from amount sign.
  const AmountText.auto(
    this.amount, {
    super.key,
    this.emphasize = false,
    this.showSign = true,
    this.fontSize,
  }) : isIncome = amount >= 0;

  @override
  Widget build(BuildContext context) {
    final color = isIncome ? AppColors.success : AppColors.danger;
    final sign = showSign ? (isIncome ? '+' : '-') : '';
    final size = fontSize ?? (emphasize ? 22.0 : 14.0);

    return Text(
      '$sign ${AppFormat.currency(amount.abs())}',
      style: TextStyle(
        fontSize: size,
        fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
        color: color,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
