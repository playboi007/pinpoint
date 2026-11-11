import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/widget_info.dart';
import 'package:pinpoint/src/overlay/highlight_painter.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/overlay/pick_tracker.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// Milestone 2, build step 2: picking through the wrapper, the highlight,
/// hover coalescing and the outline that follows its widget.
void main() {
  /// A selection opens the comment field (Milestone 5). Its focus
  /// animation draws frames for about 170 ms, and its caret blinks twice a
  /// second while it has focus. Both are the field's own; wait for the one
  /// and stop the other, so the frame checks below see only Pinpoint's.
  Future<void> settleCommentField(WidgetTester tester) async {
    EditableText.debugDeterministicCursor = true;
    addTearDown(() => EditableText.debugDeterministicCursor = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(Widget home) => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: home,
  );

  Future<void> startPicking(WidgetTester tester) async {
    controller.startPicking();
    await tester.pump();
  }

  Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: at);
    return mouse;
  }

  RenderObject highlight(WidgetTester tester) =>
      tester.renderObject(find.byKey(InspectorOverlay.highlightKey));

  /// The tokens the overlay paints with until the wrapper passes its own.
  const tokens = PinPointTokens.redline;

  /// Matches a `drawPath` of [bounds]: the halo under a hover outline runs
  /// along the whole edge, half a pixel inside the widget's rect.
  bool Function(Symbol, List<dynamic>) pathOf(Rect bounds) =>
      (method, args) =>
          method == #drawPath &&
          ((args[0] as Path).getBounds().left - bounds.left).abs() < 0.01 &&
          ((args[0] as Path).getBounds().top - bounds.top).abs() < 0.01 &&
          ((args[0] as Path).getBounds().right - bounds.right).abs() < 0.01 &&
          ((args[0] as Path).getBounds().bottom - bounds.bottom).abs() < 0.01;

  /// Matches the label pill: the one `drawRect` filled with `paper`.
  bool Function(Symbol, List<dynamic>) pill(void Function(Rect) check) =>
      (method, args) {
        if (method != #drawRect) return false;
        final paint = args[1] as Paint;
        if (paint.style != PaintingStyle.fill || paint.color != tokens.paper) {
          return false;
        }
        check(args[0] as Rect);
        return true;
      };

  const page = Scaffold(body: Center(child: Text('target')));

  // The info panel shows the text too, so look for the app's copy only.
  final target = find.descendant(
    of: find.byType(Scaffold),
    matching: find.text('target'),
  );

  group('acceptance', () {
    testWidgets('hovering a Text outlines exactly the text bounds', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final textRect = tester.getRect(target);

      final mouse = await mouseAt(tester, Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(textRect.center);
      await tester.pump();

      final hovered = controller.hovered.value!;
      expect(hovered.renderObject, isA<RenderParagraph>());
      expect(hovered.globalRect, textRect);
      // A paper halo, then the dashed ink line, both on the text rect: no
      // fill.
      expect(
        highlight(tester),
        paints
          ..something(pathOf(textRect.deflate(0.5)))
          ..path(color: tokens.ink, strokeWidth: 1),
      );
      expect(highlight(tester), isNot(paints..rect()));
    });

    testWidgets('the outline follows the widget on window resize', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      await tester.tapAt(tester.getCenter(target));
      await settleCommentField(tester);
      final before = controller.selection.value!.globalRect;

      tester.view.physicalSize = tester.view.physicalSize * 0.5;
      await tester.pump(); // the app lays out; the rect is read after it
      await tester.pump(); // the highlight repaints

      final after = tester.getRect(target);
      expect(after, isNot(before));
      expect(controller.selection.value!.globalRect, after);
      expect(
        highlight(tester),
        paints
          ..rect(rect: after.inflate(1.5))
          ..rect(rect: after.inflate(0.5))
          ..rect(rect: after.deflate(1)),
      );
      // On a metrics change the focused comment field scrolls its caret
      // into view, animated over 100 ms. After that, nothing draws.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the outline clears when the widget unmounts', (tester) async {
      final show = ValueNotifier<bool>(true);
      addTearDown(show.dispose);
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: show,
                builder: (context, visible, _) =>
                    visible ? const Text('target') : const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await startPicking(tester);
      await tester.tapAt(tester.getCenter(target));
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting);

      show.value = false;
      await tester.pump();
      await tester.pump();

      expect(controller.selection.value, isNull);
      expect(controller.mode, PinPointMode.picking);
      expect(highlight(tester), isNot(paints..rect()));
    });
  });

  group('selecting', () {
    testWidgets('a click selects and yields the element', (tester) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);

      await tester.tapAt(tester.getCenter(target));
      await tester.pump();

      final selection = controller.selection.value!;
      expect(controller.mode, PinPointMode.commenting);
      // The Text written in this test, not the RichText it builds.
      expect(selection.element.widget, isA<Text>());
      expect(selection.pickedElement.widget, isA<RichText>());
      expect(selection.element.mounted, isTrue);
      expect(
        highlight(tester),
        paints
          ..rect(rect: selection.globalRect.inflate(1.5), color: tokens.ink)
          ..rect(rect: selection.globalRect.inflate(0.5), color: tokens.paper)
          ..rect(
            rect: selection.globalRect.deflate(1),
            color: tokens.accent,
            strokeWidth: 2,
          ),
      );
    });

    testWidgets('the same spot again selects the next candidate', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final at = tester.getCenter(target);

      await tester.tapAt(at);
      await tester.pump();
      final first = controller.selection.value!;
      await tester.tapAt(at);
      await tester.pump();
      final second = controller.selection.value!;

      expect(controller.mode, PinPointMode.commenting);
      expect(first.index, 0);
      expect(second.index, 1);
      expect(second.renderObject, same(first.candidates[1].renderObject));
    });

    testWidgets('the highlight sits outside the app boundary', (tester) async {
      await tester.pumpWidget(host(page));
      final appBoundary = find
          .descendant(
            of: find.byType(PinPointWrapper),
            matching: find.byType(RepaintBoundary),
          )
          .first;
      expect(
        find.descendant(
          of: appBoundary,
          matching: find.byKey(InspectorOverlay.highlightKey),
        ),
        findsNothing,
      );
    });
  });

  group('hover', () {
    testWidgets('moves between frames cost one pick', (tester) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final mouse = await mouseAt(tester, const Offset(10, 10));
      addTearDown(mouse.removePointer);
      await tester.pump();

      PickTracker.debugPickCount = 0;
      for (var i = 0; i < 5; i++) {
        await mouse.moveTo(Offset(20.0 + i, 30));
      }
      expect(PickTracker.debugPickCount, 0, reason: 'nothing before the frame');
      await tester.pump();
      expect(PickTracker.debugPickCount, 1);
      expect(controller.hovered.value!.position, const Offset(24, 30));
    });

    testWidgets('hover and selection force no frames once settled', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final textCenter = tester.getCenter(target);
      await tester.tapAt(textCenter);
      await settleCommentField(tester);
      final mouse = await mouseAt(tester, textCenter);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      await tester.pump();
      // A mouse that connects starts a short Material animation in the
      // panel (about 150 ms). It ends by itself; Pinpoint's per-frame work
      // must not keep frames coming after it.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(controller.hovered.value, isNotNull);
      expect(controller.selection.value, isNotNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the outline clears when the pointer leaves', (tester) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final mouse = await mouseAt(tester, Offset.zero);
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();
      expect(controller.hovered.value, isNotNull);

      await mouse.removePointer();
      await tester.pump();
      expect(controller.hovered.value, isNull);
      expect(highlight(tester), isNot(paints..path()));
    });

    testWidgets('hovering the selected widget draws one outline', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final at = tester.getCenter(target);
      await tester.tapAt(at);
      final mouse = await mouseAt(tester, at);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(at + const Offset(1, 0));
      await tester.pump();

      expect(highlight(tester), isNot(paints..path()));
    });
  });

  group('the selected label pill', () {
    /// Selects the text and returns its rect and the pill's rect, as the
    /// painter draws it.
    Future<(Rect, Rect)> selectedPill(WidgetTester tester, Widget page) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      await tester.tapAt(tester.getCenter(target));
      await tester.pump();
      final textRect = tester.getRect(target);
      Rect? drawn;
      expect(
        highlight(tester),
        paints..something(pill((rect) => drawn = rect)),
      );
      return (textRect, drawn!);
    }

    testWidgets('sits 3 px below the selection, 18 px high', (tester) async {
      final (text, drawn) = await selectedPill(tester, page);
      expect(drawn.top, text.bottom + 3);
      expect(drawn.height, 18);
      expect(drawn.left, text.left);
    });

    testWidgets('goes above when there is no room below', (tester) async {
      final (text, drawn) = await selectedPill(
        tester,
        const Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: Text('target')),
        ),
      );
      expect(drawn.bottom, text.top - 3);
      expect(drawn.height, 18);
    });

    testWidgets('is clamped to the viewport', (tester) async {
      final (text, drawn) = await selectedPill(
        tester,
        const Scaffold(
          body: Align(alignment: Alignment.centerRight, child: Text('target')),
        ),
      );
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(text.right, screen.width);
      expect(drawn.right, screen.width);
      expect(drawn.left, greaterThanOrEqualTo(0));
    });

    testWidgets('names the widget, its size and its file and line', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      await tester.tapAt(tester.getCenter(target));
      await tester.pump();
      final pick = controller.selection.value!;
      final size = tester.getSize(target);

      expect(pillName(pick), 'Text');
      // Whole numbers without a decimal, others with one.
      expect(pillSize(pick), '${formatNumber(size.width)} × 20');
      // File name and line only, never the directory.
      expect(pillLocation(pick), matches(RegExp(r'^[^/]+\.dart:\d+$')));
    });
  });

  group('labelRect', () {
    const canvas = Size(400, 300);
    const label = Size(80, 18);

    test('goes below the target when there is room', () {
      final rect = labelRect(
        const Rect.fromLTWH(50, 100, 40, 40),
        label,
        canvas,
      );
      expect(rect, const Rect.fromLTWH(50, 143, 80, 18));
    });

    test('goes above when there is no room below', () {
      final rect = labelRect(
        const Rect.fromLTWH(50, 250, 40, 40),
        label,
        canvas,
      );
      expect(rect.bottom, 247);
    });

    test('goes inside when there is no room above or below', () {
      final rect = labelRect(
        const Rect.fromLTWH(0, 0, 400, 300),
        label,
        canvas,
      );
      expect(rect.bottom, 297);
    });

    test('starts at the left edge when it is wider than the canvas', () {
      final rect = labelRect(
        const Rect.fromLTWH(30, 100, 20, 20),
        const Size(500, 18),
        canvas,
      );
      expect(rect.left, 0);
    });

    test('stays inside the canvas horizontally', () {
      final rect = labelRect(
        const Rect.fromLTWH(380, 100, 20, 20),
        label,
        canvas,
      );
      expect(rect.right, canvas.width);
    });
  });
}
