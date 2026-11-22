import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/services/dynamic_island_service.dart';
import 'package:spend_x/shared/widgets/dynamic_island_hud.dart';

void main() {
  testWidgets(
      'DynamicIslandHUD: cleanly acts as pass-through widget after overlay decommissioning',
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

    expect(find.text('Home'), findsOneWidget);

    // Event arrives; pass-through widget safely renders child without overlay interference
    await DynamicIslandService.instance.show(
      amount: '100.00',
      isExpense: true,
      subtitle: 'First Merchant',
    );
    await tester.pump();
    expect(find.text('Home'), findsOneWidget);
  });
}
