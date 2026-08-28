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
      await tester.pump(const Duration(milliseconds: 500));

      // Drive the add-transaction form if it rendered (exercises the
      // FinancialTransactionService / ledger path on-device). Bounded pumps
      // only — never pumpAndSettle here, a save can kick off a perpetual
      // animation that would hang the suite.
      final fields = find.byType(TextFormField);
      if (tester.any(fields)) {
        await tester.enterText(fields.first, '250');
        await tester.pump(const Duration(milliseconds: 300));
      }
      var submitted = false;
      for (final label in const ['Save', 'Add', 'Submit']) {
        final b = find.widgetWithText(ElevatedButton, label);
        if (tester.any(b)) {
          await tester.tap(b.first, warnIfMissed: false);
          submitted = true;
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 600));
      if (submitted) {
        // Best-effort leave the screen.
        await tester.pageBack();
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    expect(errors, isEmpty,
        reason: 'Flutter errors encountered while navigating the app');
  });
}
