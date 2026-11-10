import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/toast_layer.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/fake_sink.dart';

/// Milestone 5, build step 3: the send flow with a toast per sink.
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

  final field = find.byKey(CommentForm.fieldKey);
  final toasts = find.byKey(ToastLayer.layerKey);
  Finder toast(Pattern text) => find.descendant(
    of: toasts,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Text && text.allMatches(widget.data ?? '').isNotEmpty,
    ),
  );

  Future<void> writeComment(
    WidgetTester tester,
    List<PinPointSink> sinks,
  ) async {
    await tester.pumpWidget(host(sinks));
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(
        find.descendant(of: find.byType(Scaffold), matching: find.text('Save')),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(field, 'Too tight');
    await tester.pump();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byKey(CommentForm.sendKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  testWidgets('acceptance: with the receiver stopped, the toast reports the '
      'failure and the text is still in the field', (tester) async {
    final http = FakeSink(name: 'HTTP', error: Exception('Connection refused'));
    await writeComment(tester, [http]);
    await send(tester);

    expect(toast(RegExp('HTTP failed: .*Connection refused')), findsOneWidget);
    expect(controller.mode, PinPointMode.commenting);
    expect(
      find.descendant(of: field, matching: find.text('Too tight')),
      findsOneWidget,
    );
    final copy = tester.widget<ButtonStyleButton>(
      find.byKey(CommentForm.copyKey),
    );
    expect(copy.enabled, isTrue, reason: 'the comment is never lost');
  });

  testWidgets('one toast per sink, in order', (tester) async {
    final clipboard = FakeSink(name: 'Clipboard');
    final http = FakeSink(name: 'HTTP', error: Exception('timeout'));
    await writeComment(tester, [clipboard, http]);
    await send(tester);

    final first = tester.getTopLeft(toast('Sent to Clipboard'));
    final second = tester.getTopLeft(toast(RegExp('HTTP failed')));
    expect(first.dy, lessThan(second.dy));
    expect(clipboard.notes, hasLength(1));
    expect(http.notes, hasLength(1));
    expect(controller.mode, PinPointMode.commenting, reason: 'one failed');
    expect(controller.draft.text.text, 'Too tight');
  });

  testWidgets('a full success says so and clears the comment', (tester) async {
    await writeComment(tester, [FakeSink(name: 'HTTP')]);
    await send(tester);
    expect(toast('Sent to HTTP'), findsOneWidget);
    expect(controller.mode, PinPointMode.idle);
    expect(controller.draft.text.text, isEmpty);
  });

  testWidgets('with no sinks, the toast says so and the text stays', (
    tester,
  ) async {
    await writeComment(tester, const []);
    await send(tester);
    expect(toast(RegExp('No sink')), findsOneWidget);
    expect(controller.mode, PinPointMode.commenting);
    expect(controller.draft.text.text, 'Too tight');
  });

  testWidgets('toasts go away by themselves', (tester) async {
    await writeComment(tester, [FakeSink(name: 'HTTP')]);
    await send(tester);
    expect(toast('Sent to HTTP'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(toast('Sent to HTTP'), findsNothing);
  });

  testWidgets('toasts sit outside the app boundary and take no clicks', (
    tester,
  ) async {
    await writeComment(tester, [FakeSink(name: 'HTTP')]);
    await send(tester);
    final appBoundary = find
        .descendant(
          of: find.byType(PinPointWrapper),
          matching: find.byType(RepaintBoundary),
        )
        .first;
    expect(find.descendant(of: appBoundary, matching: toasts), findsNothing);
    final ignore = tester.widget<IgnorePointer>(
      find.descendant(of: toasts, matching: find.byType(IgnorePointer)).first,
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('Copy as Markdown copies the note and keeps the comment', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await writeComment(tester, const []);
    await tester.tap(find.byKey(CommentForm.copyKey));
    await tester.pump();
    await tester.pump();

    expect(copied, contains('Comment: Too tight'));
    expect(copied, contains('save_bar_fixture.dart:'));
    expect(toast('Copied as Markdown'), findsOneWidget);
    expect(controller.mode, PinPointMode.commenting);
    expect(controller.draft.text.text, 'Too tight');
  });
}
