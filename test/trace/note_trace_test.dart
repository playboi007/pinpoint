import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/note_detail.dart';
import 'package:pinpoint/src/model/annotation.dart' show traceNotRecorded;
import 'package:pinpoint/src/overlay/comment_form.dart';

import '../support/fake_sink.dart';
import '../support/finish_send.dart';
import '../support/trace_host.dart';

/// PLAN-v2 Milestone 13, step 12: a note carries `trace`, what happened in
/// the 10 seconds before the pick, and its Markdown a "What happened"
/// section.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  /// Taps the counter in the app, then picks the count text and sends a
  /// note about it. Returns the note the sink got.
  Future<Annotation> noteAfterTap(
    WidgetTester tester, {
    bool detail = false,
  }) async {
    final sink = FakeSink();
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        config: PinPointConfig(sinks: [sink]),
        home: const _Screen(),
      ),
    );
    await tester.pump();
    if (detail) {
      await toolResult(tester, controller, 'trace_detail', {'on': true});
    }
    await tester.tap(find.text('+'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    controller.panelPosition = const Offset(300, 20);
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.text('count 1')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Wrong count');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    await finishSend(tester, controller);
    if (detail) {
      await toolResult(tester, controller, 'trace_detail', {'on': false});
    }
    return sink.notes.single;
  }

  testWidgets('acceptance: a note made after a tap has a trace that includes '
      'that tap', (tester) async {
    final note = await noteAfterTap(tester);
    final trace = note.trace!;
    final lines = (trace['lines']! as List<Object?>).cast<String>();
    expect(lines, contains(contains('input.pointer  down Text')));
    expect(lines, contains(contains('input.pointer  up')));
    // The click that picked is Pinpoint's, after the window: not there.
    expect(lines.where((l) => l.contains('input.pointer  down')), hasLength(1));
    expect(trace['seconds'], 10);
  });

  testWidgets('with level 3 off the trace says so first, and holds inputs, '
      'routes and errors only', (tester) async {
    final note = await noteAfterTap(tester);
    final lines = (note.trace!['lines']! as List<Object?>).cast<String>();
    expect(note.trace!['rebuilds'], isFalse);
    expect(lines.first, traceNotRecorded);
    expect(lines.where((l) => l.contains('  build  ')), isEmpty);
  });

  testWidgets('with level 3 on, the trace holds the rebuilds of the picked '
      "widget's subtree only", (tester) async {
    final note = await noteAfterTap(tester, detail: true);
    final lines = (note.trace!['lines']! as List<Object?>).cast<String>();
    // Level 3 started after the app did: the first line names the part of
    // the window before it.
    expect(lines.first, startsWith('$traceNotRecorded for seq 1-'));
    expect(lines, contains(contains('build  Text')));
    // _Screen rebuilt too, but it is above the picked text.
    expect(lines.where((l) => l.contains('build  _Screen')), isEmpty);
  });

  testWidgets('the Markdown and the agent\'s note text have "What happened"', (
    tester,
  ) async {
    final note = await noteAfterTap(tester);
    final markdown = note.toMarkdown();
    expect(markdown, contains('What happened (10 s before the pick):'));
    // The note keeps that line in its JSON; the text says nothing about
    // it (PLAN-v3 Milestone 19, step 9).
    expect(markdown, isNot(contains(traceNotRecorded)));
    expect(markdown, contains('input.pointer  down Text'));
    final standard = noteText(note.toJson(), NoteDetail.standard);
    expect(standard, contains('What happened (10 s before the pick):'));
    expect(standard, isNot(contains(traceNotRecorded)));
    expect(
      noteText(note.toJson(), NoteDetail.compact),
      isNot(contains('What')),
    );
  });
}

class _Screen extends StatefulWidget {
  const _Screen();

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  int count = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('count $count'),
          ElevatedButton(
            onPressed: () => setState(() => count++),
            child: const Text('+'),
          ),
        ],
      ),
    ),
  );
}
