import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spend_x/shared/widgets/playful/spendx_playful_button.dart';
import 'package:spend_x/theme/playful_tokens.dart';
import 'package:spend_x/widgets/form/spendx_sticky_bottom_bar.dart';

void main() {
  Widget buildTestHost({
    required Widget child,
    ThemeData? theme,
    MediaQueryData? mediaQuery,
  }) {
    return MaterialApp(
      theme: theme ?? ThemeData.light(),
      home: MediaQuery(
        data: mediaQuery ?? const MediaQueryData(),
        child: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: child,
        ),
      ),
    );
  }

  group('SpendXStickyBottomBar - Single Action Layout', () {
    testWidgets('renders single primary button with label and icon', (tester) async {
      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Save Activity',
            primaryIcon: Icons.check_circle_outline,
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(find.byType(SpendXStickyBottomBar), findsOneWidget);
      expect(find.text('Save Activity'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byKey(const ValueKey('spendx_sticky_primary_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('spendx_sticky_secondary_button')), findsNothing);

      // Verify touch target meets or exceeds 48px
      final RenderBox box = tester.renderObject(
        find.byKey(const ValueKey('spendx_sticky_primary_button')),
      );
      expect(box.size.height, greaterThanOrEqualTo(48.0));
    });

    testWidgets('respects custom primary semantic label', (tester) async {
      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Save',
            primarySemanticLabel: 'Save transaction details',
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Save transaction details',
        ),
        findsOneWidget,
      );
    });
  });

  group('SpendXStickyBottomBar - Dual Action Layout', () {
    testWidgets('renders both primary and secondary buttons with configured flex', (tester) async {
      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.dualAction(
            secondaryLabel: 'Cancel',
            onSecondaryPressed: () {},
            primaryLabel: 'Save Account',
            onPrimaryPressed: () {},
            secondaryFlex: 1,
            primaryFlex: 2,
          ),
        ),
      );

      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Save Account'), findsOneWidget);
      expect(find.byKey(const ValueKey('spendx_sticky_secondary_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('spendx_sticky_primary_button')), findsOneWidget);

      // Verify flex factors on Expanded widgets
      final expandeds = tester.widgetList<Expanded>(find.byType(Expanded)).toList();
      expect(expandeds.length, 2);
      expect(expandeds[0].flex, 1);
      expect(expandeds[1].flex, 2);

      // Verify touch targets on both buttons
      final RenderBox secondaryBox = tester.renderObject(
        find.byKey(const ValueKey('spendx_sticky_secondary_button')),
      );
      final RenderBox primaryBox = tester.renderObject(
        find.byKey(const ValueKey('spendx_sticky_primary_button')),
      );
      expect(secondaryBox.size.height, greaterThanOrEqualTo(48.0));
      expect(primaryBox.size.height, greaterThanOrEqualTo(48.0));
    });
  });

  group('SpendXStickyBottomBar - Loading and Disabled States', () {
    testWidgets('primary loading state shows progress indicator and suppresses taps', (tester) async {
      int tapCount = 0;

      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Save',
            isPrimaryLoading: true,
            onPrimaryPressed: () => tapCount++,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.byType(SpendXPlayfulButton));
      await tester.pump();

      expect(tapCount, 0);
    });

    testWidgets('primary disabled state renders non-interactive button', (tester) async {
      int tapCount = 0;

      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Save',
            isPrimaryDisabled: true,
            onPrimaryPressed: () => tapCount++,
          ),
        ),
      );

      // Check semantics shows enabled: false
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.button == true && w.properties.enabled == false,
        ),
        findsOneWidget,
      );

      await tester.tap(find.byType(SpendXPlayfulButton));
      await tester.pump();

      expect(tapCount, 0);
    });

    testWidgets('secondary loading and disabled states behave correctly', (tester) async {
      int secondaryTapCount = 0;

      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.dualAction(
            secondaryLabel: 'Cancel',
            isSecondaryLoading: true,
            onSecondaryPressed: () => secondaryTapCount++,
            primaryLabel: 'Save',
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('spendx_sticky_secondary_button')));
      await tester.pump();
      expect(secondaryTapCount, 0);
    });
  });

  group('SpendXStickyBottomBar - Callback Behavior & Duplicate-Submit Prevention', () {
    testWidgets('triggers callback on tap', (tester) async {
      int tapCount = 0;

      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Submit',
            onPrimaryPressed: () => tapCount++,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('spendx_sticky_primary_button')));
      await tester.pump();

      expect(tapCount, 1);
    });

    testWidgets('debounces rapid multi-taps to prevent duplicate submissions', (tester) async {
      int tapCount = 0;

      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Submit',
            duplicateSubmitDebounce: const Duration(milliseconds: 600),
            onPrimaryPressed: () => tapCount++,
          ),
        ),
      );

      final buttonFinder = find.byKey(const ValueKey('spendx_sticky_primary_button'));

      // First tap
      await tester.tap(buttonFinder);
      await tester.pump();
      expect(tapCount, 1);

      // Immediate second tap (within debounce window)
      await tester.tap(buttonFinder);
      await tester.pump();
      expect(tapCount, 1, reason: 'Rapid duplicate tap should be suppressed');

      // Third tap after debounce expires in real time
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 650));
      });
      await tester.tap(buttonFinder);
      await tester.pump();
      expect(tapCount, 2, reason: 'Tap after debounce interval should be registered');
    });
  });

  group('SpendXStickyBottomBar - Safe Area & Keyboard Inset Handling', () {
    testWidgets('absorbs keyboard insets without double-counting safe area', (tester) async {
      await tester.pumpWidget(
        buildTestHost(
          mediaQuery: const MediaQueryData(
            padding: EdgeInsets.only(bottom: 34),
            viewInsets: EdgeInsets.only(bottom: 320),
          ),
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Save',
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(find.byType(SpendXStickyBottomBar), findsOneWidget);
      final safeAreaFinder = find.descendant(
        of: find.byType(SpendXStickyBottomBar),
        matching: find.byType(SafeArea),
      );
      expect(safeAreaFinder, findsOneWidget);

      final SafeArea safeArea = tester.widget(safeAreaFinder);
      expect(safeArea.bottom, isFalse, reason: 'Bottom safe area should be disabled when keyboard is open to avoid double-counting');
    });

    testWidgets('in overlay mode applies keyboard inset to stay above keyboard', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              padding: EdgeInsets.only(bottom: 34),
              viewInsets: EdgeInsets.only(bottom: 280),
            ),
            child: Scaffold(
              body: Stack(
                children: [
                  const SizedBox.expand(),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SpendXStickyBottomBar.singleAction(
                      primaryLabel: 'Save',
                      isOverlay: true,
                      onPrimaryPressed: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SpendXStickyBottomBar), findsOneWidget);
    });

    testWidgets('exposes correct overlayContentInset helpers', (tester) async {
      expect(SpendXStickyBottomBar.overlayContentInset, 76.0);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              padding: EdgeInsets.only(bottom: 34),
            ),
            child: Builder(
              builder: (context) {
                final inset = SpendXStickyBottomBar.getOverlayContentInset(context, extraPadding: 10);
                // 76 + 34 + 10 = 120
                expect(inset, 120.0);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
    });
  });

  group('SpendXStickyBottomBar - Light and Dark Themes', () {
    testWidgets('adapts cleanly to light theme', (tester) async {
      await tester.pumpWidget(
        buildTestHost(
          theme: ThemeData.light(),
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Save',
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('adapts cleanly to dark theme', (tester) async {
      await tester.pumpWidget(
        buildTestHost(
          theme: ThemeData.dark(),
          child: SpendXStickyBottomBar.dualAction(
            secondaryLabel: 'Cancel',
            onSecondaryPressed: () {},
            primaryLabel: 'Confirm',
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Confirm'), findsOneWidget);
    });

    testWidgets('renders backdrop blur when enableBlur is true', (tester) async {
      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.singleAction(
            primaryLabel: 'Blurred Dock',
            enableBlur: true,
            blurSigma: 16.0,
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });

  group('SpendXStickyBottomBar - Small-Screen Constraints', () {
    testWidgets('renders dual action on narrow 320px viewport without overflow', (tester) async {
      tester.view.physicalSize = const Size(320 * 2, 640 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildTestHost(
          child: SpendXStickyBottomBar.dualAction(
            secondaryLabel: 'Cancel Action',
            onSecondaryPressed: () {},
            primaryLabel: 'Save Long Activity Name',
            onPrimaryPressed: () {},
          ),
        ),
      );

      expect(tester.takeException(), isNull, reason: 'Should not throw RenderFlex overflow on narrow screens');
      expect(find.text('Cancel Action'), findsOneWidget);
      expect(find.text('Save Long Activity Name'), findsOneWidget);
    });
  });
}
