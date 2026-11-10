import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/note_view.dart';
import 'package:pinpoint/src/overlay/pin_marker.dart';

import '../fixtures/pin_fixture.dart';
import '../support/fake_sink.dart';
import '../support/finish_send.dart';

/// Milestone 8, build step 2 (second part): pins and drafts in the app.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(Widget home, {List<PinPointSink> sinks = const []}) =>
      MaterialApp(
        builder: (context, child) => PinPointWrapper(
          controller: controller,
          config: PinPointConfig(sinks: sinks),
          child: child,
        ),
        home: home,
      );

  Finder appText(String text) =>
      find.descendant(of: find.byType(Scaffold), matching: find.text(text));

  Finder pins() => find.byType(PinMarker);

  /// Picks the app text [text], writes [comment] and saves a draft.
  Future<String> saveDraft(
    WidgetTester tester,
    String text, {
    String comment = 'Too tight',
  }) async {
    if (controller.mode == PinPointMode.idle) controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText(text)));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), comment);
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.draftKey));
    await tester.pump();
    await finishSend(tester, controller);
    await tester.pump();
    return controller.notes.notes.last.id;
  }

  Offset pinCenter(WidgetTester tester, String id) =>
      tester.getCenter(find.byKey(ValueKey<String>('pinpoint.pin.$id')));

  /// The pin is centered on the widget's top-right corner, pushed inside
  /// the screen.
  void expectOnTopRight(WidgetTester tester, String id, Finder widget) {
    final rect = tester.getRect(widget);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    const half = PinMarker.size / 2;
    final center = pinCenter(tester, id);
    expect(
      center.dx,
      moreOrLessEquals(
        rect.right.clamp(half, screen.width - half),
        epsilon: 0.5,
      ),
    );
    expect(
      center.dy,
      moreOrLessEquals(
        rect.top.clamp(half, screen.height - half),
        epsilon: 0.5,
      ),
    );
  }

  group('drafts', () {
    testWidgets('Save draft makes a numbered draft pin and goes back to '
        'picking', (tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      final id = await saveDraft(tester, 'row 1');

      final note = controller.notes.byId(id)!;
      expect(note.status, NoteStatus.draft);
      expect(note.comment, 'Too tight');
      expect(note.anchor!.widget, 'Text');
      expect(note.anchor!.ordinal, 1);
      expect(controller.mode, PinPointMode.picking);
      expect(controller.draft.text.text, isEmpty);
      expect(controller.selection.value, isNull);

      expect(pins(), findsOneWidget);
      expect(tester.widget<PinMarker>(pins()).number, 1);
      expect(tester.widget<PinMarker>(pins()).status, NoteStatus.draft);
      expectOnTopRight(tester, id, appText('row 1'));
    });

    testWidgets('a draft goes to no sink', (tester) async {
      final sink = FakeSink();
      await tester.pumpWidget(host(const PinFixture(), sinks: [sink]));
      await saveDraft(tester, 'Title');
      expect(sink.notes, isEmpty);
    });

    testWidgets('Send makes a submitted pin', (tester) async {
      final sink = FakeSink();
      await tester.pumpWidget(host(const PinFixture(), sinks: [sink]));
      controller.startPicking();
      await tester.pump();
      await tester.tapAt(tester.getCenter(appText('Title')));
      await tester.pump();
      await tester.enterText(find.byKey(CommentForm.fieldKey), 'Bigger');
      await tester.pump();
      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await finishSend(tester, controller);
      await tester.pump();

      expect(sink.notes.single.status, NoteStatus.submitted);
      final note = controller.notes.notes.single;
      expect(note.status, NoteStatus.submitted);
      expect(tester.widget<PinMarker>(pins()).status, NoteStatus.submitted);
      expectOnTopRight(tester, note.id, appText('Title'));
    });
  });

  group('acceptance: a pin stays on its widget', () {
    testWidgets('through a scroll', (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(host(PinListFixture(controller: scroll)));
      final id = await saveDraft(tester, 'Item 6');
      controller.stop();
      await tester.pump();
      expectOnTopRight(tester, id, appText('Item 6'));

      scroll.jumpTo(100);
      await tester.pump();
      await tester.pump();
      expectOnTopRight(tester, id, appText('Item 6'));

      // Scrolled out of the list's viewport: no pin.
      scroll.jumpTo(2000);
      await tester.pump();
      await tester.pump();
      expect(pins(), findsNothing);

      // And back, with no frame after the jump: the throttled lookup still
      // runs once.
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expectOnTopRight(tester, id, appText('Item 6'));
    });

    testWidgets('through a window resize', (tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      final id = await saveDraft(tester, 'row 2');
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.pump();
      expectOnTopRight(tester, id, appText('row 2'));
    });

    testWidgets('through a hot reload', (tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      final id = await saveDraft(tester, 'row 0');
      final reload = tester.binding.reassembleApplication();
      await tester.pump();
      await reload;
      await tester.pump();
      await tester.pump();
      expectOnTopRight(tester, id, appText('row 0'));
    });

    // Acceptance: "After the agent inserts ten lines above the widget, the
    // pin still resolves." A restarted app has only the anchor, ten lines
    // off.
    testWidgets('when ten lines were inserted above it', (tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      final id = await saveDraft(tester, 'Title');
      final note = controller.notes.byId(id)!;
      final star = await (() async {
        // The star icon's anchor, made the way a pin makes it.
        await tester.tapAt(tester.getCenter(find.byIcon(Icons.star)));
        await tester.pump();
        return controller.selection.value!;
      })();
      controller.stop();
      await tester.pump();
      final iconLine = star.entry.location!.line;

      // A fresh book: no element is known, only the moved anchor.
      controller.notes.remove(id);
      controller.notes.put(
        note.copyWith(
          anchor: () => NoteAnchor(
            file: note.anchor!.file,
            line: iconLine - 10,
            widget: 'Icon',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expectOnTopRight(tester, id, find.byIcon(Icons.star));
      // The anchor follows the widget, so the next edit counts from here.
      expect(controller.notes.byId(id)!.anchor!.line, iconLine);
    });
  });

  testWidgets('a pin hides while its route is beneath another', (tester) async {
    await tester.pumpWidget(host(const PinFixture()));
    await saveDraft(tester, 'Title');
    controller.stop();
    await tester.pump();
    expect(pins(), findsOneWidget);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other')),
      ),
    );
    await tester.pumpAndSettle();
    expect(pins(), findsNothing);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(pins(), findsOneWidget);
  });

  group('a click on a pin', () {
    testWidgets('opens its note in the panel, from idle', (tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      final id = await saveDraft(tester, 'row 1', comment: 'Wrap it');
      controller.stop();
      await tester.pump();

      await tester.tap(pins());
      await tester.pump();
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting);
      expect(controller.openNote.value, id);
      expect(find.byType(NoteView), findsOneWidget);
      expect(find.textContaining('Note 1 · draft'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(NoteView.fieldKey),
          matching: find.text('Wrap it'),
        ),
        findsOneWidget,
      );
      expect(
        (controller.selection.value!.element.widget as Text).data,
        'row 1',
      );
    });

    testWidgets('Send submits the draft to every sink', (tester) async {
      final sink = FakeSink();
      await tester.pumpWidget(host(const PinFixture(), sinks: [sink]));
      final id = await saveDraft(tester, 'row 1');
      await tester.tap(pins());
      await tester.pump();
      await tester.enterText(find.byKey(NoteView.fieldKey), 'Wrap it now');
      await tester.pump();
      await tester.tap(find.byKey(NoteView.sendKey));
      await tester.pump();
      await tester.pump();

      expect(sink.notes.single.comment, 'Wrap it now');
      expect(sink.notes.single.status, NoteStatus.submitted);
      expect(controller.notes.byId(id)!.status, NoteStatus.submitted);
      expect(find.textContaining('Note 1 · sent'), findsOneWidget);
    });

    testWidgets('Send all submits every draft', (tester) async {
      final sink = FakeSink();
      await tester.pumpWidget(host(const PinFixture(), sinks: [sink]));
      await saveDraft(tester, 'row 0');
      await saveDraft(tester, 'row 2');
      expect(controller.notes.drafts, hasLength(2));
      await tester.tap(pins().first);
      await tester.pump();
      await tester.tap(find.byKey(NoteView.sendAllKey));
      await tester.pump();
      await tester.pump();
      expect(sink.notes, hasLength(2));
      expect(controller.notes.drafts, isEmpty);
    });

    testWidgets('a failed send keeps the draft', (tester) async {
      final sink = FakeSink(error: Exception('refused'));
      await tester.pumpWidget(host(const PinFixture(), sinks: [sink]));
      final id = await saveDraft(tester, 'row 1');
      await tester.tap(pins());
      await tester.pump();
      await tester.tap(find.byKey(NoteView.sendKey));
      await tester.pump();
      await tester.pump();
      expect(controller.notes.byId(id)!.status, NoteStatus.draft);
      expect(find.textContaining('refused'), findsOneWidget);
    });

    testWidgets('Delete removes the note and its pin', (tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      await saveDraft(tester, 'row 1');
      await tester.tap(pins());
      await tester.pump();
      await tester.tap(find.byKey(NoteView.deleteKey));
      await tester.pump();
      await tester.pump();
      expect(controller.notes.notes, isEmpty);
      expect(pins(), findsNothing);
      expect(find.byType(NoteView), findsNothing);
    });
  });

  group('a note the agent is done with', () {
    Future<String> resolvedPin(WidgetTester tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      final id = await saveDraft(tester, 'Title');
      controller.notes.put(
        controller.notes
            .byId(id)!
            .withStatus(NoteStatus.resolved)
            .copyWith(
              messages: [
                NoteMessage(
                  at: DateTime.utc(2026, 11, 10),
                  from: 'agent',
                  text: 'Made it bigger.',
                ),
              ],
            ),
      );
      await tester.pump();
      await tester.pump();
      return id;
    }

    // PLAN.md, Milestone 8, watch out: the agent can mark a note resolved
    // without fixing it, so a resolved pin fades but stays for the user.
    testWidgets('shows a tick and fades, but stays', (tester) async {
      await resolvedPin(tester);
      expect(
        find.descendant(of: pins(), matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      await tester.pump(PinMarker.fadeDuration);
      final fade = tester.widget<AnimatedOpacity>(
        find.descendant(of: pins(), matching: find.byType(AnimatedOpacity)),
      );
      expect(fade.opacity, PinMarker.fadedOpacity);
      await tester.pump(const Duration(seconds: 10));
      expect(pins(), findsOneWidget);
    });

    testWidgets('Accept removes the pin; Reopen sends it back', (tester) async {
      final id = await resolvedPin(tester);
      await tester.tap(pins());
      await tester.pump();
      expect(
        find.textContaining('Made it bigger.', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.byKey(NoteView.reopenKey));
      await tester.pump();
      expect(controller.notes.byId(id)!.status, NoteStatus.submitted);

      controller.notes.put(
        controller.notes.byId(id)!.withStatus(NoteStatus.resolved),
      );
      await tester.pump();
      await tester.tap(find.byKey(NoteView.acceptKey));
      await tester.pump();
      await tester.pump();
      expect(controller.notes.byId(id)!.status, NoteStatus.verified);
      expect(pins(), findsNothing);
    });
  });

  // Engineering rule 2: placing pins after each frame must not keep the app
  // drawing.
  testWidgets('settled pins schedule no frames', (tester) async {
    await tester.pumpWidget(host(const PinFixture()));
    await saveDraft(tester, 'row 1');
    controller.stop();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(pins(), findsOneWidget);
    expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
  });
}
