import 'package:flutter/material.dart';

class MainNavigationScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget bottomNavigationBar;
  final Widget? floatingActionButton;
  final Widget? drawer;

  const MainNavigationScaffold({
    super.key,
    this.appBar,
    required this.body,
    required this.bottomNavigationBar,
    this.floatingActionButton,
    this.drawer,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBar,
      body: SafeArea(child: body),

      bottomNavigationBar: bottomNavigationBar,
      drawer: drawer,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: floatingActionButton,
    );
  }
}
