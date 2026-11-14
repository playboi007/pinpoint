import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/note_detail.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/note_view.dart';
import 'package:pinpoint/src/overlay/tape_range_picker.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';
import 'package:pinpoint/src/sink/markdown_formatter.dart';
import 'package:pinpoint/src/tape/tape_player.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../fixtures/pin_fixture.dart';
import '../support/fake_bridge.dart';
import '../support/finish_send.dart';

/// PLAN-v2 Milestone 15, build step 7 (UI): "Attach what happened" in the
/// comment form, `tape` in the note, "has tape" for the agent, and the
/// Replay button on a pin.
void main() {
  late PinPointController controller;
  late FakeBridge bridge;

  setUp(() {
    controller = PinPointController();
    bridge = FakeBridge();
    BridgeClient.debugClient = bridge.client;
  });

  tearDown(() {
    TapePlayer.debugReset();
    BridgeClient.debugClient = null;
    controller.dispose();
  });

  Widget host() => MaterialApp(
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: PinPointConfig(
        sinks: [HttpSink.bridge(port: 4747, client: bridge.client)],
      ),
      child: child,
    ),
    home: const PinFixture(),
  );

  Finder appText(String text) =>
      find.descendant(of: find.byType(Scaffold), matching: find.text(text));

  Future<String> writeNote(
    WidgetTester tester, {
    bool tape = true,
    void Function()? range,
  }) async {
    // What the user did before noticing the bug.
    await tester.tap(appText('row 1'));
    await tester.pump(Duration.zero);
    controller.startPicking();
    controller.panelPosition = const Offset(300, 20);
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText('row 1')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(CommentForm.tapeKey), findsOneWidget);
    expect(find.textContaining('Attach what happened ('), findsOneWidget);
    if (!tape) {
      await tester.tap(find.byKey(CommentForm.tapeKey));
      await tester.pump();
    }
    range?.call();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Row 1 is off');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await finishSend(tester, controller);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
    return controller.notes.notes.last.id;
  }

  testWidgets('acceptance (form): Attach what happened puts a tape on the '
      'bridge and its summary in the note', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester);
    final note = bridge.notes[id]!;
    final tape = note['tape']! as Map<String, Object?>;
    expect(tape['kind'], 'full');
    expect(tape['inputs'], greaterThan(0));
    expect(bridge.tapes.keys, [tape['id']]);
    // The agent's header and the Markdown say so.
    expect(noteText(note, NoteDetail.compact), contains('has tape'));
    expect(markdownFromJson(note), contains('Tape: ${tape['id']} (full'));
  });

  testWidgets('the range picker shows with the switch, and the tape holds '
      'only the chosen range', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(
      tester,
      range: () {
        expect(find.byType(TapeRangePicker), findsOneWidget);
        // From after the tap on row 1 to now: no input in it.
        controller.draft.setTapeRange(TraceSession.current!.tapes.now, null);
      },
    );
    final tape = bridge.notes[id]!['tape']! as Map<String, Object?>;
    expect(tape['kind'], 'segment');
    expect(tape['inputs'], 0);
    // The range belongs to that note: the next one starts from the default.
    expect(controller.draft.tapeFrom, isNull);
  });

  testWidgets('with the switch off, no tape goes', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester, tape: false);
    expect(bridge.notes[id]!.containsKey('tape'), isFalse);
    expect(bridge.tapes, isEmpty);
  });

  testWidgets('a pin with a tape shows Replay', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester);
    final note = controller.notes.byId(id)!;
    expect(note.tape, isNotNull);
    // Shown when the pin's note is open.
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: NoteView(
            note: note,
            number: 1,
            drafts: 0,
            focusNode: FocusNode(),
            actions: NoteActions(
              send: (_) {},
              sendAll: () {},
              delete: (_) {},
              accept: (_) {},
              reopen: (_, _) {},
              edit: (_, _) {},
              replay: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(NoteView.replayKey), findsOneWidget);
  });
}
