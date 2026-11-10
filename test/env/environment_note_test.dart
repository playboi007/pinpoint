import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/fake_sink.dart';
import '../support/finish_send.dart';

/// Milestone 9, plan step 9: every note records the active overrides.
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

  Future<void> comment(WidgetTester tester, List<PinPointSink> sinks) async {
    tester.view.physicalSize = const Size(1200, 1000) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(sinks));
    controller.environment.value = const Environment(
      viewport: Size(360, 800),
      textScale: 1.5,
    );
    await tester.pump();
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(
        find.descendant(of: find.byType(Scaffold), matching: find.text('Save')),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(CommentForm.fieldKey), 'Too tight');
    await tester.pump();
  }

  testWidgets('acceptance: a note filed at 360 wide and text scale 1.5 '
      'carries both in environment', (tester) async {
    final sink = FakeSink();
    await comment(tester, [sink]);
    await tester.tap(find.byKey(CommentForm.sendKey));
    await tester.pump();
    await finishSend(tester, controller);

    final note = sink.notes.single;
    expect(note.environment, {
      'viewport': {'width': 360, 'height': 800},
      'textScale': 1.5,
    });
    // The page keeps the real window; the overrides are separate.
    expect(note.page.viewport!.width, 1200);
    expect(
      note.toMarkdown(),
      contains('What-if: viewport 360x800, textScale 1.5'),
    );
    // The screenshot was taken from the moved and scaled boundary.
    expect(note.errors, isNot(contains('screenshot')));
  });

  testWidgets('a saved draft keeps the environment it was filed in', (
    tester,
  ) async {
    await comment(tester, [FakeSink()]);
    await tester.tap(find.byKey(CommentForm.draftKey));
    await tester.pump();
    await finishSend(tester, controller);
    controller.environment.reset();
    await tester.pump();

    final draft = controller.notes.drafts.single;
    expect(draft.environment, containsPair('textScale', 1.5));
  });

  testWidgets('with nothing overridden the note has no environment', (
    tester,
  ) async {
    final sink = FakeSink();
    await comment(tester, [sink]);
    controller.environment.reset();
    await tester.pump();
    await tester.tap(find.byKey(CommentForm.sendKey));
    await tester.pump();
    await finishSend(tester, controller);
    expect(sink.notes.single.environment, isNull);
    expect(sink.notes.single.toJson().containsKey('environment'), isFalse);
  });
}
