import 'package:flutter/material.dart';

class SpendXBottomSheet extends StatelessWidget {
  const SpendXBottomSheet({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  static Future<T?> show<T>(BuildContext context, {required dynamic builder}) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        if (builder is Widget Function(BuildContext, StateSetter)) {
          return StatefulBuilder(
            builder: (context, setState) => builder(context, setState),
          );
        }
        if (builder is Widget Function(BuildContext)) {
          return builder(context);
        }
        throw ArgumentError('Unsupported SpendXBottomSheet builder signature');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final insets = MediaQuery.viewInsetsOf(context);

    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SingleChildScrollView(
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: child,
        ),
      ),
    );
  }
}
