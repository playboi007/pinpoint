import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';

/// Milestone 2, build step 3: the draggable info panel.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host() => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: const Scaffold(
      body: Center(child: Text('Save', style: TextStyle(fontSize: 16))),
    ),
  );

  // The panel shows the text too, so look for the app's copy only.
  final appText = find.descendant(
    of: find.byType(Scaffold),
    matching: find.text('Save'),
  );

  Future<void> selectText(WidgetTester tester) async {
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText));
    await tester.pump();
  }

  final panel = find.byKey(InfoPanel.panelKey);
  final header = find.byKey(InfoPanel.headerKey);
  Finder inPanel(String text) =>
      find.descendant(of: panel, matching: find.text(text));

  testWidgets('shows only while there is a selection', (tester) async {
    await tester.pumpWidget(host());
    controller.startPicking();
    await tester.pump();
    expect(panel, findsNothing);

    await tester.tapAt(tester.getCenter(appText));
    await tester.pump();
    expect(panel, findsOneWidget);

    controller.stop();
    await tester.pump();
    expect(panel, findsNothing);
  });

  testWidgets('shows the WidgetInfo labels and sections', (tester) async {
    await tester.pumpWidget(host());
    await selectText(tester);

    final info = WidgetInfo.fromRenderObject(tester.renderObject(appText));
    expect(inPanel('RenderParagraph'), findsOneWidget);
    expect(inPanel(info.sizeLabel), findsOneWidget);
    expect(inPanel(info.positionLabel), findsOneWidget);
    expect(inPanel(info.constraintsLabel), findsOneWidget);
    // The selected widget (Milestone 3 refines RichText to Text) and the
    // section title.
    expect(inPanel('Text'), findsNWidgets(2));
    expect(inPanel('Save'), findsOneWidget);
    expect(inPanel('16.0'), findsOneWidget);
  });

  testWidgets('follows reselection', (tester) async {
    await tester.pumpWidget(host());
    await selectText(tester);
    await tester.tapAt(tester.getCenter(appText));
    await tester.pump();

    final selected = controller.selection.value!;
    expect(selected.index, 1);
    expect(inPanel('${selected.element.widget.runtimeType}'), findsOneWidget);
    expect(inPanel('2 of ${selected.candidates.length}'), findsOneWidget);
  });

  testWidgets('a click on the panel does not pick through it', (tester) async {
    await tester.pumpWidget(host());
    await selectText(tester);
    final before = controller.selection.value;

    await tester.tap(inPanel('RenderParagraph'));
    await tester.pump();
    expect(controller.selection.value, same(before));
  });

  testWidgets('drags, clamped to the viewport', (tester) async {
    await tester.pumpWidget(host());
    await selectText(tester);
    final start = tester.getTopLeft(panel);

    await tester.drag(header, const Offset(-100, 50));
    await tester.pump();
    expect(tester.getTopLeft(panel), start + const Offset(-100, 50));

    await tester.drag(header, const Offset(-5000, -5000));
    await tester.pump();
    expect(tester.getTopLeft(panel), Offset.zero);

    await tester.drag(header, const Offset(5000, 5000));
    await tester.pump();
    final screen = tester.getSize(find.byType(PinPointWrapper));
    final rect = tester.getRect(panel);
    expect(rect.right, screen.width);
    expect(rect.top, lessThan(screen.height), reason: 'header stays visible');
    expect(tester.getRect(header).bottom, lessThanOrEqualTo(screen.height));
  });

  testWidgets('keeps its place across reselection and stop', (tester) async {
    await tester.pumpWidget(host());
    await selectText(tester);
    await tester.drag(header, const Offset(-200, 100));
    await tester.pump();
    final moved = tester.getTopLeft(panel);
    expect(controller.panelPosition, moved);

    controller.stop();
    await tester.pump();
    await selectText(tester);
    expect(tester.getTopLeft(panel), moved);
  });

  testWidgets('close clears the selection', (tester) async {
    await tester.pumpWidget(host());
    await selectText(tester);

    await tester.tap(find.byTooltip('Close panel'));
    await tester.pump();
    expect(controller.selection.value, isNull);
    expect(controller.mode, PinPointMode.picking);
    expect(panel, findsNothing);
  });
}
