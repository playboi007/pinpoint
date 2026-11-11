import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/note_view.dart';
import 'package:pinpoint/src/overlay/pin_marker.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/fake_sink.dart';
import '../support/finish_send.dart';

/// Milestone 12, build step 3: the comment form offers checks from a short
/// menu, and a verified note shows its outcome on the pin and in the
/// panel.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(List<PinPointSink> sinks) => MaterialApp(
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: PinPointConfig(sinks: sinks),
      child: child,
    ),
    home: const FixturePage(),
  );

  Future<void> selectSave(WidgetTester tester) async {
    // Clear of the launcher at the bottom left: the footer buttons sit at the
    // panel's bottom edge.
    controller.panelPosition = const Offset(300, 20);
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(
        find.descendant(of: find.byType(Scaffold), matching: find.text('Save')),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> addCheck(WidgetTester tester, String type) async {
    await tester.tap(find.byKey(CommentForm.addCheckKey));
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.checkItemKey(type)));
    // The menu calls the item after the frame that closes it.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the form offers checks from a short menu; the note carries '
      'them', (tester) async {
    final sink = FakeSink(name: 'HTTP');
    await tester.pumpWidget(host([sink]));
    controller.draft.includeScreenshot = false;
    await selectSave(tester);
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Too tight');
    await tester.pump();

    await addCheck(tester, 'no_overflow');
    await addCheck(tester, 'text_contains');
    await addCheck(tester, 'visible');
    expect(find.byKey(CommentForm.checkChipKey('no_overflow')), findsOneWidget);
    expect(find.text('Text contains "Save"'), findsOneWidget);
    expect(controller.draft.checks.map((c) => c['type']), [
      'no_overflow',
      'text_contains',
      'visible',
    ]);
    expect(find.byKey(CommentForm.checkChipKey('visible')), findsOneWidget);
    // Removed again from its chip.
    await tester.tap(
      find.descendant(
        of: find.byKey(CommentForm.checkChipKey('visible')),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pump();
    expect(find.byKey(CommentForm.checkChipKey('visible')), findsNothing);

    await tester.tap(find.byKey(CommentForm.sendKey));
    await tester.pump();
    await finishSend(tester, controller);
    final note = sink.notes.single;
    expect(note.checks, [
      {'type': 'no_overflow'},
      {'type': 'text_contains', 'text': 'Save'},
    ]);
    expect(note.toMarkdown(), contains('Checks: no_overflow, text_contains'));
    // A sent note's checks do not carry over to the next one.
    expect(controller.draft.checks, isEmpty);
  });

  testWidgets('a check is offered once', (tester) async {
    await tester.pumpWidget(host(const []));
    await selectSave(tester);
    await addCheck(tester, 'no_overflow');
    await tester.tap(find.byKey(CommentForm.addCheckKey));
    await tester.pump();
    expect(find.byKey(CommentForm.checkItemKey('no_overflow')), findsNothing);
    expect(find.byKey(CommentForm.checkItemKey('visible')), findsOneWidget);
  });

  testWidgets('a verified note shows the outcome on its pin and in the '
      'panel', (tester) async {
    await tester.pumpWidget(host(const []));
    await selectSave(tester);
    final selection = controller.selection.value!;
    final entry = selection.chain[selection.chainIndex];
    final anchor = NoteAnchor(
      file: selection.chain.resolver.paths.relativePath(entry.location!.uri),
      line: entry.location!.line,
      column: entry.location!.column,
      widget: entry.name,
    );
    controller.stop();
    await tester.pump();
    final note = Annotation.fromJson({
      'id': 'pp_checked',
      'createdAt': '2026-11-11T10:00:00.000Z',
      'status': 'fixed',
      'comment': 'Too tight',
      'anchor': anchor.toJson(),
      'checks': [
        {'type': 'no_overflow'},
      ],
      'verification': {
        'at': '2026-11-11T10:05:00.000Z',
        'passed': false,
        'checks': [
          {
            'type': 'no_overflow',
            'passed': false,
            'message': 'Row overflows by 8 px on the right',
          },
        ],
      },
    })!;
    controller.notes.put(note);
    await tester.pump();
    await tester.pump();

    final pin = tester.widget<PinMarker>(find.byType(PinMarker));
    expect(pin.checksPassed, isFalse);
    expect(find.byKey(PinMarker.checksKey), findsOneWidget);

    await tester.tap(find.byType(PinMarker));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(NoteView.verificationKey), findsOneWidget);
    expect(
      find.textContaining('Checks failed (0 of 1 passed)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('no_overflow: Row overflows by 8 px'),
      findsOneWidget,
    );
  });
}
