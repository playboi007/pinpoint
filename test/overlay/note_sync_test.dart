import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/bridge_protocol.dart';
import 'package:pinpoint/src/core/note_book.dart';
import 'package:pinpoint/src/core/note_sync.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;
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
        .descendant(of: pins(), matching: find.byIcon(Icons.done_all))
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
  testWidgets('a note sent through the bridge sink is posted with the tab\'s '
      'client id', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester, 'Title', button: CommentForm.sendKey);
    final posts = [
      for (var i = 0; i < bridge.urls.length; i++)
        if (bridge.requests[i] == 'POST /annotations') bridge.urls[i],
    ];
    expect(posts, isNotEmpty, reason: 'the sink or the sync posted $id');
    final ids = {for (final url in posts) url.queryParameters['client']};
    expect(ids, hasLength(1), reason: 'one id for the whole tab');
    expect(ids.single, isNotEmpty);
  });

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

  testWidgets('acceptance: the whole loop in the app: sent, fixed and '
      'verified, reopened with a reason, fixed and verified again, '
      'accepted', (tester) async {
    await tester.pumpWidget(host());
    final id = await writeNote(tester, 'Title', button: CommentForm.sendKey);
    controller.stop();
    await settle(tester);
    expect(bridge.notes[id]!['status'], 'submitted');

    Finder checksBadge() =>
        find.descendant(of: pins(), matching: find.byKey(PinMarker.checksKey));
    Future<void> openPin() async {
      await tester.tap(find.byKey(ValueKey<String>('pinpoint.pin.$id')));
      await settle(tester);
    }

    // First pass, while Pinpoint is off. A click on the pin asks the
    // bridge at once.
    bridge
      ..agentUpdate(id, 'inProgress', message: 'Looking at it.')
      ..agentUpdate(id, 'fixed', message: 'Made it 36 px.')
      ..agentVerify(id, passed: true);
    await openPin();
    expect(controller.notes.byId(id)!.status, NoteStatus.fixed);
    expect(checksBadge(), findsOneWidget);
    expect(find.byKey(NoteView.acceptKey), findsOneWidget);
    expect(find.byKey(NoteView.reopenKey), findsOneWidget);

    // Reopen, saying why.
    await tester.enterText(
      find.byKey(NoteView.reasonKey),
      'not yet, you shortened it',
    );
    await tester.tap(find.byKey(NoteView.reopenKey));
    await settle(tester);
    final stored = bridge.notes[id]!;
    expect(stored['status'], 'submitted');
    expect(stored['verification'], isNull, reason: 'about the old code');
    expect(stored['reopened'], 1);
    expect(
      (stored['messages']! as List<Object?>).last,
      containsPair('text', 'Reopened: not yet, you shortened it'),
    );
    expect(find.textContaining('· SENT ·'), findsOneWidget);
    expect(checksBadge(), findsNothing);
    // If the agent fixes it from the chat and never marks it, the note is
    // not stuck: the user can accept it anyway.
    expect(find.text('Accept anyway'), findsOneWidget);

    // The agent marks it and verifies again: the same view as pass one.
    bridge
      ..agentUpdate(
        id,
        'fixed',
        message: 'Kept the width; set the height to 36 px.',
      )
      ..agentVerify(id, passed: true);
    await tester.pump(pollInterval);
    await settle(tester);
    expect(controller.notes.byId(id)!.status, NoteStatus.fixed);
    expect(checksBadge(), findsOneWidget);
    expect(find.byKey(NoteView.reopenKey), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);

    await tester.tap(find.byKey(NoteView.acceptKey));
    await settle(tester);
    expect(bridge.notes[id]!['status'], 'verified');
    // The pin folds away first, then it is gone.
    await tester.pumpAndSettle();
    expect(pins(), findsNothing);
    expect(controller.mode, PinPointMode.idle);
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

  // PLAN-v3 Milestone 20, step 7: the undo goes through the sync with the
  // tab's client id, and the note it answers with lands in the book.
  testWidgets('undo sends the tab\'s client id and puts the answer in the '
      'book', (tester) async {
    bridge.notes['pp_a'] = {
      'schema': annotationSchema,
      'id': 'pp_a',
      'createdAt': '2026-11-20T09:00:00Z',
      'status': 'fixed',
      'intent': 'bug',
      'comment': 'Fix pp_a',
      'app': {'buildMode': 'debug', 'platform': 'web'},
      'page': <String, Object?>{},
      'target': {'widget': 'Text', 'sourceUnavailable': true},
    };
    final errors = <String>[];
    final sync = NoteSync(
      client: BridgeClient(Uri.parse('http://127.0.0.1:4747')),
      notes: NoteBook(),
      onError: errors.add,
    );
    await sync.load();
    expect(sync.notes.byId('pp_a')!.status, NoteStatus.fixed);

    final result = await sync.undo(
      'pp_a',
      round: 2,
      changes: ['c1', 'c3'],
      reason: 'Too tight',
    );
    expect(result!.undo, 'done');
    expect(result.isDone, isTrue);
    expect(result.reverted, ['lib/a.dart']);
    expect(result.reloaded, isTrue);
    expect(bridge.undos.single, {
      'round': 2,
      'changes': ['c1', 'c3'],
      'reason': 'Too tight',
    });
    final url = bridge.urls.lastWhere(
      (u) => u.path == '/annotations/pp_a/undo',
    );
    expect(url.queryParameters['client'], sync.clientId);
    // This tab's own write is left out of its /changes, so the book got the
    // note from the answer.
    final seen = sync.notes.byId('pp_a')!;
    expect(seen.status, NoteStatus.submitted);
    expect(seen.messages.last.from, 'user');
    expect(errors, isEmpty);

    // A refusal comes back as null, and the error is reported once.
    expect(await sync.undo('pp_none', round: 1, changes: ['*']), isNull);
    expect(errors.single, contains('Undo failed'));
    sync.dispose();
  });

  // PLAN-v3 Milestone 19, steps 1 and 2: the long poll.
  group('the long poll', () {
    Annotation sample(String id, {NoteStatus status = NoteStatus.submitted}) =>
        Annotation(
          id: id,
          createdAt: DateTime.utc(2026, 11, 20, 9),
          intent: AnnotationIntent.bug,
          comment: 'Fix $id',
          app: const AppInfo(buildMode: 'debug', platform: 'web'),
          page: const PageInfo(),
          target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
          status: status,
        );

    late List<NoteSync> syncs;

    /// A sync with its own book, loaded, as another tab would be.
    Future<NoteSync> tab(
      WidgetTester tester, {
      void Function(Annotation)? onAgentChange,
      void Function(String)? onError,
    }) async {
      final sync = NoteSync(
        client: BridgeClient(Uri.parse('http://127.0.0.1:4747')),
        notes: NoteBook(),
        onAgentChange: onAgentChange,
        onError: onError,
      );
      syncs.add(sync);
      await sync.load();
      return sync;
    }

    int changesCalls() => bridge.count('GET /changes');

    setUp(() {
      syncs = [];
      bridge.longPoll = true;
    });

    /// Stops every tab and answers what they hold, so no request timer
    /// outlives the test.
    Future<void> finish(WidgetTester tester) async {
      for (final sync in syncs) {
        sync.dispose();
      }
      bridge.releasePolls();
      await tester.pump();
    }

    testWidgets('with nothing to say, one request per 25 seconds, each '
        'asking for the wait', (tester) async {
      final sync = await tab(tester);
      sync.active = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 24));
      expect(changesCalls(), 1, reason: 'held open, not asked every 2 s');

      bridge.releasePolls(); // the 25 s ended on the bridge
      await tester.pump(pollInterval * 2);
      expect(changesCalls(), 2);
      for (final url in bridge.urls.where((u) => u.path == '/changes')) {
        expect(url.queryParameters['wait'], '25');
        expect(url.queryParameters['client'], sync.clientId);
      }
      await finish(tester);
    });

    testWidgets('a change answers the held request at once', (tester) async {
      final seen = <String>[];
      final sync = await tab(tester, onAgentChange: (n) => seen.add(n.id));
      bridge.notes['pp_a'] = sample('pp_a').toJson();
      sync.notes.put(sample('pp_a'));
      sync.active = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(seen, isEmpty);

      bridge.agentUpdate('pp_a', 'resolved');
      await tester.pump();
      await tester.pump();
      expect(seen, ['pp_a']);
      expect(sync.notes.byId('pp_a')!.status, NoteStatus.resolved);
      await finish(tester);
    });

    testWidgets('on, off and on again fast leaves one loop', (tester) async {
      final sync = await tab(tester);
      sync
        ..active = true
        ..active = false
        ..active = true;
      await tester.pump();
      expect(changesCalls(), 2, reason: 'the first and the last start');

      bridge.releasePolls();
      await tester.pump(pollInterval * 2);
      // One loop asks again; a second one would make it 4.
      expect(changesCalls(), 3);
      bridge.releasePolls();
      await tester.pump(pollInterval * 2);
      expect(changesCalls(), 4);
      await finish(tester);
    });

    testWidgets('off stops the loop after the answer', (tester) async {
      final sync = await tab(tester);
      sync.active = true;
      await tester.pump();
      sync.active = false;
      bridge.releasePolls();
      await tester.pump(const Duration(seconds: 10));
      expect(changesCalls(), 1);
      await finish(tester);
    });

    testWidgets('after an error the next call waits 2 seconds', (tester) async {
      final sync = await tab(tester);
      bridge.offline = true;
      sync.active = true;
      await tester.pump();
      expect(changesCalls(), 1);
      await tester.pump(pollInterval - const Duration(milliseconds: 100));
      expect(changesCalls(), 1, reason: 'still in the pause');
      await tester.pump(const Duration(milliseconds: 200));
      expect(changesCalls(), 2);
      await finish(tester);
    });

    testWidgets('an empty quick answer (a bridge that does not hold '
        'requests) is followed by a pause', (tester) async {
      bridge.longPoll = false;
      final sync = await tab(tester);
      sync.active = true;
      await tester.pump(const Duration(seconds: 7));
      expect(changesCalls(), inInclusiveRange(3, 4), reason: 'every 2 s');
      await finish(tester);
    });

    testWidgets('the tab\'s own write does not come back; the agent\'s '
        'does', (tester) async {
      final seen = <String, List<String>>{'a': [], 'b': []};
      final a = await tab(tester, onAgentChange: (n) => seen['a']!.add(n.id));
      final b = await tab(tester, onAgentChange: (n) => seen['b']!.add(n.id));
      a.active = true;
      b.active = true;
      await tester.pump();
      int callsOf(NoteSync sync) => bridge.urls
          .where(
            (u) =>
                u.path == '/changes' &&
                u.queryParameters['client'] == sync.clientId,
          )
          .length;
      expect(callsOf(a), 1);
      expect(callsOf(b), 1);

      // Tab a writes a note: b hears of it, a's own request stays held.
      expect(await a.save(sample('pp_a')), isTrue);
      await tester.pump();
      await tester.pump();
      expect(b.notes.byId('pp_a'), isNotNull, reason: 'another tab sees it');
      expect(callsOf(b), 2);
      expect(callsOf(a), 1, reason: 'no answer to a: it is still held');

      // The same for a change of status the user makes in tab a.
      a.notes.put(sample('pp_a'));
      expect(await a.update('pp_a', status: NoteStatus.resolved), isTrue);
      await tester.pump();
      await tester.pump();
      expect(seen['a'], isEmpty, reason: 'no echo of its own write');
      expect(seen['b'], ['pp_a']);
      expect(callsOf(a), 1);

      // The agent (no client id) moves it on: every tab hears of it.
      bridge.agentUpdate('pp_a', 'fixed');
      await tester.pump();
      await tester.pump();
      expect(seen['a'], ['pp_a']);
      await finish(tester);
    });
  });
}
