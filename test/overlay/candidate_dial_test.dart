import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/candidate_dial.dart';
import 'package:pinpoint/src/theme/pinpoint_theme.dart';

/// The candidate dial in the info panel's header: ticks for the widgets under
/// one spot, turned by drag, wheel, click or a screen reader.
void main() {
  // The index the parent holds, and every index the dial asked for.
  late ValueNotifier<int> index;
  late List<int> asked;
  late bool accept;

  setUp(() {
    index = ValueNotifier<int>(0);
    asked = <int>[];
    accept = true;
  });
  tearDown(() => index.dispose());

  Widget host({
    required int count,
    bool reduced = false,
    PinPointPalette palette = PinPointPalette.redline,
  }) => MaterialApp(
    theme: pinPointThemeData(palette),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: index,
            builder: (context, value, _) => CandidateDial(
              count: count,
              index: value,
              describeNeighbours: () => '↑ Outer  ↓ Inner',
              onSelect: (next) {
                asked.add(next);
                if (!accept) return false;
                index.value = next;
                return true;
              },
            ),
          ),
        ),
      ),
    ),
  );

  final dial = find.byType(CandidateDial);

  Future<void> pumpHost(
    WidgetTester tester, {
    required int count,
    int start = 0,
    bool reduced = false,
  }) async {
    index.value = start;
    await tester.pumpWidget(host(count: count, reduced: reduced));
  }

  group('ticks', () {
    test('only real candidates get a tick', () {
      // At most four on each side of the middle one.
      expect(CandidateDial.visibleTicks(139, 66), [
        for (var i = 62; i <= 70; i++) i,
      ]);
      // The first and the last show nothing past them.
      expect(CandidateDial.visibleTicks(139, 0), [0, 1, 2, 3, 4]);
      expect(CandidateDial.visibleTicks(139, 138), [134, 135, 136, 137, 138]);
      expect(CandidateDial.visibleTicks(3, 1), [0, 1, 2]);
      expect(CandidateDial.visibleTicks(1, 0), [0]);
    });

    testWidgets('are drawn under every palette', (tester) async {
      for (final palette in PinPointPalette.values) {
        await tester.pumpWidget(host(count: 9, palette: palette));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$palette');
        expect(
          find.descendant(of: dial, matching: find.byType(CustomPaint)),
          findsOneWidget,
        );
      }
    });

    testWidgets('fit the header: 24 by 34', (tester) async {
      await pumpHost(tester, count: 5);
      expect(tester.getSize(dial), const Size(24, 34));
    });
  });

  group('input', () {
    testWidgets('a click on the upper half goes outer, the lower inner', (
      tester,
    ) async {
      await pumpHost(tester, count: 5, start: 2);
      final box = tester.getRect(dial);
      await tester.tapAt(box.topCenter + const Offset(0, 6));
      await tester.pumpAndSettle();
      expect(index.value, 3);

      await tester.tapAt(box.bottomCenter - const Offset(0, 6));
      await tester.pumpAndSettle();
      expect(index.value, 2);
      await tester.tapAt(box.bottomCenter - const Offset(0, 6));
      await tester.pumpAndSettle();
      expect(index.value, 1);
    });

    testWidgets('there is no wrap past the ends', (tester) async {
      await pumpHost(tester, count: 3, start: 0);
      final box = tester.getRect(dial);
      await tester.tapAt(box.bottomCenter - const Offset(0, 6));
      await tester.pumpAndSettle();
      expect(index.value, 0);
      expect(asked, isEmpty);

      index.value = 2;
      await tester.pump();
      await tester.tapAt(box.topCenter + const Offset(0, 6));
      await tester.pumpAndSettle();
      expect(index.value, 2);
      expect(asked, isEmpty);
    });

    // A mouse drag counts from the first pixel; a finger must pass the touch
    // slop (18 px) first, so a small touch movement is a tap.
    Future<void> mouseDrag(WidgetTester tester, double dy) async {
      final gesture = await tester.startGesture(
        tester.getCenter(dial),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(Offset(0, dy));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('a drag turns the drum with the finger: one detent per '
        'spacing', (tester) async {
      await pumpHost(tester, count: 9, start: 4);
      // Up: the drum turns up and the widget below comes to the middle.
      await mouseDrag(tester, -CandidateDial.dragSpacing);
      expect(asked, [3]);
      expect(index.value, 3);

      // Down: the outer widget comes down to the middle, two detents.
      await mouseDrag(tester, CandidateDial.dragSpacing * 2);
      expect(index.value, 5);
    });

    testWidgets('a touch drag works once it passes the slop', (tester) async {
      await pumpHost(tester, count: 9, start: 6);
      await tester.drag(dial, const Offset(0, -24));
      await tester.pumpAndSettle();
      expect(index.value, 2);
    });

    testWidgets('a drag follows the finger: each detent selects', (
      tester,
    ) async {
      await pumpHost(tester, count: 9, start: 4);
      final gesture = await tester.startGesture(
        tester.getCenter(dial),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, -CandidateDial.dragSpacing));
      await gesture.moveBy(const Offset(0, -CandidateDial.dragSpacing));
      expect(asked, [3, 2]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(index.value, 2);
    });

    testWidgets('a drag stops at the ends', (tester) async {
      await pumpHost(tester, count: 4, start: 3);
      await mouseDrag(tester, CandidateDial.dragSpacing * 6);
      expect(index.value, 3);
      expect(asked, isEmpty);

      // A detent and a bit more rounds to one detent.
      await mouseDrag(tester, -CandidateDial.dragSpacing * 1.3);
      expect(index.value, 2);
    });

    testWidgets('a drag does not move the panel behind it', (tester) async {
      var panned = Offset.zero;
      index.value = 2;
      await tester.pumpWidget(
        MaterialApp(
          theme: pinPointThemeData(PinPointPalette.redline),
          home: Scaffold(
            body: GestureDetector(
              onPanUpdate: (d) => panned += d.delta,
              child: Center(
                child: CandidateDial(count: 5, index: 2, onSelect: (_) => true),
              ),
            ),
          ),
        ),
      );
      await tester.drag(dial, const Offset(0, -24));
      await tester.pumpAndSettle();
      expect(panned, Offset.zero);
    });

    testWidgets('the wheel steps one candidate per notch', (tester) async {
      await pumpHost(tester, count: 9, start: 4);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(tester.getCenter(dial)));
      // Down moves like a drag up: to the inner widget.
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
      await tester.pumpAndSettle();
      expect(index.value, 3);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
      await tester.pumpAndSettle();
      expect(index.value, 4);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
      await tester.pumpAndSettle();
      expect(index.value, 5);
      // A trackpad's small deltas add up to a step.
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 10)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 10)));
      expect(index.value, 5);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 10)));
      await tester.pumpAndSettle();
      expect(index.value, 4);
    });

    testWidgets('a refused step rolls back', (tester) async {
      await pumpHost(tester, count: 5, start: 2);
      accept = false;
      await tester.tapAt(tester.getRect(dial).topCenter + const Offset(0, 6));
      await tester.pumpAndSettle();
      expect(asked, [3]);
      expect(index.value, 2);
    });

    testWidgets('one candidate: nothing to turn', (tester) async {
      await pumpHost(tester, count: 1);
      await tester.tapAt(tester.getRect(dial).topCenter + const Offset(0, 6));
      await tester.drag(dial, const Offset(0, -20));
      await tester.pumpAndSettle();
      expect(asked, isEmpty);
    });

    testWidgets('the cursor over the dial is resizeUpDown', (tester) async {
      await pumpHost(tester, count: 5, start: 2);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(dial));
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.resizeUpDown,
      );
    });

    testWidgets('the tooltip names the outer and inner widgets', (
      tester,
    ) async {
      await pumpHost(tester, count: 5, start: 2);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(dial));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('↑ Outer  ↓ Inner'), findsOneWidget);
    });
  });

  group('motion', () {
    testWidgets('a step rolls the ticks, then everything is still', (
      tester,
    ) async {
      await pumpHost(tester, count: 9, start: 4);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.tapAt(tester.getRect(dial).topCenter + const Offset(0, 6));
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    });

    testWidgets('it takes the quick duration, 150 ms', (tester) async {
      await pumpHost(tester, count: 9, start: 4);
      await tester.tapAt(tester.getRect(dial).topCenter + const Offset(0, 6));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('with reduced motion the ticks jump', (tester) async {
      await pumpHost(tester, count: 9, start: 4, reduced: true);
      await tester.tapAt(tester.getRect(dial).topCenter + const Offset(0, 6));
      await tester.pump();
      expect(index.value, 5);
      expect(tester.hasRunningAnimations, isFalse);
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    });

    testWidgets('idle: no frame is scheduled', (tester) async {
      await pumpHost(tester, count: 9, start: 4);
      await tester.pumpAndSettle();
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
      // A change from elsewhere (a new pick) jumps: no animation.
      index.value = 7;
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    });
  });

  group('semantics', () {
    testWidgets('a slider with "N of M" and increase and decrease', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpHost(tester, count: 139, start: 65);
      final paint = find.descendant(
        of: dial,
        matching: find.byType(CustomPaint),
      );
      final node = tester.getSemantics(paint);
      final data = node.getSemanticsData();
      expect(data.value, '66 of 139');
      expect(data.increasedValue, '67 of 139');
      expect(data.decreasedValue, '65 of 139');
      expect(data.flagsCollection.isSlider, isTrue);
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);

      // Increase goes outer: the number grows.
      tester.semantics.increase(
        find.semantics.byAction(SemanticsAction.increase),
      );
      await tester.pumpAndSettle();
      expect(index.value, 66);
      tester.semantics.decrease(
        find.semantics.byAction(SemanticsAction.decrease),
      );
      await tester.pumpAndSettle();
      expect(index.value, 65);
      handle.dispose();
    });

    testWidgets('no action past the ends; the dial is its own node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpHost(tester, count: 3, start: 0);
      final finder = find.descendant(
        of: dial,
        matching: find.byType(CustomPaint),
      );
      var data = tester.getSemantics(finder).getSemanticsData();
      expect(data.hasAction(SemanticsAction.decrease), isFalse);
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      index.value = 2;
      await tester.pump();
      data = tester.getSemantics(finder).getSemanticsData();
      expect(data.hasAction(SemanticsAction.increase), isFalse);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      handle.dispose();
    });
  });
}
