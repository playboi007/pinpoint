import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/overlay/ruler_painter.dart';

/// Milestone 2, build step 3: rulers to the ancestor, and gaps with Alt.
void main() {
  double distance(List<RulerSegment> segments, RulerSide side) =>
      segments.firstWhere((s) => s.side == side).distance;

  group('ancestorRulers', () {
    const outer = Rect.fromLTWH(0, 0, 200, 100);

    test('labels add up to the ancestor size', () {
      const inner = Rect.fromLTWH(13, 7, 150, 40);
      final rulers = ancestorRulers(inner, outer);
      expect(rulers, hasLength(4));
      expect(
        distance(rulers, RulerSide.left) +
            inner.width +
            distance(rulers, RulerSide.right),
        outer.width,
      );
      expect(
        distance(rulers, RulerSide.top) +
            inner.height +
            distance(rulers, RulerSide.bottom),
        outer.height,
      );
      expect(distance(rulers, RulerSide.left), 13);
      expect(distance(rulers, RulerSide.bottom), 53);
    });

    test('an overflowing child gets a negative gap that still adds up', () {
      const inner = Rect.fromLTWH(180, 10, 40, 20);
      final rulers = ancestorRulers(inner, outer);
      expect(distance(rulers, RulerSide.right), -20);
      expect(
        distance(rulers, RulerSide.left) +
            inner.width +
            distance(rulers, RulerSide.right),
        outer.width,
      );
    });

    test('segments run from the ancestor edge to the child edge', () {
      const inner = Rect.fromLTWH(20, 30, 100, 40);
      final left = ancestorRulers(
        inner,
        outer,
      ).firstWhere((s) => s.side == RulerSide.left);
      expect(left.start, Offset(0, inner.center.dy));
      expect(left.end, Offset(20, inner.center.dy));
    });
  });

  group('gapRulers', () {
    const a = Rect.fromLTWH(0, 0, 50, 50);

    test('side by side: one horizontal gap', () {
      const b = Rect.fromLTWH(80, 10, 50, 50);
      final rulers = gapRulers(a, b);
      expect(rulers, hasLength(1));
      expect(rulers.single.distance, 30);
      expect(rulers.single.start.dx, 50);
      expect(rulers.single.end.dx, 80);
      expect(rulers.single.start.dy, 30, reason: 'middle of the overlap');
    });

    test('one above the other: one vertical gap', () {
      const b = Rect.fromLTWH(0, 70, 50, 50);
      final rulers = gapRulers(b, a);
      expect(rulers.single.distance, 20);
      expect(rulers.single.side, RulerSide.top);
    });

    test('diagonal: both gaps', () {
      const b = Rect.fromLTWH(60, 75, 10, 10);
      final rulers = gapRulers(a, b);
      expect(rulers.map((r) => r.distance), unorderedEquals([10, 25]));
    });

    test('one inside the other: four edges', () {
      const b = Rect.fromLTWH(10, 10, 20, 20);
      expect(gapRulers(a, b), hasLength(4));
      expect(gapRulers(b, a), hasLength(4));
    });
  });

  group('in the overlay', () {
    late PinPointController controller;
    setUp(() => controller = PinPointController());
    tearDown(() => controller.dispose());

    const inner = Key('inner');
    const other = Key('other');
    Widget host() => MaterialApp(
      builder: (context, child) =>
          PinPointWrapper(controller: controller, child: child),
      home: const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.fromLTRB(13, 7, 29, 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(key: inner, width: 60, height: 30),
                SizedBox(width: 40),
                SizedBox(key: other, width: 20, height: 30),
              ],
            ),
          ),
        ),
      ),
    );

    RenderObject rulerLayer(WidgetTester tester) =>
        tester.renderObject(find.byKey(InspectorOverlay.rulerKey));

    testWidgets('a selection measures to its nearest differing ancestor', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byKey(inner)));
      await tester.pump();

      final selection = controller.selection.value!;
      final rowRect = tester.getRect(find.byType(Row).first);
      expect(selection.globalRect, tester.getRect(find.byKey(inner)));
      expect(selection.ancestorRect, rowRect);
      final rulers = ancestorRulers(
        selection.globalRect,
        selection.ancestorRect!,
      );
      expect(distance(rulers, RulerSide.right), 60);
      expect(rulerLayer(tester), paints..line());
    });

    testWidgets('Alt with a second widget hovered measures the gap', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byKey(inner)));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.byKey(other)));
      await mouse.moveTo(tester.getCenter(find.byKey(other)));
      await tester.pump();
      expect(controller.measuring.value, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.measuring.value, isTrue);
      final gap =
          tester.getRect(find.byKey(other)).left -
          tester.getRect(find.byKey(inner)).right;
      expect(gap, 40);
      // One gap: the first dash starts at the selection's right edge.
      final innerRect = tester.getRect(find.byKey(inner));
      expect(
        rulerLayer(tester),
        paints..line(p1: Offset(innerRect.right, innerRect.center.dy)),
      );

      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.measuring.value, isFalse);
    });

    testWidgets('no rulers without a selection', (tester) async {
      await tester.pumpWidget(host());
      controller.startPicking();
      await tester.pump();
      expect(rulerLayer(tester), isNot(paints..line()));
    });
  });
}
