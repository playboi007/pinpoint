import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/comment_form.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/overlay/motion/flight_layer.dart';
import 'package:pinpoint/src/overlay/motion/ink_wipe.dart';
import 'package:pinpoint/src/overlay/pin_marker.dart';
import 'package:pinpoint/src/overlay/theme_menu.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/fake_sink.dart';

/// The seldom-used moments of Pinpoint's UI: the paper plane of a send, the
/// ink of a palette switch, the card that flies into its pin, and the copy
/// icon that flips to a check.
///
/// Each one plays next to its action, never before it; each ends; and with
/// reduced motion none of them moves.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(List<PinPointSink> sinks, {bool reduce = false}) => MaterialApp(
    builder: (context, child) {
      // `MaterialApp` makes its own `MediaQuery`: the setting goes inside it.
      final wrapper = PinPointWrapper(
        controller: controller,
        config: PinPointConfig(sinks: sinks),
        child: child,
      );
      return reduce
          ? MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: wrapper,
            )
          : wrapper;
    },
    home: const FixturePage(),
  );

  Future<void> comment(
    WidgetTester tester,
    List<PinPointSink> sinks, {
    bool reduce = false,
  }) async {
    await tester.pumpWidget(host(sinks, reduce: reduce));
    controller.panelPosition = const Offset(300, 20);
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
    // No screenshot: the engine makes it outside the test clock, and it
    // would stand between the tap and the result.
    controller.draft.includeScreenshot = false;
    // The caret of a focused field blinks with an animation of its own, which
    // would show in `hasRunningAnimations`.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    // Let the panel's own opening animations end, so only the moment under
    // test can be running.
    await tester.pump(const Duration(seconds: 1));
  }

  final layer = find.byKey(FlightLayer.layerKey);
  Finder stamp() => find.descendant(of: layer, matching: find.text('Sent'));

  group('Send: paper plane', () {
    testWidgets('the plane flies while the note is already sent, then the '
        '"Sent" stamp rests and goes', (tester) async {
      final sink = FakeSink(name: 'HTTP');
      await comment(tester, [sink]);
      expect(layer, findsNothing);

      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // The send has gone out and ended, and the plane is still in the air.
      expect(sink.notes, hasLength(1));
      expect(controller.mode, PinPointMode.idle);
      expect(layer, findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);
      expect(stamp(), findsNothing, reason: 'not before the plane is gone');

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(stamp(), findsOneWidget);

      // The stamp rests with no frames: nothing runs while it stays.
      await tester.pump(const Duration(milliseconds: 300));
      expect(stamp(), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(layer, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('the plane lasts about 350 ms', (tester) async {
      await comment(tester, [FakeSink(name: 'HTTP')]);
      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 320));
      expect(stamp(), findsNothing, reason: 'still flying at 330 ms');
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      expect(stamp(), findsOneWidget, reason: 'landed by 390 ms');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });

    testWidgets('a failed send drops the plane: no stamp, and it ends', (
      tester,
    ) async {
      final sink = FakeSink(name: 'HTTP', error: Exception('Connection'));
      await comment(tester, [sink]);

      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(sink.notes, hasLength(1));
      expect(controller.mode, PinPointMode.commenting);
      expect(layer, findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);

      // The plane falls from where it was; no "Sent" at any time.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(stamp(), findsNothing);
      }
      await tester.pumpAndSettle();
      expect(layer, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      expect(controller.draft.text.text, 'Too tight');
    });

    testWidgets('a send with no sink drops the plane at once', (tester) async {
      await comment(tester, const []);
      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting);
      expect(layer, findsOneWidget);
      await tester.pumpAndSettle();
      expect(layer, findsNothing);
    });

    testWidgets('with reduced motion no plane flies; the stamp shows at once '
        'and goes', (tester) async {
      final sink = FakeSink(name: 'HTTP');
      await comment(tester, [sink], reduce: true);

      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      expect(sink.notes, hasLength(1));
      expect(controller.mode, PinPointMode.idle);
      await tester.pump();
      expect(stamp(), findsOneWidget);
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason: 'the plane and the stamp make no frames',
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(layer, findsNothing);
    });

    testWidgets('with reduced motion a failed send shows nothing', (
      tester,
    ) async {
      await comment(tester, [
        FakeSink(name: 'HTTP', error: Exception('x')),
      ], reduce: true);
      await tester.tap(find.byKey(CommentForm.sendKey));
      await tester.pump();
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting);
      expect(stamp(), findsNothing);
      // No plane to fall: the ghost is over before it draws anything. (The
      // panel's own caret may still blink, so `hasRunningAnimations` is not
      // asked here.)
      expect(
        find.descendant(of: layer, matching: find.byType(CustomPaint)),
        findsNothing,
      );
      await tester.pump();
      expect(layer, findsNothing);
    });
  });

  group('Save draft: the card flies into its pin', () {
    Finder card() =>
        find.descendant(of: layer, matching: find.byType(CustomPaint));

    testWidgets('the draft and its pin exist at once; the card shrinks onto '
        'the pin and is gone', (tester) async {
      await comment(tester, const []);
      final panel = tester.getRect(find.byKey(InfoPanel.panelKey));

      await tester.tap(find.byKey(CommentForm.draftKey));
      await tester.pump();
      // At once, as before: the draft, its pin and the picking mode.
      expect(controller.notes.drafts, hasLength(1));
      expect(controller.mode, PinPointMode.picking);
      expect(controller.notes.pinned, hasLength(1));
      await tester.pump();
      expect(find.byType(PinMarker), findsOneWidget);
      expect(layer, findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);

      final start = tester.getRect(card().first);
      expect(start.width, closeTo(panel.width, 1));

      await tester.pump(const Duration(milliseconds: 200));
      final middle = tester.getRect(card().first);
      expect(middle.width, lessThan(start.width));
      expect(middle.width, greaterThan(PinMarker.size));

      final pin = tester.getCenter(find.byType(PinMarker));
      await tester.pump(const Duration(milliseconds: 190));
      final end = tester.getRect(card().first);
      expect(end.size.width, closeTo(PinMarker.size, 1));
      expect((end.center - pin).distance, lessThan(2));

      await tester.pumpAndSettle();
      expect(layer, findsNothing);
      expect(find.byType(PinMarker), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('with reduced motion there is no card', (tester) async {
      await comment(tester, const [], reduce: true);
      await tester.tap(find.byKey(CommentForm.draftKey));
      await tester.pump();
      expect(controller.notes.drafts, hasLength(1));
      await tester.pump();
      expect(find.byType(PinMarker), findsOneWidget);
      expect(card(), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pump();
      expect(layer, findsNothing);
    });
  });

  group('Copy as Markdown: the icon flips to a check', () {
    String? copied;
    var fail = false;

    setUp(() {
      copied = null;
      fail = false;
    });

    void mockClipboard(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (fail) throw PlatformException(code: 'denied');
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
    }

    Finder icon(IconData data) => find.descendant(
      of: find.byKey(CommentForm.copyKey),
      matching: find.byIcon(data),
    );

    testWidgets('copies at once, flips for 1.2 s, and flips back', (
      tester,
    ) async {
      mockClipboard(tester);
      await comment(tester, const []);
      expect(icon(PinPointIcons.contentCopy), findsOneWidget);

      await tester.tap(find.byKey(CommentForm.copyKey));
      await tester.pump();
      await tester.pump();
      // The text is on the clipboard before the flip is over.
      expect(copied, contains('Comment: Too tight'));
      expect(tester.hasRunningAnimations, isTrue);
      expect(controller.draft.text.text, 'Too tight');

      await tester.pump(const Duration(milliseconds: 40));
      // Half way: the icon is turning (a transform above the button).
      expect(
        find.ancestor(
          of: find.byKey(CommentForm.copyKey),
          matching: find.byType(Transform),
        ),
        findsWidgets,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(icon(PinPointIcons.check), findsOneWidget);
      expect(icon(PinPointIcons.contentCopy), findsNothing);
      // At rest: no frames while the check stays.
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pump(const Duration(milliseconds: 1000));
      expect(icon(PinPointIcons.check), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(icon(PinPointIcons.contentCopy), findsOneWidget);
      expect(icon(PinPointIcons.check), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a copy that fails shows no check', (tester) async {
      mockClipboard(tester);
      fail = true;
      await comment(tester, const []);
      await tester.tap(find.byKey(CommentForm.copyKey));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(icon(PinPointIcons.check), findsNothing);
      expect(icon(PinPointIcons.contentCopy), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('with reduced motion the icon changes at once and back at '
        'once', (tester) async {
      mockClipboard(tester);
      await comment(tester, const [], reduce: true);
      await tester.tap(find.byKey(CommentForm.copyKey));
      await tester.pump();
      await tester.pump();
      expect(copied, isNotNull);
      expect(icon(PinPointIcons.check), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pump(const Duration(milliseconds: 1250));
      expect(icon(PinPointIcons.contentCopy), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a footer built alone flips on the press', (tester) async {
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Theme(
            data: ThemeData(extensions: [PinPointTokens.redline]),
            child: Scaffold(
              body: CommentFooter(
                controller: controller,
                onSend: () {},
                onCopy: () => presses++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(CommentForm.copyKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(presses, 1);
      expect(icon(PinPointIcons.check), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1250));
      await tester.pumpAndSettle();
      expect(icon(PinPointIcons.contentCopy), findsOneWidget);
    });
  });

  group('Palette switch: ink wipe', () {
    Future<void> pumpHost(WidgetTester tester, {bool reduce = false}) async {
      tester.view.physicalSize = const Size(1200, 900) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            final wrapper = PinPointWrapper(
              controller: controller,
              child: child,
            );
            return reduce
                ? MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(disableAnimations: true),
                    child: wrapper,
                  )
                : wrapper;
          },
          home: const Scaffold(body: Center(child: Text('app'))),
        ),
      );
    }

    Future<void> pick(WidgetTester tester, PinPointPalette palette) async {
      await tester.tap(find.byKey(ThemeMenu.buttonKey));
      await tester.pump();
      await tester.tap(find.byKey(ThemeMenu.rowKey(palette)));
      await tester.pump();
    }

    final wipe = find.byKey(PaletteInk.wipeKey);

    testWidgets('the palette changes at once; the ink spreads for 420 ms and '
        'goes', (tester) async {
      await pumpHost(tester);
      await pick(tester, PinPointPalette.cobalt);
      // At once: saved, applied and the menu closed.
      expect(controller.palette.value, PinPointPalette.cobalt);
      expect(find.byKey(ThemeMenu.menuKey), findsNothing);
      expect(wipe, findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pump(const Duration(milliseconds: 200));
      expect(wipe, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(wipe, findsOneWidget, reason: 'still 20 ms to go');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
      expect(wipe, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('only Pinpoint is wiped: the host app is not under it', (
      tester,
    ) async {
      await pumpHost(tester);
      await pick(tester, PinPointPalette.ember);
      expect(wipe, findsOneWidget);
      expect(find.ancestor(of: find.text('app'), matching: wipe), findsNothing);
      // The picture is laid over Pinpoint's own subtree, under its theme.
      expect(
        find.descendant(of: find.byType(InspectorOverlay), matching: wipe),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('picking the palette that is on does not wipe', (tester) async {
      await pumpHost(tester);
      await pick(tester, PinPointPalette.redline);
      expect(wipe, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('with reduced motion the palette just changes', (tester) async {
      await pumpHost(tester, reduce: true);
      await pick(tester, PinPointPalette.cobalt);
      expect(controller.palette.value, PinPointPalette.cobalt);
      expect(wipe, findsNothing);
      // Whatever else the menu does to close, it is over in a moment.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
