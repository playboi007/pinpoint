import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/toast_layer.dart';
import 'package:pinpoint/src/theme/controls.dart';

/// Toasts: a success goes by itself, an error stays until dismissed, and
/// sending shows a loading toast.
void main() {
  late ToastController toasts;
  late PinPointController controller;

  setUp(() {
    toasts = ToastController();
    controller = PinPointController();
  });
  tearDown(() {
    toasts.dispose();
    controller.dispose();
  });

  Future<void> pumpLayer(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Stack(
        children: [ToastLayer(toasts: toasts, controller: controller)],
      ),
    ),
  );

  testWidgets('a success goes after 4 s; an error stays until dismissed', (
    tester,
  ) async {
    await pumpLayer(tester);
    toasts
      ..show('Sent to HTTP')
      ..show('bridge failed', error: true);
    await tester.pump();
    expect(find.text('Sent to HTTP'), findsOneWidget);
    expect(find.text('bridge failed'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Sent to HTTP'), findsNothing);
    expect(find.text('bridge failed'), findsOneWidget);
    await tester.pump(const Duration(minutes: 5));
    expect(find.text('bridge failed'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('bridge failed'), findsNothing);
  });

  testWidgets('an action runs and dismisses the toast', (tester) async {
    var retried = 0;
    await pumpLayer(tester);
    toasts.show(
      'Send failed',
      error: true,
      actionLabel: 'Retry',
      onAction: () => retried++,
    );
    await tester.pump();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retried, 1);
    expect(find.text('Send failed'), findsNothing);
  });

  testWidgets('a toast without an action takes no clicks', (tester) async {
    await pumpLayer(tester);
    toasts.show('Copied');
    await tester.pump();
    final ignore = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.text('Copied'),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignore.ignoring, isTrue);
    expect(find.byType(DraftButton), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}
