import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/toast_layer.dart';

import '../support/fake_sink.dart';
import '../support/finish_send.dart';

/// Milestone 6, build step 3: Send captures the screenshot when the box is
/// ticked and puts it in the note.
void main() {
  late PinPointController controller;
  late ValueNotifier<Offset> shift;

  setUp(() {
    controller = PinPointController();
    shift = ValueNotifier<Offset>(Offset.zero);
  });
  tearDown(() {
    controller.dispose();
    shift.dispose();
  });

  Widget host(
    List<PinPointSink> sinks, {
    int maxScreenshotWidth = 1600,
    double targetWidth = 120,
  }) => MaterialApp(
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: PinPointConfig(
        sinks: sinks,
        maxScreenshotWidth: maxScreenshotWidth,
      ),
      child: child,
    ),
    home: Scaffold(
      body: Center(
        child: ValueListenableBuilder<Offset>(
          valueListenable: shift,
          builder: (context, offset, child) =>
              Transform.translate(offset: offset, child: child),
          child: ColoredBox(
            color: const Color(0xFF00AA00),
            child: SizedBox(
              width: targetWidth,
              height: 40,
              child: Text('Target'),
            ),
          ),
        ),
      ),
    ),
  );

  final field = find.byKey(CommentForm.fieldKey);
  final box = find.byKey(CommentForm.screenshotKey);
  Finder toast(Pattern text) => find.descendant(
    of: find.byKey(ToastLayer.layerKey),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Text && text.allMatches(widget.data ?? '').isNotEmpty,
    ),
  );

  Future<void> writeComment(
    WidgetTester tester,
    FakeSink sink, {
    int maxScreenshotWidth = 1600,
    double targetWidth = 120,
  }) async {
    await tester.pumpWidget(
      host(
        [sink],
        maxScreenshotWidth: maxScreenshotWidth,
        targetWidth: targetWidth,
      ),
    );
    // Clear of the launcher at the bottom left: the footer buttons sit at the
    // panel's bottom edge.
    controller.panelPosition = const Offset(300, 20);
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(
        find.descendant(
          of: find.byType(Scaffold),
          matching: find.text('Target'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(field, 'Too tight');
    await tester.pump();
  }

  /// Taps Send and lets the capture finish. The image is made by the engine
  /// outside the test's fake clock, so each round gives it real time.
  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byKey(CommentForm.sendKey));
    await finishSend(tester, controller);
  }

  testWidgets('acceptance: unticking "Include screenshot" sends a payload '
      'with no screenshot key', (tester) async {
    final sink = FakeSink();
    await writeComment(tester, sink);
    await tester.tap(box);
    await tester.pump();
    expect(controller.draft.includeScreenshot, isFalse);
    await send(tester);

    expect(sink.notes, hasLength(1));
    final note = sink.notes.single;
    expect(note.screenshot, isNull);
    expect(note.toJson().containsKey('screenshot'), isFalse);
    expect(
      note.toJson(includeScreenshotData: true).containsKey('screenshot'),
      isFalse,
    );
  });

  testWidgets('ticked, the note carries a PNG named after it, at the '
      'device pixel ratio capped at 2', (tester) async {
    expect(tester.view.devicePixelRatio, 3, reason: 'the test view');
    final sink = FakeSink();
    await writeComment(tester, sink);
    await send(tester);

    expect(controller.mode, PinPointMode.idle, reason: 'sent');
    final note = sink.notes.single;
    final shot = note.screenshot!;
    expect(shot.file, '${note.id}.png');
    expect(shot.pixelRatio, 2);
    expect(shot.hasPlatformViews, isFalse);
    expect(shot.debugPaint, isEmpty);

    final image = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(shot.png!);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    }))!;
    expect(image.width, shot.width);
    expect(image.height, shot.height);
    expect(shot.width, (shot.crop!.w * 2).round());
    image.dispose();
    // The image goes to sinks only when they ask.
    expect((note.toJson()['screenshot']! as Map).containsKey('data'), isFalse);
    expect(
      (note.toJson(includeScreenshotData: true)['screenshot']! as Map)['data'],
      isA<String>(),
    );
  });

  testWidgets('debug paint flags that were on are named in the note', (
    tester,
  ) async {
    final sink = FakeSink();
    await writeComment(tester, sink);
    debugPaintSizeEnabled = true;
    try {
      await send(tester);
    } finally {
      debugPaintSizeEnabled = false;
    }
    expect(sink.notes.single.screenshot!.debugPaint, ['debugPaintSizeEnabled']);
  });

  testWidgets('a target off screen: the note is sent without the image and '
      'names the screenshot in errors', (tester) async {
    final sink = FakeSink();
    await writeComment(tester, sink);
    shift.value = const Offset(5000, 0);
    await tester.pump();
    await send(tester);

    expect(toast(RegExp('No screenshot')), findsOneWidget);
    expect(toast('Sent to fake'), findsOneWidget);
    final note = sink.notes.single;
    expect(note.screenshot, isNull);
    expect(note.errors, contains('screenshot'));
  });

  testWidgets('the screenshot box stays on screen on every send, also while '
      'sending and with a long comment', (tester) async {
    // The image can show personal data that text masking never sees, so the
    // choice must be in view every time.
    final sink = FakeSink()..gate = Completer<void>();
    await writeComment(tester, sink);
    await tester.enterText(field, List.filled(12, 'line').join('\n'));
    await tester.pump();
    final screen = Offset.zero & tester.view.physicalSize / 3;
    expect(screen.contains(tester.getCenter(box)), isTrue);

    await tester.tap(find.byKey(CommentForm.sendKey));
    for (var i = 0; i < 8 && sink.notes.isEmpty; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(sink.notes, hasLength(1), reason: 'captured, the sink waits');
    expect(controller.mode, PinPointMode.sending);
    expect(screen.contains(tester.getCenter(box)), isTrue);

    sink.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(controller.mode, PinPointMode.idle);
  });

  group('the width cap (build step 4)', () {
    testWidgets('acceptance: a 4K viewport capture stays under 1600 px '
        'wide', (tester) async {
      tester.view.physicalSize = const Size(3840, 2160);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final sink = FakeSink();
      // A full-width bar: 1920 logical px at 2x would be 3840 px.
      await writeComment(tester, sink, targetWidth: double.infinity);
      await send(tester);
      final shot = sink.notes.single.screenshot!;
      expect(shot.crop!.w, 1920);
      expect(shot.width, lessThanOrEqualTo(1600));
      expect(shot.pixelRatio, lessThan(2));
    });

    testWidgets('a crop wider than the cap lowers the ratio', (tester) async {
      tester.view.physicalSize = const Size(3840, 2160);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final sink = FakeSink();
      await writeComment(tester, sink, maxScreenshotWidth: 400);
      await send(tester);
      final shot = sink.notes.single.screenshot!;
      expect(shot.width, lessThanOrEqualTo(400));
      expect(shot.pixelRatio, lessThan(2));
      expect(shot.width, (shot.crop!.w * shot.pixelRatio).round());
    });
  });
}
