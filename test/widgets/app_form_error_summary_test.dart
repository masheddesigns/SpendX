import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/shared/widgets/app_form_error_summary.dart';

void main() {
  testWidgets('AppFormErrorSummary renders nothing when errors list is empty', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppFormErrorSummary(errors: []),
        ),
      ),
    );

    expect(find.byType(AppFormErrorSummary), findsOneWidget);
    expect(find.textContaining('Please correct'), findsNothing);
  });

  testWidgets('AppFormErrorSummary renders all error messages and semantics', (tester) async {
    const testErrors = ['Name is required', 'Amount must be greater than zero'];

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppFormErrorSummary(errors: testErrors),
        ),
      ),
    );

    expect(find.text('Please correct the following errors:'), findsOneWidget);
    expect(find.text('Name is required'), findsOneWidget);
    expect(find.text('Amount must be greater than zero'), findsOneWidget);

    // Verify Semantics has liveRegion enabled and contains error message
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            (w.properties.label?.contains('Name is required') ?? false) &&
            (w.properties.liveRegion ?? false),
      ),
      findsOneWidget,
    );
  });
}
