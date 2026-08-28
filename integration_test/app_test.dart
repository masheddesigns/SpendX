import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:spend_x/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches and navigates main surfaces without errors',
      (tester) async {
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = (d) => errors.add(d);

    app.main();
    // Settle past the splash screen and initial route building.
    for (var i = 0; i < 12; i++) {
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      await Future.delayed(const Duration(milliseconds: 150));
    }

    // Exercise every bottom-navigation destination (renders each screen).
    final nav = find.byType(BottomNavigationBar);
    if (tester.any(nav)) {
      final icons = find.descendant(of: nav, matching: find.byType(Icon));
      final count = tester.widgetList(icons).length;
      for (var i = 0; i < count; i++) {
        final itemIcon =
            find.descendant(of: nav, matching: find.byType(Icon)).at(i);
        await tester.tap(itemIcon, warnIfMissed: false);
        await tester.pumpAndSettle(const Duration(milliseconds: 300));
      }
    }

    // Exercise the primary FAB (typically the add-transaction flow).
    final fab = find.byType(FloatingActionButton);
    if (tester.any(fab)) {
      await tester.tap(fab.first, warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.pageBack();
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
    }

    expect(errors, isEmpty,
        reason: 'Flutter errors encountered while navigating the app');
  });
}
