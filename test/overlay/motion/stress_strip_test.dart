import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/stress_matrix.dart';
import 'package:pinpoint/src/overlay/agent_layer.dart';
import 'package:pinpoint/src/overlay/motion/stress_strip.dart';

/// Moment 6: a progress strip with one tick for each run of a stress
/// matrix, on the rail's agent item, only while the matrix runs.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() {
    StressProgress.finish();
    controller.dispose();
  });

  group('StressProgress', () {
    test('is null until a matrix starts and after it ends', () {
      expect(StressProgress.running.value, isNull);
      final seen = <StressStatus?>[];
      StressProgress.running.addListener(
        () => seen.add(StressProgress.running.value),
      );
      StressProgress.start(3);
      StressProgress.advance(1);
      StressProgress.advance(2);
      StressProgress.advance(3);
      StressProgress.finish();
      expect(seen, const [
        StressStatus(0, 3),
        StressStatus(1, 3),
        StressStatus(2, 3),
        StressStatus(3, 3),
        null,
      ]);
    });

    test('advance with no matrix running does nothing', () {
      StressProgress.advance(2);
      expect(StressProgress.running.value, isNull);
    });

    test('the words say which run is in progress', () {
      expect(
        StressStrip.describe(const StressStatus(0, 9)),
        'Stress matrix: run 1 of 9',
      );
      expect(
        StressStrip.describe(const StressStatus(3, 9)),
        'Stress matrix: run 4 of 9',
      );
      expect(
        StressStrip.describe(const StressStatus(9, 9)),
        'Stress matrix: run 9 of 9',
      );
    });
  });

  group('the strip', () {
    Future<void> pump(WidgetTester tester, {bool reduced = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: const Center(
                child: SizedBox(width: 32, child: StressStrip()),
              ),
            ),
          ),
        );

    testWidgets('shows only while a matrix runs and is gone after', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(StressStrip.stripKey), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);

      StressProgress.start(9);
      await tester.pump();
      expect(find.byKey(StressStrip.stripKey), findsOneWidget);
      StressProgress.advance(4);
      await tester.pump();
      expect(find.byKey(StressStrip.stripKey), findsOneWidget);

      StressProgress.finish();
      await tester.pump();
      expect(find.byKey(StressStrip.stripKey), findsNothing);
    });

    testWidgets('fades in once, then nothing moves: a run ending only '
        'changes the ticks', (tester) async {
      await pump(tester);
      StressProgress.start(9);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);

      StressProgress.advance(1);
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse, reason: 'a value, no tween');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reduced motion: no fade, the strip is there at once', (
      tester,
    ) async {
      await pump(tester, reduced: true);
      StressProgress.start(9);
      await tester.pump();
      expect(find.byKey(StressStrip.stripKey), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      StressProgress.advance(5);
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('up to 48 runs fit in the strip', (tester) async {
      await pump(tester);
      StressProgress.start(48);
      await tester.pumpAndSettle();
      StressProgress.advance(30);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(StressStrip.stripKey), findsOneWidget);
    });
  });

  group('on the rail', () {
    Future<void> pumpHost(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => PinPointWrapper(
            controller: controller,
            config: const PinPointConfig(allowAgentControl: true),
            child: child,
          ),
          home: const Scaffold(body: Center(child: Text('app'))),
        ),
      );
    }

    final strip = find.descendant(
      of: find.byKey(AgentLayer.toggleKey),
      matching: find.byKey(StressStrip.stripKey),
    );

    testWidgets('the agent item carries the strip while a matrix runs', (
      tester,
    ) async {
      await pumpHost(tester);
      expect(strip, findsNothing);

      StressProgress.start(9);
      await tester.pump();
      expect(strip, findsOneWidget);
      final item = tester.getRect(find.byKey(AgentLayer.toggleKey));
      final tick = tester.getRect(strip);
      expect(item.contains(tick.topLeft), isTrue);
      expect(item.contains(tick.bottomRight - const Offset(1, 1)), isTrue);
      expect(find.byTooltip('Stress matrix: run 1 of 9'), findsOneWidget);

      StressProgress.advance(3);
      await tester.pump();
      expect(find.byTooltip('Stress matrix: run 4 of 9'), findsOneWidget);

      StressProgress.finish();
      await tester.pump();
      expect(strip, findsNothing);
      expect(find.byTooltip('Allow agent control'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
