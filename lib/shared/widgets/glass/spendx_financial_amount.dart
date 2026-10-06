import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_format.dart';

enum FinancialSemanticType {
  neutral,
  income,
  expense,
  transfer,
  shortfall,
}

enum FinancialAmountSize {
  hero,     // 34px - Safe to Spend & Net Worth
  large,    // 26px - Card balances
  medium,   // 18px - Section totals
  standard, // 15px - List items
  compact,  // 13px - Subtitles, metadata
}

/// Formatted financial amount with tabular figures and semantic coloring.
class SpendXFinancialAmount extends StatelessWidget {
  final double amount;
  final FinancialSemanticType semanticType;
  final FinancialAmountSize size;
  final bool showSign;
  final String? prefix;
  final String? suffix;
  final Color? colorOverride;

  const SpendXFinancialAmount({
    super.key,
    required this.amount,
    this.semanticType = FinancialSemanticType.neutral,
    this.size = FinancialAmountSize.standard,
    this.showSign = false,
    this.prefix,
    this.suffix,
    this.colorOverride,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color color;
    if (colorOverride != null) {
      color = colorOverride!;
    } else {
      switch (semanticType) {
        case FinancialSemanticType.income:
          color = AppTheme.semanticIncome;
          break;
        case FinancialSemanticType.expense:
          color = AppTheme.semanticExpense;
          break;
        case FinancialSemanticType.transfer:
          color = AppTheme.semanticTransfer;
          break;
        case FinancialSemanticType.shortfall:
          color = AppTheme.semanticShortfall;
          break;
        case FinancialSemanticType.neutral:
          color = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
          break;
      }
    }

    double fontSize;
    double letterSpacing;
    FontWeight fontWeight;

    switch (size) {
      case FinancialAmountSize.hero:
        fontSize = 34;
        letterSpacing = -1.0;
        fontWeight = FontWeight.w700;
        break;
      case FinancialAmountSize.large:
        fontSize = 26;
        letterSpacing = -0.6;
        fontWeight = FontWeight.w700;
        break;
      case FinancialAmountSize.medium:
        fontSize = 18;
        letterSpacing = -0.3;
        fontWeight = FontWeight.w600;
        break;
      case FinancialAmountSize.standard:
        fontSize = 15;
        letterSpacing = -0.2;
        fontWeight = FontWeight.w600;
        break;
      case FinancialAmountSize.compact:
        fontSize = 13;
        letterSpacing = -0.1;
        fontWeight = FontWeight.w500;
        break;
    }

    final formattedText = AppFormat.currency(amount);
    String sign = '';
    if (showSign && amount > 0 && semanticType == FinancialSemanticType.income) {
      sign = '+';
    } else if (showSign && amount < 0) {
      sign = '-';
    }

    final displayText = '$sign${prefix ?? ''}$formattedText${suffix ?? ''}';

    return Text(
      displayText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
