import 'package:flutter/material.dart';

class ExpenseTile extends StatelessWidget {
  final String title;
  final String amount;

  const ExpenseTile({
    super.key,
    required this.title,
    required this.amount,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.attach_money),
      title: Text(title),
      trailing: Text(amount),
    );
  }
}