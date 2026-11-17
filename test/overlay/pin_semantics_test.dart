import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/pin_marker.dart';

import '../fixtures/pin_fixture.dart';
import '../support/finish_send.dart';

void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  /// Every semantics node with a tap action, with its rect in the root's
  /// coordinates.
  List<(String, Rect)> tapNodes(WidgetTester tester) {
    final found = <(String, Rect)>[];
    void walk(SemanticsNode node, Matrix4 parent) {
      final transform = parent.clone();
      if (node.transform != null) transform.multiply(node.transform!);
      final data = node.getSemanticsData();
      if (data.hasAction(SemanticsAction.tap)) {
        found.add((
          data.label,
          MatrixUtils.transformRect(transform, node.rect),
        ));
      }
      node.visitChildren((child) {
        walk(child, transform);
        return true;
      });
    }

    walk(
      tester
          .binding
          .renderViews
          .single
          .owner!
          .semanticsOwner!
          .rootSemanticsNode!,
      Matrix4.identity(),
    );
    return found;
  }

  // On web, an app that keeps semantics on gets a DOM element per
  // semantics node, and a click on one runs its tap action without the hit
  // test. The pin's tap must sit on a node the size of the pin: on a node
  // that covers the screen, a click anywhere opens its note.
  testWidgets('in idle, the pin tap is on a node the size of the pin', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PinPointWrapper(controller: controller, child: child),
        home: const PinFixture(),
      ),
    );
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(
        find.descendant(
          of: find.byType(Scaffold),
          matching: find.text('row 1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Too tight');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.draftKey));
    await tester.pump();
    await finishSend(tester, controller);
    controller.stop();
    await tester.pump();
    await tester.pump();

    expect(find.byType(PinMarker), findsOneWidget);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final nodes = tapNodes(tester);
    for (final (label, rect) in nodes) {
      expect(
        rect.width < screen.width / 2 && rect.height < screen.height / 2,
        isTrue,
        reason: 'tap node "$label" covers $rect',
      );
    }
    handle.dispose();
  });
}
