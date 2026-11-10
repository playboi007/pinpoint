import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/highlight_painter.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/fake_sink.dart';

/// Milestone 5, build step 2: the comment form as a tab of the info panel,
/// driven by a fake sink.
void main() {
  late PinPointController controller;
  late FakeSink sink;

  setUp(() {
    controller = PinPointController();
    sink = FakeSink();
  });
  tearDown(() => controller.dispose());

  Widget host({Widget home = const FixturePage()}) => MaterialApp(
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: PinPointConfig(sinks: [sink]),
      child: child,
    ),
    home: home,
  );

  // The panel repeats widget names, so look in the app's Scaffold only.
  Finder appText(String text) =>
      find.descendant(of: find.byType(Scaffold), matching: find.text(text));
  final panel = find.byKey(InfoPanel.panelKey);
  final field = find.byKey(CommentForm.fieldKey);
  Finder crumb(String name) => find.descendant(
    of: find.byKey(InfoPanel.crumbsKey),
    matching: find.text(name),
  );
  Finder inPanel(String text) =>
      find.descendant(of: panel, matching: find.text(text));

  Future<void> select(WidgetTester tester, Finder target) async {
    await tester.tapAt(tester.getCenter(target));
    await tester.pump();
  }

  Future<void> selectSave(WidgetTester tester) async {
    await tester.pumpWidget(host());
    controller.startPicking();
    await tester.pump();
    await select(tester, appText('Save'));
  }

  /// Lets an async send run to its end.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  testWidgets('a click opens the Comment tab with the plan contents in order', (
    tester,
  ) async {
    await selectSave(tester);
    expect(controller.mode, PinPointMode.commenting);
    final selection = controller.selection.value!;

    // Breadcrumb of the local chain.
    for (final name in ['Row', 'ElevatedButton', 'Text']) {
      expect(crumb(name), findsOneWidget, reason: name);
    }
    // Widget name and file:line.
    expect(inPanel(locationLabel(selection)!), findsOneWidget);
    // Intent chips, the field, the screenshot box and three buttons.
    for (final label in ['Bug', 'Improve', 'Question']) {
      expect(inPanel(label), findsOneWidget, reason: label);
    }
    expect(field, findsOneWidget);
    final box = find.byKey(CommentForm.screenshotKey);
    expect(tester.widget<CheckboxListTile>(box).value, isTrue);
    for (final key in [
      CommentForm.sendKey,
      CommentForm.copyKey,
      CommentForm.cancelKey,
    ]) {
      expect(find.byKey(key), findsOneWidget);
    }

    final tops = [
      tester.getTopLeft(find.byKey(InfoPanel.crumbsKey)).dy,
      tester.getTopLeft(inPanel('Bug')).dy,
      tester.getTopLeft(field).dy,
      tester.getTopLeft(box).dy,
      tester.getTopLeft(find.byKey(CommentForm.sendKey)).dy,
    ];
    final sorted = [...tops]..sort();
    expect(tops, sorted, reason: 'top to bottom as in the plan');

    final textField = tester.widget<TextField>(field);
    expect(textField.minLines, 3);
    expect(textField.maxLines, 8);
  });

  testWidgets('the Info tab still shows the WidgetInfo', (tester) async {
    await selectSave(tester);
    await tester.tap(find.byKey(InfoPanel.infoTabKey));
    await tester.pump();
    expect(inPanel('RenderParagraph'), findsOneWidget);
    expect(field, findsNothing);

    await tester.tap(find.byKey(InfoPanel.commentTabKey));
    await tester.pump();
    expect(field, findsOneWidget);
  });

  testWidgets('chips, the box and the field write the draft', (tester) async {
    await selectSave(tester);
    expect(controller.draft.intent, AnnotationIntent.improve);

    await tester.tap(inPanel('Bug'));
    await tester.pump();
    expect(controller.draft.intent, AnnotationIntent.bug);

    await tester.tap(find.byKey(CommentForm.screenshotKey));
    await tester.pump();
    expect(controller.draft.includeScreenshot, isFalse);

    await tester.enterText(field, 'Label truncates');
    expect(controller.draft.text.text, 'Label truncates');
  });

  testWidgets('Send is off until there is a comment', (tester) async {
    await selectSave(tester);
    Widget sendButton() => tester.widget(find.byKey(CommentForm.sendKey));
    expect((sendButton() as ButtonStyleButton).enabled, isFalse);

    await tester.enterText(field, '   ');
    await tester.pump();
    expect((sendButton() as ButtonStyleButton).enabled, isFalse);

    await tester.enterText(field, 'Too tight');
    await tester.pump();
    expect((sendButton() as ButtonStyleButton).enabled, isTrue);
  });

  testWidgets('Send hands the note to the sink, then goes idle and clears '
      'the comment', (tester) async {
    await selectSave(tester);
    await tester.tap(inPanel('Bug'));
    await tester.enterText(field, 'Too tight');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    await settle(tester);

    final note = sink.notes.single;
    expect(note.comment, 'Too tight');
    expect(note.intent, AnnotationIntent.bug);
    expect(note.target.widget, 'Text');
    expect(note.target.source?.line, isNotNull);
    expect(controller.mode, PinPointMode.idle);
    expect(controller.draft.text.text, isEmpty);
    expect(controller.draft.intent, AnnotationIntent.bug, reason: 'kept');
  });

  testWidgets('the mode is sending while the sink works', (tester) async {
    await selectSave(tester);
    sink.gate = Completer<void>();
    await tester.enterText(field, 'Too tight');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    await tester.pump();
    expect(controller.mode, PinPointMode.sending);
    expect(tester.widget<TextField>(field).readOnly, isTrue);

    sink.gate!.complete();
    await settle(tester);
    expect(controller.mode, PinPointMode.idle);
  });

  testWidgets('a failed send keeps the comment and the selection', (
    tester,
  ) async {
    sink.error = Exception('connection refused');
    await selectSave(tester);
    final selection = controller.selection.value;
    await tester.enterText(field, 'Too tight');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    await settle(tester);

    expect(sink.notes, hasLength(1));
    expect(controller.mode, PinPointMode.commenting);
    expect(controller.selection.value, same(selection));
    expect(controller.draft.text.text, 'Too tight');
    expect(find.text('Too tight'), findsOneWidget);
  });

  testWidgets('Cancel goes back to picking with the selection and text kept', (
    tester,
  ) async {
    await selectSave(tester);
    final selection = controller.selection.value;
    await tester.enterText(field, 'Too tight');
    await tester.tap(find.byKey(CommentForm.cancelKey));
    await tester.pump();

    expect(controller.mode, PinPointMode.picking);
    expect(controller.selection.value, same(selection));
    expect(controller.draft.text.text, 'Too tight');
    expect(panel, findsOneWidget);
  });

  testWidgets('acceptance: clicking a breadcrumb reselects and the outline '
      'updates', (tester) async {
    await selectSave(tester);
    final textRect = controller.selection.value!.globalRect;

    await tester.tap(crumb('ElevatedButton'));
    await tester.pump();
    final selection = controller.selection.value!;
    expect(selection.entry.name, 'ElevatedButton');
    expect(selection.globalRect, tester.getRect(find.byType(ElevatedButton)));
    expect(selection.globalRect, isNot(textRect));
    expect(controller.mode, PinPointMode.commenting);

    // The highlight paints the selection notifier: it moved with it.
    final highlight = tester.widget<CustomPaint>(
      find.byKey(const ValueKey<String>('pinpoint.highlight')),
    );
    final painter = highlight.painter! as HighlightPainter;
    expect(painter.selected.value, same(selection));

    // The crumbs follow: Text is still there, below the button.
    await tester.tap(crumb('Text'));
    await tester.pump();
    expect(controller.selection.value!.entry.name, 'Text');
    expect(controller.selection.value!.globalRect, textRect);
  });

  group('a click outside the panel (watch out for)', () {
    /// Room for the panel below Save, so it does not cover the hint text.
    void largeView(WidgetTester tester) {
      tester.view
        ..physicalSize = const Size(1600, 1200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('with no comment typed, it selects again', (tester) async {
      largeView(tester);
      await selectSave(tester);
      expect(
        tester.getRect(panel).contains(tester.getCenter(appText('hint'))),
        isFalse,
      );
      await select(tester, appText('hint'));
      expect(controller.selection.value!.element.widget, isA<Text>());
      expect((controller.selection.value!.element.widget as Text).data, 'hint');
    });

    testWidgets('with a comment typed, it does nothing', (tester) async {
      largeView(tester);
      await selectSave(tester);
      expect(
        tester.getRect(panel).contains(tester.getCenter(appText('hint'))),
        isFalse,
      );
      final selection = controller.selection.value;
      await tester.enterText(field, 'Too tight');
      await tester.pump();
      await select(tester, appText('hint'));
      expect(controller.selection.value, same(selection));
      expect(controller.draft.text.text, 'Too tight');
    });
  });

  testWidgets('the panel opens next to its target', (tester) async {
    await selectSave(tester);
    final target = controller.selection.value!.globalRect;
    final screen = tester.getSize(find.byType(PinPointWrapper));
    expect(
      tester.getTopLeft(panel),
      placePanel(target, tester.getSize(panel), screen),
    );
  });

  group('acceptance: the panel never overflows the viewport', () {
    for (final size in const [Size(360, 640), Size(1920, 1080)]) {
      testWidgets('at ${size.width.toInt()} px wide', (tester) async {
        tester.view
          ..physicalSize = size
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(host(home: const _CornersPage()));

        final screen = Offset.zero & size;
        for (final label in _CornersPage.labels) {
          // Start over each time, so the last panel cannot cover the target.
          controller
            ..stop()
            ..startPicking();
          await tester.pump();
          await select(tester, appText(label));
          final widget = controller.selection.value!.element.widget;
          expect((widget as Text).data, label);
          for (final tab in [InfoPanel.infoTabKey, InfoPanel.commentTabKey]) {
            await tester.tap(find.byKey(tab));
            await tester.pump();
            final rect = tester.getRect(panel);
            expect(
              screen.deflate(panelMargin).expandToInclude(rect),
              screen.deflate(panelMargin),
              reason: '$label, $tab: $rect',
            );
            expect(tester.takeException(), isNull, reason: '$label, $tab');
          }
        }
      });
    }
  });
}

/// Text at each corner, each edge's middle and the center.
class _CornersPage extends StatelessWidget {
  const _CornersPage();

  static const labels = ['tl', 'tr', 'bl', 'br', 'top', 'left', 'mid'];

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Stack(
        children: [
          Positioned(left: 0, top: 0, child: Text('tl')),
          Positioned(right: 0, top: 0, child: Text('tr')),
          Positioned(left: 0, bottom: 0, child: Text('bl')),
          Positioned(right: 0, bottom: 0, child: Text('br')),
          Align(alignment: Alignment.topCenter, child: Text('top')),
          Align(alignment: Alignment.centerLeft, child: Text('left')),
          Center(child: Text('mid')),
        ],
      ),
    );
  }
}
