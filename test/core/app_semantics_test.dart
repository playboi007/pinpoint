import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/core/app_semantics.dart';
import 'package:pinpoint/src/detect/a11y_audit.dart';
import 'package:pinpoint/src/detect/detector.dart';

/// On web, an app that keeps semantics on gets a DOM element over each
/// tappable widget. A quick click on one is sent to the widget as a
/// semantics tap, past the pointer trap: it ran the app's button while
/// picking. So the app's semantics are hidden while Pinpoint is active.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          PinPointWrapper(controller: controller, child: child),
      home: Scaffold(
        body: Center(
          child: ElevatedButton(onPressed: () {}, child: const Text('Go')),
        ),
      ),
    ),
  );

  /// Whether the live semantics tree has a node labeled "Go". (A render
  /// object keeps its last node after it is excluded, so a finder on the
  /// widget would still match.)
  bool hasButton(WidgetTester tester) {
    final root = tester
        .binding
        .renderViews
        .first
        .owner
        ?.semanticsOwner
        ?.rootSemanticsNode;
    var found = false;
    bool visit(SemanticsNode node) {
      if (node.label == 'Go') found = true;
      if (!found) node.visitChildren(visit);
      return !found;
    }

    if (root != null) visit(root);
    return found;
  }

  testWidgets('the app has no semantics while Pinpoint is active', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpHost(tester);
    expect(hasButton(tester), isTrue);

    controller.startPicking();
    await tester.pump();
    expect(hasButton(tester), isFalse);

    controller.stop();
    await tester.pump();
    expect(hasButton(tester), isTrue);
    semantics.dispose();
  });

  testWidgets('a reader shows them again until it is done', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHost(tester);
    controller.startPicking();
    await tester.pump();

    final done = AppSemantics.read();
    await tester.pump();
    expect(hasButton(tester), isTrue);

    done();
    // A second call does nothing: the count never goes below zero.
    done();
    await tester.pump();
    expect(hasButton(tester), isFalse);
    expect(AppSemantics.readers.value, 0);
    semantics.dispose();
  });

  testWidgets('the accessibility audit still sees the app while picking', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PinPointWrapper(controller: controller, child: child),
        home: Scaffold(
          body: Center(
            // No label and 24 x 24: two findings.
            child: GestureDetector(
              onTap: () {},
              child: const SizedBox(width: 24, height: 24),
            ),
          ),
        ),
      ),
    );
    controller.startPicking();
    await tester.pump();

    // The wrapper's app boundary, as the overlay passes it.
    final root = tester.renderObject(find.byType(RepaintBoundary).first);
    final audit = runAccessibilityAudit(
      root,
      locator: FindingLocator(boundary: tester.binding.rootElement),
      devicePixelRatio: tester.view.devicePixelRatio,
      contrast: false,
    );
    await tester.pump();
    final findings = await audit;
    // Excluded nodes are detached from the tree: without the reader the
    // audit still finds them, but measures 24 / 3 (the pixel ratio) = 8.
    final small = findings.singleWhere((f) => f.kind == 'small_tap_target');
    expect(small.summary, contains('24x24'));
    await tester.pump();
    expect(AppSemantics.readers.value, 0);
  });
}
