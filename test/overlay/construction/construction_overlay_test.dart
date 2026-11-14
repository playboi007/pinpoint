import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/commands.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/construction/construction_stage.dart';

import '../../fixtures/pin_fixture.dart';
import '../../support/fake_construction_stage.dart';
import '../../support/finish_send.dart';

/// The construction site in the real overlay, with a fake stage: it follows
/// a note's status and its widget, and it draws no Flutter frame.
void main() {
  late PinPointController controller;
  late FakeConstructionStage stage;

  setUp(() {
    controller = PinPointController();
    stage = FakeConstructionStage();
    debugConstructionStage = () => stage;
  });

  tearDown(() {
    debugConstructionStage = null;
    controller.dispose();
  });

  Widget host({bool reduced = false, Widget home = const PinFixture()}) =>
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: PinPointWrapper(
            controller: controller,
            config: const PinPointConfig(sinks: []),
            child: child,
          ),
        ),
        home: home,
      );

  Future<String> noteAt(WidgetTester tester, Offset point) async {
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(point);
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Bigger');
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.draftKey));
    await tester.pump();
    await finishSend(tester, controller);
    await tester.pump();
    controller.stop();
    await tester.pump();
    return controller.notes.notes.last.id;
  }

  Future<String> noteOnTitle(WidgetTester tester) async =>
      noteAt(tester, tester.getCenter(find.text('Title')));

  Future<void> setStatus(
    WidgetTester tester,
    String id,
    NoteStatus status,
  ) async {
    controller.notes.put(controller.notes.byId(id)!.withStatus(status));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a site goes up on the widget while the note is in progress, '
      'and the app draws no frame for it', (tester) async {
    await tester.pumpWidget(host());
    final id = await noteOnTitle(tester);
    expect(stage.sites, isEmpty, reason: 'a draft is not worked on');

    await setStatus(tester, id, NoteStatus.inProgress);
    expect(stage.sites.keys, [id]);
    final title = tester.getRect(find.text('Title'));
    expect(stage.sites[id], title);
    // A Text has no boxes inside: the blueprint is the generic one.
    expect(stage.boxes[id], isNotEmpty);
    for (final b in stage.boxes[id]!) {
      expect(b.left + b.width, lessThanOrEqualTo(title.width + 0.01));
      expect(b.top + b.height, lessThanOrEqualTo(title.height + 0.01));
    }

    // Settle, then check that nothing runs.
    await tester.pump(const Duration(seconds: 1));
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    // The agent's commands wait only while the app draws: no extra wait.
    expect(AgentCommands.appIsMoving, isFalse);

    // Planning (2.5 s) and building have no frame: they are CSS delays.
    await tester.pump(const Duration(seconds: 3));
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pump(const Duration(seconds: 30));
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(AgentCommands.appIsMoving, isFalse);
    // Read once: no second add or move for a widget that stays.
    expect(stage.calls, ['add:$id']);
  });

  testWidgets('the blueprint is the boxes of the real widget, read once', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.all(20),
              child: SizedBox(
                width: 300,
                height: 60,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(width: 40, height: 20),
                    SizedBox(width: 40, height: 40),
                    SizedBox(width: 40, height: 30),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The gap between the first two boxes.
    final id = await noteAt(tester, const Offset(20 + 40 + 30, 20 + 30));
    await setStatus(tester, id, NoteStatus.inProgress);
    final rect = stage.sites[id]!;
    final boxes = stage.boxes[id]!;
    final sizes = {for (final b in boxes) (b.width, b.height)};
    expect(sizes, containsAll([(40.0, 20.0), (40.0, 40.0), (40.0, 30.0)]));
    for (final b in boxes) {
      expect(b.left, greaterThanOrEqualTo(0));
      expect(b.left + b.width, lessThanOrEqualTo(rect.width + 0.01));
    }
    // Relative to the widget: the first box is at its left edge.
    final first = boxes.firstWhere((b) => b.width == 40 && b.height == 20);
    expect(first.left, closeTo(0, 0.2));

    await tester.pump(const Duration(seconds: 5));
    expect(stage.calls, ['add:$id']);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('other statuses fade the site away', (tester) async {
    await tester.pumpWidget(host());
    final id = await noteOnTitle(tester);
    await setStatus(tester, id, NoteStatus.inProgress);
    await setStatus(tester, id, NoteStatus.submitted);
    expect(stage.sites, isEmpty);
    expect(stage.fades, [true]);
    expect(stage.reveals, isEmpty);
  });

  testWidgets('deleting the note takes the site away', (tester) async {
    await tester.pumpWidget(host());
    final id = await noteOnTitle(tester);
    await setStatus(tester, id, NoteStatus.inProgress);
    controller.notes.remove(id);
    await tester.pump();
    await tester.pump();
    expect(stage.sites, isEmpty);
  });

  testWidgets('fixed: one picture is taken, the reveal plays, the site goes, '
      'and the app is still not drawing', (tester) async {
    await tester.pumpWidget(host());
    final id = await noteOnTitle(tester);
    await setStatus(tester, id, NoteStatus.inProgress);
    await setStatus(tester, id, NoteStatus.fixed);
    // The engine makes the image outside the test's fake clock.
    for (var i = 0; i < 20 && !stage.reveals.containsKey(id); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(stage.reveals.containsKey(id), isTrue);
    final png = stage.reveals[id];
    expect(png, isNotNull, reason: 'the widget was captured');
    // A PNG.
    expect(png!.sublist(1, 4), [0x50, 0x4E, 0x47]);

    // The pin's own hop (a Flutter animation that is older than the site)
    // ends first. The reveal itself then runs with no frame at all.
    await tester.pump(const Duration(milliseconds: 700));
    expect(stage.sites, isNotEmpty, reason: 'the finish is still playing');
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(AgentCommands.appIsMoving, isFalse);

    await tester.pump(const Duration(seconds: 2));
    expect(stage.sites, isEmpty);
    expect(stage.fades.last, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion reaches the stage, and fixed just removes', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduced: true));
    expect(stage.reduced, isTrue);
    final id = await noteOnTitle(tester);
    await setStatus(tester, id, NoteStatus.inProgress);
    expect(stage.sites.keys, [id], reason: 'it shows still');
    await setStatus(tester, id, NoteStatus.fixed);
    expect(stage.sites, isEmpty);
    expect(stage.reveals, isEmpty);

    await tester.pumpWidget(host());
    expect(stage.reduced, isFalse);
  });

  testWidgets('the palette reaches the stage', (tester) async {
    await tester.pumpWidget(host());
    final redline = stage.colors;
    expect(redline, isNotNull);
    controller.palette.value = PinPointPalette.cobalt;
    await tester.pump();
    expect(stage.colors, isNot(redline));
  });

  testWidgets('the overlay takes the stage down when it goes', (tester) async {
    await tester.pumpWidget(host());
    expect(stage.disposed, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(stage.disposed, isTrue);
  });
}
