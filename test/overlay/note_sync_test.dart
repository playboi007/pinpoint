import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/note_view.dart';
import 'package:pinpoint/src/overlay/pin_marker.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';

import '../fixtures/pin_fixture.dart';
import '../support/fake_bridge.dart';
import '../support/finish_send.dart';

/// Milestone 8, build step 3 (second part): the app loads its pins from
/// the bridge and polls it for the agent's changes.
void main() {
  late PinPointController controller;
  late FakeBridge bridge;

  setUp(() {
    controller = PinPointController();
    bridge = FakeBridge();
    BridgeClient.debugClient = bridge.client;
  });
  tearDown(() {
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
  Finder pins() => find.byType(PinMarker);

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<String> writeNote(
    WidgetTester tester,
    String text, {
    required Key button,
  }) async {
    if (controller.mode == PinPointMode.idle) controller.startPicking();
    // Clear of the launcher at the bottom left: the footer buttons sit at the
    // panel's bottom edge.
    controller.panelPosition = const Offset(300, 20);
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText(text)));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'About $text');
    await tester.pump();
    await tester.tap(find.byKey(button));
    await tester.pump();
    await finishSend(tester, controller);
    await settle(tester);
    return controller.notes.notes.last.id;
  }

  testWidgets('a saved draft is stored on the bridge as a draft', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester, 'row 1', button: CommentForm.draftKey);
    expect(bridge.notes[id]!['status'], 'draft');
    expect(bridge.notes[id]!['anchor'], isNotNull);
  });

  testWidgets('acceptance: restarting the app with the bridge running '
      'restores all open pins', (tester) async {
    await tester.pumpWidget(host());
    final draft = await writeNote(
      tester,
      'row 1',
      button: CommentForm.draftKey,
    );
    final sent = await writeNote(tester, 'Title', button: CommentForm.sendKey);
    expect(pins(), findsNWidgets(2));

    // A restart: a new controller, a new tree, nothing in memory.
    controller.dispose();
    controller = PinPointController();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host());
    await settle(tester);

    expect([for (final n in controller.notes.notes) n.id], [draft, sent]);
    expect(controller.notes.byId(draft)!.status, NoteStatus.draft);
    expect(controller.notes.byId(sent)!.status, NoteStatus.submitted);
    expect(pins(), findsNWidgets(2));
    final rowPin = tester.getCenter(
      find.byKey(ValueKey<String>('pinpoint.pin.$draft')),
    );
    expect(rowPin.dx, moreOrLessEquals(tester.getRect(appText('row 1')).right));
  });

  testWidgets('acceptance: update_note(id, "resolved") makes the pin show a '
      'tick and fade within 3 seconds', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester, 'Title', button: CommentForm.sendKey);
    controller.startPicking();
    await tester.pump();

    bridge.agentUpdate(id, 'resolved', message: 'Made it bold.');
    final clock = Stopwatch();
    var elapsed = Duration.zero;
    while (find
        .descendant(of: pins(), matching: find.byIcon(Icons.check))
        .evaluate()
        .isEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      elapsed += const Duration(milliseconds: 100);
      expect(elapsed, lessThan(const Duration(seconds: 3)));
    }
    await tester.pump(PinMarker.fadeDuration);
    elapsed += PinMarker.fadeDuration;
    clock.stop();
    expect(elapsed, lessThanOrEqualTo(const Duration(seconds: 3)));
    final fade = tester.widget<AnimatedOpacity>(
      find.descendant(of: pins(), matching: find.byType(AnimatedOpacity)),
    );
    expect(fade.opacity, PinMarker.fadedOpacity);
    expect(controller.notes.byId(id)!.messages.single.text, 'Made it bold.');
    expect(find.textContaining('Note 1 is resolved'), findsOneWidget);
  });

  // PLAN.md, Milestone 8, watch out: polling must stop when the overlay is
  // idle, or it keeps the network panel noisy and the tab awake.
  testWidgets('the poll runs only while the overlay is active', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 10));
    expect(bridge.count('GET /changes'), 0, reason: 'idle from the start');
    expect(bridge.count('GET /annotations'), 1, reason: 'one load at start');

    controller.startPicking();
    await tester.pump();
    await tester.pump(pollInterval * 3);
    final polls = bridge.count('GET /changes');
    expect(polls, inInclusiveRange(3, 4));

    controller.stop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(bridge.count('GET /changes'), polls);
  });

  testWidgets('Delete, Accept and Reopen reach the bridge', (tester) async {
    await tester.pumpWidget(host());
    final a = await writeNote(tester, 'Title', button: CommentForm.sendKey);
    // Not row 0: its pin would overlap the title's.
    final b = await writeNote(tester, 'row 2', button: CommentForm.sendKey);
    bridge
      ..agentUpdate(a, 'resolved')
      ..agentUpdate(b, 'fixed');
    controller.startPicking();
    await tester.pump(pollInterval);
    await settle(tester);

    await tester.tap(find.byKey(ValueKey<String>('pinpoint.pin.$a')));
    await settle(tester);
    await tester.tap(find.byKey(NoteView.acceptKey));
    await settle(tester);
    expect(bridge.notes[a]!['status'], 'verified');

    await tester.tap(find.byKey(ValueKey<String>('pinpoint.pin.$b')));
    await settle(tester);
    await tester.tap(find.byKey(NoteView.reopenKey));
    await settle(tester);
    expect(bridge.notes[b]!['status'], 'submitted');
    await tester.tap(find.byKey(NoteView.deleteKey));
    await settle(tester);
    expect(bridge.notes.containsKey(b), isFalse);
  });

  testWidgets('a draft edit reaches the bridge once typing pauses', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester, 'row 1', button: CommentForm.draftKey);
    await tester.tap(pins());
    await settle(tester);
    await tester.enterText(find.byKey(NoteView.fieldKey), 'Better');
    await tester.enterText(find.byKey(NoteView.fieldKey), 'Better words');
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.count('PATCH /annotations/$id'), 1);
    expect(bridge.notes[id]!['comment'], 'Better words');
  });

  testWidgets('with the bridge stopped, a draft stays in this tab', (
    tester,
  ) async {
    bridge.offline = true;
    await tester.pumpWidget(host());
    final id = await writeNote(tester, 'row 1', button: CommentForm.draftKey);
    expect(controller.notes.byId(id)!.status, NoteStatus.draft);
    expect(pins(), findsOneWidget);
    expect(find.textContaining('Draft kept in this tab only'), findsOneWidget);
  });

  testWidgets('a note deleted on the bridge loses its pin', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester, 'Title', button: CommentForm.sendKey);
    controller.startPicking();
    await tester.pump();
    await bridge.client.delete(
      Uri.parse('http://127.0.0.1:4747/annotations/$id'),
    );
    await tester.pump(pollInterval);
    await settle(tester);
    expect(controller.notes.byId(id), isNull);
    expect(pins(), findsNothing);
  });
}
