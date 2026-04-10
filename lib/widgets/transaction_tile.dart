import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';
import '../core/constants/category_meta.dart';
import '../theme/app_theme.dart';
import '../services/settings_service.dart';
import '../shared/widgets/app_card.dart';
import '../models/transaction.dart';
import '../models/category.dart';
import '../utils/app_format.dart';
import '../utils/text_formatter.dart';

class TransactionTile extends StatelessWidget {
  final Transaction transaction;
  final Category? category;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;
  final VoidCallback? onConvertToRecurring;

  const TransactionTile({
    super.key,
    required this.transaction,
    this.category,
    this.onTap,
    this.onEdit,
    this.onDelete,
    this.onDuplicate,
    this.onConvertToRecurring,
  });

  String _formatAmount(double amount) {
    return AppFormat.currency(amount);
  }

  /// Smart subtitle: shows notes + source badge.
  /// Only labels that ADD meaning — no "Card" (implied), no "Manual" (obvious).
  String _buildSubtitle() {
    final src = transaction.source;
    final isAuto = src == 'sms_auto' || src == 'sms_import' || src == 'sms_review';
    final isLoan = src == 'loan_payment';
    final isTransfer = src == 'bank_transfer';

    // Only show labels that add meaning
    final sourceLabel = isAuto
        ? 'Auto-detected'
        : isLoan
            ? 'Loan EMI'
            : isTransfer
                ? 'Transfer'
                : null;

    // Build: "notes \u00b7 source" or "date \u00b7 source" or just notes/date
    final notesText = transaction.notes.isNotEmpty
        ? transaction.notes
        : DateFormat('dd MMM, h:mm a').format(transaction.date);

    if (sourceLabel != null) {
      // Truncate notes if needed to fit source label
      final maxNotes = 25;
      final truncated = notesText.length > maxNotes
          ? '${notesText.substring(0, maxNotes)}...'
          : notesText;
      return '$truncated \u00b7 $sourceLabel';
    }

    return notesText;
  }

  Widget _buildIcon(Category? category, Color color, {double size = 24}) {
    // If source is a special ledger type, override category icon
    IconData? specialIcon;
    switch (transaction.source) {
      case 'credit_purchase':
        specialIcon = Icons.shopping_bag;
        break;
      case 'credit_payment':
        specialIcon = Icons.account_balance_wallet;
        break;
      case 'emi_installment':
        specialIcon = Icons.repeat;
        break;
      case 'loan_disbursement':
      case 'loan_payment':
        specialIcon = Icons.account_balance;
        break;
      case 'fuel_expense':
        specialIcon = Icons.local_gas_station;
        break;
    }

    if (specialIcon != null) {
      return Icon(specialIcon, color: color, size: size);
    }

    if (category != null) {
      final meta = CategoryMetaMap.resolve(category.name, category.type);
      return Icon(meta.icon, color: color, size: size);
    }

    final icon = category?.icon;
    if (icon == null || icon.isEmpty) {
      return Icon(Icons.category_rounded, color: color, size: size);
    }
    if (icon.length <= 2) {
      return Text(
        icon,
        style: TextStyle(fontSize: size, decoration: TextDecoration.none),
      );
    }

    IconData iconData;
    switch (icon) {
      case 'restaurant':
        iconData = Icons.restaurant;
        break;
      case 'directions_car':
        iconData = Icons.directions_car;
        break;
      case 'local_gas_station':
        iconData = Icons.local_gas_station;
        break;
      case 'shopping_bag':
        iconData = Icons.shopping_bag;
        break;
      case 'home':
        iconData = Icons.home;
        break;
      case 'bolt':
        iconData = Icons.bolt;
        break;
      case 'movie':
        iconData = Icons.movie;
        break;
      case 'payments':
        iconData = Icons.payments;
        break;
      case 'health_and_safety':
        iconData = Icons.health_and_safety;
        break;
      default:
        iconData = Icons.category_rounded;
    }
    return Icon(iconData, color: color, size: size);
  }

  Color? _specialIconColor(String source) {
    if (source == 'income' ||
        source == 'lending_received' ||
        source == 'credit_payment' ||
        source == 'refund' ||
        source == 'loan_disbursement') {
      return Colors.green;
    }
    if (source == 'transfer') return Colors.blue;
    if (source == 'emi_installment' || source == 'loan_payment') {
      return Colors.orange;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Watch settings to trigger rebuild on currency changes
    context.watch<SettingsService>();
    final cs = Theme.of(context).colorScheme;

    // Standardized Color Rules
    Color amountColor = cs.error; // Default red
    String sign = '-';

    final type = transaction.type.trim().toLowerCase();
    final source = transaction.source;
    if (type == 'income' ||
        source == 'income' ||
        source == 'lending_received' ||
        source == 'refund' ||
        source == 'loan_disbursement') {
      amountColor = Colors.green;
      sign = '+';
    } else if (type == 'transfer' ||
        source == 'transfer' ||
        source == 'credit_payment') {
      amountColor = Colors.blue;
      sign = '→';
    } else if (type == 'expense' ||
        source == 'emi_installment' ||
        source == 'loan_payment') {
      // Future installments could be yellow, but for now let's stick to expense red
      amountColor = cs.error;
    }

    final Color categoryColor = category != null
        ? CategoryMetaMap.resolve(category!.name, category!.type).color
        : (_specialIconColor(transaction.source) ?? cs.outline);

    final tile = AppCard(
      borderRadius: AppRadius.l,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        horizontalTitleGap: 10,
        minLeadingWidth: 38,
        titleAlignment: ListTileTitleAlignment.center,
        contentPadding: AppSpacing.cardPadding,
        onTap: onTap,
        leading: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: categoryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppRadius.m),
          ),
          child: Center(child: _buildIcon(category, categoryColor)),
        ),
        title: Text(
          TextFormatter.toSmartTitleCase(category?.name ?? 'Needs Category'),
          style: AppTextStyles.titleMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2.0),
          child: Text(
            _buildSubtitle(),
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          ),
        ),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 108),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                "$sign ${_formatAmount(transaction.amount)}",
                style: AppTextStyles.titleMedium.copyWith(
                  color: amountColor,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
              ),
              const SizedBox(height: 2),
              Text(
                DateFormat('dd MMM').format(transaction.date),
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );

    final canSlide =
        onEdit != null ||
        onDelete != null ||
        onDuplicate != null ||
        onConvertToRecurring != null;

    if (!canSlide) {
      return tile;
    }

    return Slidable(
      key: ValueKey(transaction.id),
      startActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.42,
        children: [
          if (onDuplicate != null)
            SlidableAction(
              onPressed: (_) => onDuplicate?.call(),
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
              icon: Icons.copy_rounded,
              label: 'Dup',
              borderRadius: BorderRadius.circular(AppRadius.l),
            ),
          if (onConvertToRecurring != null)
            SlidableAction(
              onPressed: (_) => onConvertToRecurring?.call(),
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              icon: Icons.autorenew_rounded,
              label: 'Rec',
              borderRadius: BorderRadius.circular(AppRadius.l),
            ),
        ],
      ),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.42,
        children: [
          if (onEdit != null)
            SlidableAction(
              onPressed: (_) => onEdit?.call(),
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              icon: Icons.edit_outlined,
              label: 'Edit',
              borderRadius: BorderRadius.circular(AppRadius.l),
            ),
          if (onDelete != null)
            SlidableAction(
              onPressed: (_) => onDelete?.call(),
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
              icon: Icons.delete_outline,
              label: 'Del',
              borderRadius: BorderRadius.circular(16),
            ),
        ],
      ),
      child: tile,
    );
  }
}
