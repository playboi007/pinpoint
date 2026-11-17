import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/overlay/motion/pin_motion.dart';
import 'package:pinpoint/src/overlay/pin_marker.dart';
import 'package:pinpoint/src/overlay/pin_tracker.dart';
import 'package:pinpoint/src/theme/pinpoint_motion.dart';

/// The seldom-used moments of a pin: fixed (hop and tick), a verify result
/// (stamp) and Accept (fold).
void main() {
  Widget host(Widget child, {bool reduced = false}) => MaterialApp(
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: app!,
    ),
    home: Scaffold(body: Center(child: child)),
  );

  Widget pin(NoteStatus status, {bool? checks}) =>
      PinMarker(number: 3, status: status, checksPassed: checks, onTap: () {});

  Finder ticks() => find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is TickPainter,
  );

  Finder dust() => find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is DustRingPainter,
  );

  double bodyTop(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(PinMarker.bodyKey)).dy;

  group('the values', () {
    test('the hop starts and ends at rest and goes up in between', () {
      expect(PinMoments.hop(0), 0);
      expect(PinMoments.hop(1), 0);
      expect(PinMoments.hop(0.35), -PinMoments.hopHeight);
      expect(PinMoments.hop(0.2), lessThan(0));
    });

    test('the stamp starts large and turned, and lands at 1 and 0', () {
      expect(PinMoments.stampSize(0), PinMoments.stampScale);
      expect(PinMoments.stampAngle(0), PinMoments.stampTurn);
      expect(PinMoments.stampSize(1), moreOrLessEquals(1));
      expect(PinMoments.stampAngle(1), moreOrLessEquals(0));
      // A small bounce: it goes below its size before it settles.
      expect(
        [
          for (var t = 0.0; t <= 1; t += 0.05) PinMoments.stampSize(t),
        ].any((size) => size < 1),
        isTrue,
      );
    });
  });

  group('agent fixed a note', () {
    testWidgets('hops and draws its tick when the status becomes fixed', (
      tester,
    ) async {
      await tester.pumpWidget(host(pin(NoteStatus.inProgress)));
      final rest = bodyTop(tester);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(host(pin(NoteStatus.fixed)));
      // The new status shows at once.
      expect(find.byKey(PinMarker.badgeKey), findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 60));
      expect(bodyTop(tester), lessThan(rest), reason: 'the pin hops up');
      await tester.pump(const Duration(milliseconds: 100));
      expect(ticks(), findsOneWidget, reason: 'the tick is being drawn');

      await tester.pumpAndSettle();
      expect(bodyTop(tester), rest);
      expect(ticks(), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(PinMarker.badgeKey),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
    });

    testWidgets('lasts the expressive time', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.inProgress)));
      await tester.pumpWidget(host(pin(NoteStatus.fixed)));
      await tester.pump();
      await tester.pump(
        PinPointMotion.expressiveBase - const Duration(milliseconds: 20),
      );
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a pin built fixed does not play', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.fixed)));
      expect(tester.hasRunningAnimations, isFalse);
      expect(ticks(), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('another change of status does not play it', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.submitted)));
      await tester.pumpWidget(host(pin(NoteStatus.inProgress)));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(host(pin(NoteStatus.resolved)));
      // The fade to 40% runs; the hop does not.
      await tester.pump(const Duration(milliseconds: 60));
      expect(ticks(), findsNothing);
    });

    testWidgets('it can play again after the note was reopened', (
      tester,
    ) async {
      await tester.pumpWidget(host(pin(NoteStatus.inProgress)));
      await tester.pumpWidget(host(pin(NoteStatus.fixed)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(pin(NoteStatus.submitted)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(pin(NoteStatus.fixed)));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('reduced motion: the end state at once', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.inProgress), reduced: true));
      final rest = bodyTop(tester);
      await tester.pumpWidget(host(pin(NoteStatus.fixed), reduced: true));
      expect(tester.hasRunningAnimations, isFalse);
      expect(bodyTop(tester), rest);
      expect(ticks(), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('the hop does not move the tap target', (tester) async {
      var taps = 0;
      Widget fixed() => host(
        PinMarker(number: 3, status: NoteStatus.fixed, onTap: () => taps++),
      );
      await tester.pumpWidget(host(pin(NoteStatus.inProgress)));
      final center = tester.getCenter(find.byType(PinMarker));
      await tester.pumpWidget(fixed());
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(center + const Offset(0, 9));
      expect(taps, 1, reason: 'the bottom of the resting box still hits');
      await tester.pumpAndSettle();
    });
  });

  group('verify result', () {
    for (final passed in [true, false]) {
      final name = passed ? 'pass' : 'fail';

      testWidgets('a $name badge lands like a stamp', (tester) async {
        await tester.pumpWidget(host(pin(NoteStatus.fixed)));
        await tester.pumpAndSettle();
        await tester.pumpWidget(host(pin(NoteStatus.fixed, checks: passed)));
        // The badge is there at once, at its place.
        expect(find.byKey(PinMarker.checksKey), findsOneWidget);
        expect(
          tester.getSize(find.byKey(PinMarker.checksKey)),
          const Size(15, 15),
        );
        expect(tester.hasRunningAnimations, isTrue);

        await tester.pump(const Duration(milliseconds: 40));
        final rect = tester.getRect(find.byKey(PinMarker.checksKey));
        expect(rect.width, greaterThan(20), reason: 'starts large');

        await tester.pump(const Duration(milliseconds: 200));
        expect(dust(), findsOneWidget);

        await tester.pumpAndSettle();
        expect(dust(), findsNothing);
        expect(
          tester.getRect(find.byKey(PinMarker.checksKey)).size,
          const Size(15, 15),
        );
        final decoration =
            tester
                    .widget<DecoratedBox>(find.byKey(PinMarker.checksKey))
                    .decoration
                as BoxDecoration;
        expect(decoration.shape, passed ? BoxShape.circle : BoxShape.rectangle);
      });
    }

    testWidgets('a pin built with a result does not play', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.fixed, checks: true)));
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.hasRunningAnimations, isFalse);
      expect(
        tester.getRect(find.byKey(PinMarker.checksKey)).size,
        const Size(15, 15),
      );
    });

    testWidgets('a new result of the other kind plays again', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.fixed, checks: false)));
      await tester.pumpWidget(host(pin(NoteStatus.fixed, checks: true)));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('lasts the expressive time', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.fixed)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(pin(NoteStatus.fixed, checks: true)));
      await tester.pump();
      await tester.pump(
        PinPointMotion.expressiveBase - const Duration(milliseconds: 20),
      );
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reduced motion: the badge is there, at rest', (tester) async {
      await tester.pumpWidget(host(pin(NoteStatus.fixed), reduced: true));
      await tester.pumpWidget(
        host(pin(NoteStatus.fixed, checks: false), reduced: true),
      );
      expect(tester.hasRunningAnimations, isFalse);
      expect(
        tester.getRect(find.byKey(PinMarker.checksKey)).size,
        const Size(15, 15),
      );
      expect(dust(), findsNothing);
    });
  });

  group('Accept', () {
    const rect = Rect.fromLTWH(100, 100, 50, 20);
    PinPlacement placed(NoteStatus status, {bool accepted = false}) =>
        PinPlacement(
          id: 'a',
          number: 1,
          status: status,
          rect: rect,
          accepted: accepted,
        );

    late ValueNotifier<List<PinPlacement>> placements;
    var opened = 0;

    setUp(() {
      opened = 0;
      placements = ValueNotifier<List<PinPlacement>>([
        placed(NoteStatus.resolved),
      ]);
    });
    tearDown(() => placements.dispose());

    Widget layer({bool reduced = false}) => MaterialApp(
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: app!,
      ),
      home: Scaffold(
        body: PinLayer(placements: placements, onOpen: (_) => opened++),
      ),
    );

    final fold = find.byKey(PinLayer.foldKey('a'));
    final live = find.byKey(const ValueKey<String>('pinpoint.pin.a'));

    testWidgets('the pin folds away, then is gone', (tester) async {
      await tester.pumpWidget(layer());
      expect(live, findsOneWidget);
      expect(fold, findsNothing);

      placements.value = [placed(NoteStatus.resolved, accepted: true)];
      await tester.pump();
      await tester.pump();
      // The live pin is gone at once; the fold is only a picture.
      expect(live, findsNothing);
      expect(fold, findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);
      final before = tester.getRect(
        find.descendant(of: fold, matching: find.byType(PinMarker)),
      );

      // The next lookup drops the placement; the fold goes on.
      placements.value = const [];
      await tester.pump(const Duration(milliseconds: 150));
      expect(fold, findsOneWidget);
      final during = tester.getRect(
        find.descendant(of: fold, matching: find.byType(PinMarker)),
      );
      expect(during.height, lessThan(before.height));

      await tester.pump(const Duration(milliseconds: 200));
      expect(fold, findsNothing);
      expect(find.byType(PinMarker), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('lasts about 300 ms', (tester) async {
      await tester.pumpWidget(layer());
      placements.value = [placed(NoteStatus.resolved, accepted: true)];
      await tester.pump();
      // The first frame starts the clock.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(fold, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
      expect(fold, findsNothing);
    });

    testWidgets('the folding pin takes no taps and has no semantics', (
      tester,
    ) async {
      await tester.pumpWidget(layer());
      placements.value = [placed(NoteStatus.resolved, accepted: true)];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tapAt(tester.getCenter(find.byType(PinMarker)));
      expect(opened, 0);
      expect(
        find.ancestor(
          of: find.byType(PinMarker),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
      expect(
        find.ancestor(
          of: find.byType(PinMarker),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a pin that is no longer there shows no fold', (tester) async {
      await tester.pumpWidget(layer());
      // Deleted, scrolled away or on another page: not accepted.
      placements.value = const [];
      await tester.pump();
      expect(fold, findsNothing);
      expect(find.byType(PinMarker), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reduced motion: gone at once', (tester) async {
      await tester.pumpWidget(layer(reduced: true));
      placements.value = [placed(NoteStatus.resolved, accepted: true)];
      await tester.pump();
      expect(fold, findsNothing);
      expect(find.byType(PinMarker), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
