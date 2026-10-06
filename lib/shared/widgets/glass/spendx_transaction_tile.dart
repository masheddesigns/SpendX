import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/category.dart';
import '../../../models/transaction.dart';
import '../../../theme/app_theme.dart';
import 'spendx_financial_amount.dart';

/// High-density transaction row designed for grouped Liquid Glass containers.
///
/// Implements Section 8 of C15-A-R1:
/// - Renders as content inside a glass material, NOT a standalone card
/// - Zero redundant blur layers (high performance)
/// - Subtle category icon pill
/// - Strong typography and semantic amount colors
class SpendXTransactionTile extends StatelessWidget {
  final Transaction transaction;
  final Category? category;
  final String? accountName;
  final VoidCallback? onTap;
  final bool isPendingReview;
  final bool showDivider;

  const SpendXTransactionTile({
    super.key,
    required this.transaction,
    this.category,
    this.accountName,
    this.onTap,
    this.isPendingReview = false,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isExpense = transaction.type == 'expense';
    final isIncome = transaction.type == 'income';
    final isTransfer = transaction.type == 'transfer';

    FinancialSemanticType semanticType;
    if (isIncome) {
      semanticType = FinancialSemanticType.income;
    } else if (isExpense) {
      semanticType = FinancialSemanticType.expense;
    } else {
      semanticType = FinancialSemanticType.transfer;
    }

    // Category icon and color
    IconData iconData = Icons.receipt_long_rounded;
    Color iconColor = AppTheme.primaryBlue;

    if (category != null) {
      iconColor = _parseColor(category!.color) ?? iconColor;
    }

    if (isTransfer) {
      iconData = Icons.swap_horiz_rounded;
      iconColor = AppTheme.semanticTransfer;
    }

    final dateStr = DateFormat('dd MMM').format(transaction.date);
    final title = transaction.notes.isNotEmpty
        ? transaction.notes
        : (category?.name ?? (isTransfer ? 'Transfer' : 'Transaction'));

    return InkWell(
      onTap: onTap,
      splashColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      highlightColor: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.05),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Category Icon Pill
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: isDark ? 0.16 : 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(
                      color: iconColor.withValues(alpha: isDark ? 0.25 : 0.18),
                      width: 0.5,
                    ),
                  ),
                  child: Icon(iconData, size: 19, color: iconColor),
                ),
                const SizedBox(width: 12),

                // Title & Subtitle Metadata
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppTheme.darkTextPrimary
                                    : AppTheme.lightTextPrimary,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          if (isPendingReview) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: AppTheme.semanticWarning
                                    .withValues(alpha: 0.18),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.xs),
                                border: Border.all(
                                  color: AppTheme.semanticWarning
                                      .withValues(alpha: 0.4),
                                  width: 0.5,
                                ),
                              ),
                              child: const Text(
                                'REVIEW',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.semanticWarning,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (accountName != null && accountName!.isNotEmpty) ...[
                            Text(
                              accountName!,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w400,
                                color: isDark
                                    ? AppTheme.darkTextSecondary
                                    : AppTheme.lightTextSecondary,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '•',
                              style: TextStyle(
                                fontSize: 10,
                                color: isDark
                                    ? AppTheme.darkTextMuted
                                    : AppTheme.lightTextMuted,
                              ),
                            ),
                            const SizedBox(width: 5),
                          ],
                          Text(
                            dateStr,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w400,
                              color: isDark
                                  ? AppTheme.darkTextSecondary
                                  : AppTheme.lightTextSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Amount
                SpendXFinancialAmount(
                  amount: transaction.amount,
                  semanticType: semanticType,
                  size: FinancialAmountSize.standard,
                  showSign: !isTransfer,
                ),
              ],
            ),
          ),
          if (showDivider)
            Container(
              margin: const EdgeInsets.only(left: 66, right: 16),
              height: 0.5,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
            ),
        ],
      ),
    );
  }

  Color? _parseColor(String colorStr) {
    try {
      final hex = colorStr.replaceAll('#', '');
      if (hex.length == 6) {
        return Color(int.parse('0xFF$hex'));
      } else if (hex.length == 8) {
        return Color(int.parse('0x$hex'));
      }
    } catch (_) {}
    return null;
  }
}
