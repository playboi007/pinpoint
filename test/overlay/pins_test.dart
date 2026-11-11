import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/note_view.dart';
import 'package:pinpoint/src/overlay/pin_marker.dart';
import 'package:pinpoint/src/overlay/pin_tracker.dart';
import 'package:pinpoint/src/search/source_index.dart';
import 'package:pinpoint/src/theme/controls.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

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

  group('a pin by state', () {
    const tokens = PinPointTokens.redline;

    Future<void> show(
      WidgetTester tester,
      NoteStatus status, {
      bool? checks,
      bool selected = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PinMarker(
              number: 4,
              status: status,
              checksPassed: checks,
              selected: selected,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    BoxDecoration body(WidgetTester tester) =>
        tester.widget<DecoratedBox>(find.byKey(PinMarker.bodyKey)).decoration
            as BoxDecoration;

    /// The hard shadows under the pin: the ones with an offset.
    List<BoxShadow> hardShadows(WidgetTester tester) => [
      for (final shadow in body(tester).boxShadow ?? const <BoxShadow>[])
        if (shadow.offset != Offset.zero) shadow,
    ];

    Finder dashes() => find.descendant(
      of: find.byType(PinMarker),
      matching: find.byType(DashedBox),
    );

    Positioned badgeBox(WidgetTester tester, Key key) =>
        tester.widget<Positioned>(
          find
              .ancestor(of: find.byKey(key), matching: find.byType(Positioned))
              .first,
        );

    testWidgets('a draft has a dotted muted border, no shadow, no badge', (
      tester,
    ) async {
      await show(tester, NoteStatus.draft);
      final border = tester.widget<DashedBox>(dashes());
      expect(border.dash, PinMarker.dotted);
      expect(border.strokeWidth, 1.5);
      expect(border.color, tokens.muted);
      expect(body(tester).color, tokens.paper);
      expect(hardShadows(tester), isEmpty);
      expect(find.byKey(PinMarker.badgeKey), findsNothing);
      expect(tester.getSize(find.byType(PinMarker)), const Size(22, 22));
    });

    testWidgets('a sent pin has a solid ink border and a 2,2 hard shadow', (
      tester,
    ) async {
      await show(tester, NoteStatus.submitted);
      expect(dashes(), findsNothing);
      final shadow = hardShadows(tester).single;
      expect(shadow.offset, const Offset(2, 2));
      expect(shadow.blurRadius, 0);
      expect(shadow.color, tokens.shadow);
      expect(body(tester).color, tokens.paper);
      expect(find.byKey(PinMarker.badgeKey), findsNothing);
    });

    testWidgets('an in-progress pin is dashed and has a top-right badge', (
      tester,
    ) async {
      await show(tester, NoteStatus.inProgress);
      expect(tester.widget<DashedBox>(dashes()).dash, PinMarker.dashed);
      expect(hardShadows(tester), hasLength(1));
      expect(
        find.descendant(
          of: find.byKey(PinMarker.badgeKey),
          matching: find.byIcon(Icons.more_horiz),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(PinMarker.badgeKey)),
        const Size(13, 13),
      );
      final place = badgeBox(tester, PinMarker.badgeKey);
      expect(place.top, isNotNull);
      expect(place.bottom, isNull);
      final badge = tester.widget<DecoratedBox>(find.byKey(PinMarker.badgeKey));
      expect((badge.decoration as BoxDecoration).color, tokens.accent);
    });

    testWidgets('a fixed pin is filled with ink and has a check at the '
        'bottom right', (tester) async {
      await show(tester, NoteStatus.fixed);
      expect(body(tester).color, tokens.ink);
      expect(hardShadows(tester), hasLength(1));
      expect(
        find.descendant(
          of: find.byKey(PinMarker.badgeKey),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      final place = badgeBox(tester, PinMarker.badgeKey);
      expect(place.bottom, isNotNull);
      expect(place.top, isNull);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(PinMarker.badgeKey),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.color, tokens.ok);
      final number = tester.widget<Text>(find.text('4'));
      expect(number.style!.color, tokens.paper);
    });

    testWidgets('a resolved pin is a faded fixed pin with a done_all badge', (
      tester,
    ) async {
      await show(tester, NoteStatus.resolved);
      expect(body(tester).color, tokens.ink);
      expect(
        find.descendant(
          of: find.byKey(PinMarker.badgeKey),
          matching: find.byIcon(Icons.done_all),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0.4,
      );
    });

    testWidgets('a rejected pin is faded, struck through, has a cross and '
        'no shadow', (tester) async {
      await show(tester, NoteStatus.rejected);
      expect(body(tester).color, tokens.paper);
      expect(hardShadows(tester), isEmpty);
      expect(
        find.descendant(
          of: find.byKey(PinMarker.badgeKey),
          matching: find.byIcon(Icons.close),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('4')).style!.decoration,
        TextDecoration.lineThrough,
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0.4,
      );
    });

    testWidgets('a passed check adds a round green badge with a check', (
      tester,
    ) async {
      await show(tester, NoteStatus.fixed, checks: true);
      final badge = tester.widget<DecoratedBox>(
        find.byKey(PinMarker.checksKey),
      );
      final decoration = badge.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, tokens.ok);
      expect(
        tester.getSize(find.byKey(PinMarker.checksKey)),
        const Size(15, 15),
      );
      expect(
        find.descendant(
          of: find.byKey(PinMarker.checksKey),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(badgeBox(tester, PinMarker.checksKey).top, isNotNull);
    });

    testWidgets('a failed check adds a square red badge with "!"', (
      tester,
    ) async {
      await show(tester, NoteStatus.fixed, checks: false);
      final badge = tester.widget<DecoratedBox>(
        find.byKey(PinMarker.checksKey),
      );
      final decoration = badge.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.rectangle);
      expect(decoration.color, tokens.err);
      expect(
        find.descendant(
          of: find.byKey(PinMarker.checksKey),
          matching: find.text('!'),
        ),
        findsOneWidget,
      );
      expect(badgeBox(tester, PinMarker.checksKey).top, isNotNull);
    });

    testWidgets('no check, no verification badge', (tester) async {
      await show(tester, NoteStatus.fixed);
      expect(find.byKey(PinMarker.checksKey), findsNothing);
    });

    testWidgets('a selected pin gets the canvas selected outline', (
      tester,
    ) async {
      Finder outlined() => find.descendant(
        of: find.byType(PinMarker),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.foregroundPainter != null,
        ),
      );
      // Just outside the 22 px pin, so its own border stays visible.
      const pin = Rect.fromLTWH(0, 0, 22, 22);
      await show(tester, NoteStatus.submitted, selected: true);
      expect(
        tester.renderObject(outlined()),
        paints
          ..rect(rect: pin.inflate(3.5), color: tokens.ink)
          ..rect(rect: pin.inflate(2.5), color: tokens.paper)
          ..rect(rect: pin.inflate(1), color: tokens.accent, strokeWidth: 2),
      );
      await show(tester, NoteStatus.submitted);
      expect(
        tester.renderObject(outlined()),
        isNot(paints..rect(color: tokens.accent)),
      );
    });

    testWidgets('the layer selects the pin of the open note', (tester) async {
      final placements = ValueNotifier<List<PinPlacement>>([
        const PinPlacement(
          id: 'a',
          number: 1,
          status: NoteStatus.submitted,
          rect: Rect.fromLTWH(100, 100, 50, 20),
        ),
        const PinPlacement(
          id: 'b',
          number: 2,
          status: NoteStatus.submitted,
          rect: Rect.fromLTWH(300, 100, 50, 20),
        ),
      ]);
      final open = ValueNotifier<String?>(null);
      addTearDown(placements.dispose);
      addTearDown(open.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PinLayer(
              placements: placements,
              openNote: open,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      List<bool> selected() => [
        for (final pin in tester.widgetList<PinMarker>(find.byType(PinMarker)))
          pin.selected,
      ];
      expect(selected(), [false, false]);
      open.value = 'b';
      await tester.pump();
      expect(selected(), [false, true]);
    });

    testWidgets('a tap anywhere on the 22 px box reaches onTap', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PinMarker(
                number: 1,
                status: NoteStatus.draft,
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(PinMarker));
      await tester.tapAt(rect.topLeft + const Offset(1, 1));
      await tester.tapAt(rect.bottomRight - const Offset(1, 1));
      expect(taps, 2);
    });
  });

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
        find.descendant(of: pins(), matching: find.byIcon(Icons.done_all)),
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

  group('a pin whose widget is not on this page', () {
    tearDown(() => PinTracker.debugUrl = null);

    /// Saves a note on the title, then shows a page without it.
    Future<void> leavePage(WidgetTester tester) async {
      await tester.pumpWidget(host(const PinFixture()));
      await saveDraft(tester, 'Title');
      controller.stop();
      await tester.pumpWidget(host(const Scaffold(body: Text('another page'))));
      await tester.pump();
      expect(pins(), findsNothing);
    }

    /// Draws a frame every 100 ms for [seconds], as hovering does.
    Future<void> drawFrames(WidgetTester tester, int seconds) async {
      for (var i = 0; i < seconds * 10; i++) {
        // A pump draws only a frame that something asked for.
        SchedulerBinding.instance.scheduleFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('is looked up less and less often while frames are drawn', (
      tester,
    ) async {
      await leavePage(tester);
      SourceIndex.debugWalks = 0;
      await drawFrames(tester, 10);
      // Every 500 ms would be 20 walks of the whole app.
      expect(SourceIndex.debugWalks, lessThanOrEqualTo(6));
      SourceIndex.debugWalks = 0;
      await drawFrames(tester, 8);
      expect(SourceIndex.debugWalks, lessThanOrEqualTo(2));
    });

    testWidgets('is looked up at once when the page URL changes', (
      tester,
    ) async {
      var url = Uri.parse('http://localhost/other');
      PinTracker.debugUrl = () => url;
      await leavePage(tester);
      await drawFrames(tester, 10);

      // A navigation changes the URL, then draws the new page.
      url = Uri.parse('http://localhost/');
      await tester.pumpWidget(host(const PinFixture()));
      await tester.pump();
      expect(pins(), findsOneWidget);
    });

    testWidgets('comes back within the longest wait without a URL change', (
      tester,
    ) async {
      await leavePage(tester);
      await drawFrames(tester, 10);
      await tester.pumpWidget(host(const PinFixture()));
      await tester.pump(PinTracker.maxRetryInterval);
      await tester.pump();
      expect(pins(), findsOneWidget);
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
