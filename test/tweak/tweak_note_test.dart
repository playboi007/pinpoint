import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/note_detail.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/sink/markdown_formatter.dart';

import '../support/fake_sink.dart';
import '../support/finish_send.dart';
import '../support/markers.dart';
import '../support/tweak_host.dart';

const String _file = 'test/tweak/tweak_note_test.dart';

/// Milestone 11, build step 3: the tweaks as a from-and-to diff in the
/// note, the line for the agent, and the before and after image.
void main() {
  const tweak = <String, Object?>{
    'renderType': 'RenderPadding',
    'property': 'padding',
    'from': 'EdgeInsets.all(8.0)',
    'to': 'EdgeInsets.all(16.0)',
    'createdBy': 'Padding',
    'nearestLocal': {
      'widget': 'Container',
      'source': {'file': 'lib/widgets/save_bar.dart', 'line': 31, 'column': 12},
    },
  };

  Annotation note({List<Map<String, Object?>> tweaks = const []}) => Annotation(
    id: 'pp_20261111_120000_abcd',
    createdAt: DateTime.utc(2026, 11, 11, 12),
    intent: AnnotationIntent.improve,
    comment: 'More room',
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(),
    target: const TargetInfo(widget: 'Container', sourceUnavailable: false),
    tweaks: tweaks,
  );

  group('model', () {
    test('schema 5 and up; tweaks only when there are some; round trip', () {
      expect(annotationSchema, greaterThanOrEqualTo(5));
      expect(note().toJson().containsKey('tweaks'), isFalse);
      final json = jsonDecode(
        jsonEncode(note(tweaks: [tweak]).toJson()),
      ) as Map<String, Object?>;
      expect(json['tweaks'], [tweak]);
      final back = Annotation.fromJson(json)!;
      expect(back.tweaks, [tweak]);
    });

    test('a malformed tweak is skipped on read', () {
      final json = note(tweaks: [tweak]).toJson()
        ..['tweaks'] = [
          tweak,
          'nonsense',
          {'property': 'x'},
        ];
      expect(Annotation.fromJson(json)!.tweaks, [tweak]);
    });
  });

  group('Markdown and MCP text', () {
    test('each tweak with where to apply it, and the line for the agent', () {
      final md = markdownFor(note(tweaks: [tweak]));
      expect(
        md,
        contains(
          'Tweaks: Apply these as source changes. A value may come from a '
          'theme or design token; change the token only if every use should '
          'change.\n'
          '- padding: EdgeInsets.all(8.0) -> EdgeInsets.all(16.0) '
          '(RenderPadding from Padding, in Container at '
          'lib/widgets/save_bar.dart:31:12)\n',
        ),
      );
      expect(markdownFor(note()), isNot(contains('Tweaks:')));
    });

    test('MCP standard detail carries the same lines', () {
      final text = noteText(
        note(tweaks: [tweak]).toJson(),
        NoteDetail.standard,
      );
      expect(text, contains('Tweaks: Apply these as source changes.'));
      expect(text, contains('- padding: EdgeInsets.all(8.0) -> '));
    });
  });

  group('through the app', () {
    late PinPointController controller;
    setUp(() => controller = PinPointController());
    tearDown(() => controller.dispose());

    Widget host(FakeSink sink) => MaterialApp(
      builder: (context, child) => PinPointWrapper(
        controller: controller,
        config: PinPointConfig(sinks: [sink]),
        child: child,
      ),
      home: Scaffold(
        body: Center(
          // PIN:tweaked_container
          child: Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFFBBDEFB),
            child: const Text('Room'),
          ),
        ),
      ),
    );

    Finder inApp(Finder finder) =>
        find.descendant(of: find.byType(Scaffold), matching: finder);

    Future<void> tweakAndSend(
      WidgetTester tester,
      FakeSink sink, {
      bool screenshot = true,
    }) async {
      await tester.pumpWidget(host(sink));
      await selectForTweak(tester, controller, inApp(find.byType(Container)));
      await typeInto(tester, tweakField('Padding', 'padding', 'left'), '16');
      await tester.tap(find.byKey(InfoPanel.commentTabKey));
      await tester.pump();
      await tester.enterText(find.byKey(CommentForm.fieldKey), 'More room');
      await tester.pump();
      if (!screenshot) {
        await tester.tap(find.byKey(CommentForm.screenshotKey));
        await tester.pump();
      }
      await tester.tap(find.byKey(CommentForm.sendKey));
      await finishSend(tester, controller);
    }

    // Acceptance: the note lists each tweak with the correct nearest local
    // widget and line.
    testWidgets('the note lists the tweak with its nearest local widget', (
      tester,
    ) async {
      final sink = FakeSink();
      await tweakAndSend(tester, sink, screenshot: false);
      expect(controller.mode, PinPointMode.idle, reason: 'sent');
      final tweaks = sink.notes.single.tweaks;
      expect(tweaks, hasLength(1));
      final t = tweaks.single;
      expect(t['renderType'], 'RenderPadding');
      expect(t['property'], 'padding');
      expect(t['from'], 'EdgeInsets.all(8.0)');
      expect(t['to'], 'EdgeInsets.all(16.0)');
      expect(t['createdBy'], 'Padding');
      final local = t['nearestLocal']! as Map<String, Object?>;
      expect(local['widget'], 'Container');
      final source = local['source']! as Map<String, Object?>;
      expect(source['file'], endsWith(_file));
      expect(source['line'], markerLine(_file, 'tweaked_container'));
      // Sending does not end the tweak: the user resets after the agent's
      // change is in.
      expect(controller.tweaks.length, 1);
    });

    testWidgets('with tweaks, the screenshot is a before and after pair', (
      tester,
    ) async {
      final sink = FakeSink();
      await tweakAndSend(tester, sink);
      final shot = sink.notes.single.screenshot!;
      expect(shot.beforeAfter, isTrue);
      expect(shot.toJson()['beforeAfter'], isTrue);
      final image = (await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(shot.png!);
        final frame = await codec.getNextFrame();
        codec.dispose();
        return frame.image;
      }))!;
      expect(image.width, shot.width);
      // Two crops side by side, each at least as wide as the crop.
      expect(shot.width, greaterThanOrEqualTo((shot.crop!.w * 2 * 2).floor()));
      image.dispose();
      expect(markdownFor(sink.notes.single), contains('left: before'));
      // The tweak is back on after the "before" image.
      expect(controller.tweaks.suspended, isFalse);
      expect(
        tester
            .renderObject<RenderPadding>(
              find.descendant(
                of: inApp(find.byType(Container)),
                matching: find.byType(Padding),
              ),
            )
            .padding,
        const EdgeInsets.all(16),
      );
    });
  });
}
