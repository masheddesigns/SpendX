import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/dynamic_island_service.dart';
import 'package:spend_x/shared/widgets/dynamic_island_hud.dart';

void main() {
  testWidgets('DynamicIslandHUD (C2 Fix): dismiss race does not hide newly arrived transaction',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DynamicIslandHUD(
          child: Scaffold(
            body: Center(child: Text('Home')),
          ),
        ),
      ),
    );

    // 1. First event arrives
    DynamicIslandService.instance.show(
      amount: '100.00',
      isExpense: true,
      subtitle: 'First Merchant',
    );
    await tester.pump(); // Start forward animation
    await tester.pump(const Duration(milliseconds: 500)); // Animation complete

    expect(find.text('- ₹100.00'), findsOneWidget);

    // 2. Advance time to trigger auto-dismiss reverse (3800ms)
    await tester.pump(const Duration(milliseconds: 3800));

    // 3. Reverse animation is in-flight (reverse duration is 250ms; pump 100ms)
    await tester.pump(const Duration(milliseconds: 100));

    // 4. Second transaction arrives DURING reverse
    DynamicIslandService.instance.show(
      amount: '200.00',
      isExpense: true,
      subtitle: 'Second Merchant',
    );
    await tester.pump(); // Triggers _onEvent, increments generation, calls forward(from: 0)

    // 5. Pump past where the first reverse animation's future would have completed
    await tester.pump(const Duration(milliseconds: 300));

    // With C2 fix, the interrupted reverse callback detects generation mismatch and does NOT null _currentEvent
    expect(find.text('- ₹200.00'), findsOneWidget);

    // Verify it stays visible until its own timer fires
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.text('- ₹200.00'), findsOneWidget);

    // Finish its dismiss timer to clean up pending timers
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 300));
  });
}
