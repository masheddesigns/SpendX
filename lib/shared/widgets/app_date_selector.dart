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
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: selectedDate,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onDateSelected(picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.calendar_today_rounded),
        ),
        child: Text(DateFormat('dd MMM yyyy').format(selectedDate)),
      ),
    );
  }
}
