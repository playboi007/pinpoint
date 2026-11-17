import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/overlay/replay_blocker.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// Moment 9: the replay banner slides in, its step number rolls, "Done"
/// slides out, and a diverged replay shakes once with a red bar and an
/// error glyph.
void main() {
  setUp(ReplayGate.clear);
  tearDown(ReplayGate.clear);

  Future<void> pump(WidgetTester tester, {bool reduced = false}) =>
      tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 600),
              disableAnimations: reduced,
            ),
            child: const Stack(
              fit: StackFit.expand,
              children: [ReplayBlocker()],
            ),
          ),
        ),
      );

  final banner = find.byKey(ReplayBlocker.bannerKey);
  final step = find.byKey(ReplayBlocker.stepKey);

  Finder inStep(String digit) =>
      find.descendant(of: step, matching: find.text(digit));

  void running(int n, {int of = 12}) =>
      ReplayGate.show('Replaying tape, step $n of $of', step: n);

  testWidgets('with no replay, nothing shows and nothing runs', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(banner, findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the banner slides in from the top in 250 ms and rests', (
    tester,
  ) async {
    await pump(tester);
    running(3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(banner, findsOneWidget);
    final start = tester.getTopLeft(banner).dy;
    expect(start, lessThan(0), reason: 'above the screen at first');
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pump(const Duration(milliseconds: 100));
    final middle = tester.getTopLeft(banner).dy;
    expect(middle, greaterThan(start));

    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.hasRunningAnimations, isFalse, reason: '250 ms in all');
    expect(tester.getTopLeft(banner).dy, 8);
    expect(find.textContaining('Replaying tape, step'), findsOneWidget);
    expect(find.textContaining('of 12 · Esc stops'), findsOneWidget);
    expect(inStep('3'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the step number rolls: the old digit goes up, the new one '
      'comes in from below', (tester) async {
    await pump(tester);
    running(3);
    await tester.pumpAndSettle();

    running(4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.hasRunningAnimations, isTrue);
    expect(inStep('3'), findsOneWidget, reason: 'still leaving');
    expect(inStep('4'), findsOneWidget, reason: 'coming in');
    expect(
      tester.getTopLeft(inStep('3')).dy,
      lessThan(tester.getTopLeft(inStep('4')).dy),
      reason: 'the old one is above the new one',
    );

    await tester.pumpAndSettle();
    expect(inStep('3'), findsNothing);
    expect(inStep('4'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('only the digit that changes rolls', (tester) async {
    await pump(tester);
    running(19);
    await tester.pumpAndSettle();
    running(20);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Both digits changed here: 1 to 2 and 9 to 0.
    expect(inStep('1'), findsOneWidget);
    expect(inStep('2'), findsOneWidget);
    await tester.pumpAndSettle();

    running(21);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(inStep('2'), findsOneWidget, reason: 'the tens digit stays put');
    expect(inStep('0'), findsOneWidget);
    expect(inStep('1'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('done: "Done" shows, input is back at once, then it slides '
      'out', (tester) async {
    await pump(tester);
    running(12);
    await tester.pumpAndSettle();
    expect(ReplayGate.blocking.value, isTrue);

    ReplayGate.finish(ReplayOutcome.done, 'Done');
    expect(ReplayGate.blocking.value, isFalse, reason: 'never delayed');
    await tester.pump();
    expect(find.text('Done'), findsOneWidget);
    expect(find.byIcon(PinPointIcons.check), findsOneWidget);
    expect(find.textContaining('Esc stops'), findsNothing);
    expect(find.byKey(ReplayBlocker.errorBarKey), findsNothing);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Done'), findsOneWidget, reason: 'it stays a moment');
    expect(tester.getTopLeft(banner).dy, 8);

    // The hold ends at 1.2 s, and the banner leaves in 250 ms.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    expect(tester.getTopLeft(banner).dy, lessThan(8));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(ReplayGate.banner.value, isNull);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('diverged: one short shake, a red left bar, an error glyph, '
      'and the reason', (tester) async {
    await pump(tester);
    running(2);
    await tester.pumpAndSettle();
    final home = tester.getCenter(banner).dx;

    ReplayGate.finish(
      ReplayOutcome.diverged,
      'Replay diverged: step 2: no Text found',
    );
    await tester.pump();
    final xs = <double>[];
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      xs.add(tester.getCenter(banner).dx);
    }
    expect(
      xs.any((x) => (x - home).abs() > 1),
      isTrue,
      reason: 'it moved sideways',
    );
    expect(xs.last, closeTo(home, 0.01), reason: 'and came back to rest');
    expect(
      xs.map((x) => (x - home).abs()).reduce((a, b) => a > b ? a : b),
      lessThan(10),
      reason: 'short',
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(tester.hasRunningAnimations, isFalse);
    // pumpAndSettle runs the hold too; check the bar before it ends in a
    // second run below.
  });

  testWidgets('diverged: the red bar and the glyph, and it stays 3.5 s', (
    tester,
  ) async {
    await pump(tester);
    running(2);
    await tester.pumpAndSettle();
    ReplayGate.finish(ReplayOutcome.diverged, 'Replay diverged: step 2');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final bar = find.byKey(ReplayBlocker.errorBarKey);
    expect(bar, findsOneWidget);
    final color = tester
        .widget<ColoredBox>(
          find.descendant(of: bar, matching: find.byType(ColoredBox)),
        )
        .color;
    expect(color, PinPointTokens.redline.err);
    expect(find.byIcon(PinPointIcons.error), findsOneWidget);
    expect(find.text('Replay diverged: step 2'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2800));
    expect(banner, findsOneWidget, reason: 'still there before 3.5 s');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
  });

  testWidgets('stopped: the banner slides out at once, with no "Done"', (
    tester,
  ) async {
    await pump(tester);
    running(2);
    await tester.pumpAndSettle();
    ReplayGate.clear();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(banner, findsOneWidget, reason: 'sliding out');
    expect(find.text('Done'), findsNothing);
    expect(find.textContaining('Replaying tape'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
  });

  testWidgets('a new replay while the last words show takes the banner '
      'back', (tester) async {
    await pump(tester);
    running(2);
    await tester.pumpAndSettle();
    ReplayGate.finish(ReplayOutcome.done, 'Done');
    await tester.pump(const Duration(milliseconds: 500));
    running(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    expect(banner, findsOneWidget, reason: 'the old hold did not hide it');
    expect(find.text('Done'), findsNothing);
    expect(find.textContaining('Replaying tape'), findsOneWidget);
    ReplayGate.clear();
    await tester.pumpAndSettle();
  });

  testWidgets('it takes real input only while a replay blocks', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
            ),
            const ReplayBlocker(),
          ],
        ),
      ),
    );
    await tester.tapAt(const Offset(300, 300));
    expect(taps, 1);
    running(1);
    await tester.pump();
    await tester.tapAt(const Offset(300, 300));
    expect(taps, 1, reason: 'blocked while it runs');
    ReplayGate.finish(ReplayOutcome.done, 'Done');
    await tester.pump();
    await tester.tapAt(const Offset(300, 300));
    expect(taps, 2, reason: 'the banner never holds input');
    ReplayGate.clear();
    await tester.pumpAndSettle();
  });

  group('reduced motion', () {
    testWidgets('the banner is there at once and nothing moves', (
      tester,
    ) async {
      await pump(tester, reduced: true);
      running(3);
      await tester.pump();
      expect(banner, findsOneWidget);
      expect(tester.getTopLeft(banner).dy, 8);
      expect(tester.hasRunningAnimations, isFalse);

      running(4);
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(inStep('3'), findsNothing, reason: 'no roll: 4 at once');
      expect(inStep('4'), findsOneWidget);
    });

    testWidgets('done and diverged show their words and shake nothing', (
      tester,
    ) async {
      await pump(tester, reduced: true);
      running(3);
      await tester.pump();
      ReplayGate.finish(ReplayOutcome.diverged, 'Replay diverged: step 3');
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.byKey(ReplayBlocker.errorBarKey), findsOneWidget);
      expect(find.byIcon(PinPointIcons.error), findsOneWidget);
      expect(
        tester.getTopLeft(banner).dx,
        closeTo((800 - tester.getSize(banner).width) / 2, 0.01),
      );

      await tester.pump(const Duration(milliseconds: 3600));
      await tester.pump();
      expect(banner, findsNothing, reason: 'gone at once, no slide');
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
