import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../models/category.dart';
import '../utils/app_format.dart';

class TransactionTile extends StatelessWidget {
  final Transaction transaction;
  final Category? category;
  final VoidCallback? onTap;

  const TransactionTile({
    super.key,
    required this.transaction,
    this.category,
    this.onTap,
  });

  String _formatAmount(double amount) {
    return AppFormat.currency(amount);
  }

  Widget _buildIcon(String? icon, Color color, {double size = 24}) {
    if (icon == null || icon.isEmpty) return Icon(Icons.category, color: color, size: size);
    if (icon.length <= 2) {
      return Text(icon, style: TextStyle(fontSize: size));
    }
    
    IconData iconData;
    switch (icon) {
      case 'restaurant': iconData = Icons.restaurant; break;
      case 'directions_car': iconData = Icons.directions_car; break;
      case 'local_gas_station': iconData = Icons.local_gas_station; break;
      case 'shopping_bag': iconData = Icons.shopping_bag; break;
      case 'home': iconData = Icons.home; break;
      case 'bolt': iconData = Icons.bolt; break;
      case 'movie': iconData = Icons.movie; break;
      case 'payments': iconData = Icons.payments; break;
      case 'health_and_safety': iconData = Icons.health_and_safety; break;
      default: iconData = Icons.category;
    }
    return Icon(iconData, color: color, size: size);
  }

  Color _hexToColor(String? hex, Color defaultColor) {
    if (hex == null) return defaultColor;
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return defaultColor;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool isIncome = transaction.type == 'income';
    final Color amountColor = isIncome ? cs.primary : cs.error; // Green for income, Red for expense
    final String sign = isIncome ? '+' : '-';
    
    final Color categoryColor = category != null 
        ? _hexToColor(category!.color, cs.secondary)
        : cs.outline;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.outline.withValues(alpha: 0.1), width: 0.5)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: onTap,
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: categoryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: _buildIcon(
            category?.icon,
            categoryColor,
          ),
        ),
        title: Text(
          category?.name ?? 'Uncategorized',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: cs.onSurface),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Text(
            transaction.notes.isNotEmpty ? transaction.notes : DateFormat('MMM dd, yyyy').format(transaction.date),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              "$sign ${_formatAmount(transaction.amount)}",
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 16,
                color: amountColor,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              DateFormat('h:mm a').format(transaction.date),
              style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
