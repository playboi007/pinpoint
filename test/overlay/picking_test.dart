import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/highlight_painter.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/overlay/pick_tracker.dart';

/// Milestone 2, build step 2: picking through the wrapper, the highlight,
/// hover coalescing and the outline that follows its widget.
void main() {
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

  const page = Scaffold(body: Center(child: Text('target')));

  group('acceptance', () {
    testWidgets('hovering a Text outlines exactly the text bounds', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final textRect = tester.getRect(find.text('target'));

      final mouse = await mouseAt(tester, Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(textRect.center);
      await tester.pump();

      final hovered = controller.hovered.value!;
      expect(hovered.renderObject, isA<RenderParagraph>());
      expect(hovered.globalRect, textRect);
      // Fill, then border, both exactly on the text rect.
      expect(
        highlight(tester),
        paints
          ..rect(
            rect: textRect,
            color: HighlightColors.hover.withValues(alpha: 0.12),
          )
          ..rect(
            rect: textRect,
            color: HighlightColors.hover,
            strokeWidth: 1.5,
          ),
      );
    });

    testWidgets('the outline follows the widget on window resize', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      await tester.tapAt(tester.getCenter(find.text('target')));
      await tester.pump();
      final before = controller.selection.value!.globalRect;

      tester.view.physicalSize = tester.view.physicalSize * 0.5;
      await tester.pump(); // the app lays out; the rect is read after it
      await tester.pump(); // the highlight repaints

      final after = tester.getRect(find.text('target'));
      expect(after, isNot(before));
      expect(controller.selection.value!.globalRect, after);
      expect(highlight(tester), paints..rect(rect: after));
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
      await tester.tapAt(tester.getCenter(find.text('target')));
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

      await tester.tapAt(tester.getCenter(find.text('target')));
      await tester.pump();

      final selection = controller.selection.value!;
      expect(controller.mode, PinPointMode.commenting);
      expect(selection.element.widget, isA<RichText>());
      expect(selection.element.mounted, isTrue);
      expect(
        highlight(tester),
        paints
          ..rect(rect: selection.globalRect)
          ..rect(rect: selection.globalRect, color: HighlightColors.selected),
      );
    });

    testWidgets('the same spot again selects the next candidate', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final at = tester.getCenter(find.text('target'));

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
      final textCenter = tester.getCenter(find.text('target'));
      await tester.tapAt(textCenter);
      final mouse = await mouseAt(tester, textCenter);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      await tester.pump();

      expect(controller.hovered.value, isNotNull);
      expect(controller.selection.value, isNotNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the outline clears when the pointer leaves', (tester) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final mouse = await mouseAt(tester, Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('target')));
      await tester.pump();
      expect(controller.hovered.value, isNotNull);

      await mouse.removePointer();
      await tester.pump();
      expect(controller.hovered.value, isNull);
      expect(highlight(tester), isNot(paints..rect()));
    });

    testWidgets('hovering the selected widget draws one outline', (
      tester,
    ) async {
      await tester.pumpWidget(host(page));
      await startPicking(tester);
      final at = tester.getCenter(find.text('target'));
      await tester.tapAt(at);
      final mouse = await mouseAt(tester, at);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(at + const Offset(1, 0));
      await tester.pump();

      expect(
        highlight(tester),
        isNot(paints..rect(color: HighlightColors.hover)),
      );
    });
  });

  group('labelRect', () {
    const canvas = Size(400, 300);
    const label = Size(80, 16);

    test('goes above the target when there is room', () {
      final rect = labelRect(
        const Rect.fromLTWH(50, 100, 40, 40),
        label,
        canvas,
      );
      expect(rect, const Rect.fromLTWH(50, 80, 80, 16));
    });

    test('goes below when there is no room above', () {
      final rect = labelRect(const Rect.fromLTWH(50, 5, 40, 40), label, canvas);
      expect(rect.top, 49);
    });

    test('goes inside when there is no room above or below', () {
      final rect = labelRect(
        const Rect.fromLTWH(0, 0, 400, 300),
        label,
        canvas,
      );
      expect(rect.top, 4);
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
