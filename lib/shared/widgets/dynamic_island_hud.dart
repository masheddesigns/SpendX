import 'package:flutter/material.dart';

/// Legacy HUD wrapper - Dynamic Island overlay was removed to prevent OS crashes
/// and notification listener interference. This is now a clean pass-through widget.
class DynamicIslandHUD extends StatelessWidget {
  final Widget child;

  const DynamicIslandHUD({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
