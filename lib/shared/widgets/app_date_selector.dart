import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class AppDateSelector extends StatelessWidget {
  const AppDateSelector({
    super.key,
    required this.selectedDate,
    required this.onDateSelected,
  });

  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final fillColor = isDark
        ? const Color(0x1AFFFFFF)
        : const Color(0x66FFFFFF);

    final borderColor = isDark
        ? const Color(0x2EFFFFFF)
        : const Color(0x1F000000);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: selectedDate,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onDateSelected(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 0.75),
        ),
        child: Row(
          children: [
            Icon(
              Icons.calendar_today_rounded,
              size: 20,
              color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
            ),
            const SizedBox(width: 12),
            Text(
              DateFormat('dd MMM yyyy').format(selectedDate),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            const Spacer(),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ],
        ),
      ),
    );
  }
}
