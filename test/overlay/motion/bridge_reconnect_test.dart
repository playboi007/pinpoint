import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/motion/bridge_reconnect.dart';
import 'package:pinpoint/src/overlay/toolbar.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// Moment 10: when the bridge comes back, the broken link in the
/// `BRIDGE OFFLINE` badge snaps together before the badge leaves.
void main() {
  final online = find.byKey(BridgeBadgeSlot.onlineKey);
  final offlineBadge = find.byKey(BridgeBadge.badgeKey);
  final halves = find.byIcon(PinPointIcons.link);

  /// How far apart the two halves of the link are, centre to centre.
  double gap(WidgetTester tester) {
    final parts = halves.evaluate().length;
    expect(parts, 2);
    return (tester.getCenter(halves.at(1)).dx -
            tester.getCenter(halves.at(0)).dx)
        .abs();
  }

  group('the slot', () {
    late ValueNotifier<List<String>> lines;
    late ValueNotifier<bool> active;

    setUp(() {
      lines = ValueNotifier<List<String>>(const []);
      active = ValueNotifier<bool>(true);
    });
    tearDown(() {
      lines.dispose();
      active.dispose();
    });

    Future<void> pump(WidgetTester tester, {bool reduced = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Align(
                alignment: Alignment.topRight,
                child: ListenableBuilder(
                  listenable: Listenable.merge([lines, active]),
                  builder: (context, _) => BridgeBadgeSlot(
                    offline: lines.value,
                    active: active.value,
                    builder: (lines) => BridgeBadge(offline: lines),
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('online all along: nothing shows and nothing runs', (
      tester,
    ) async {
      await pump(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(online, findsNothing);
      expect(offlineBadge, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('offline shows the broken badge and runs nothing', (
      tester,
    ) async {
      await pump(tester);
      lines.value = ['bridge offline: 127.0.0.1:4747'];
      await tester.pump();
      expect(offlineBadge, findsOneWidget);
      expect(find.byIcon(PinPointIcons.linkOff), findsOneWidget);
      expect(find.text('BRIDGE OFFLINE'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      expect(online, findsNothing);
    });

    testWidgets('back online: the halves slide together in 250 ms, the words '
        'change, the badge stays a beat and leaves', (tester) async {
      await pump(tester);
      lines.value = ['bridge offline: 127.0.0.1:4747'];
      await tester.pump();

      lines.value = const [];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(offlineBadge, findsNothing, reason: 'the detail lines go');
      expect(online, findsOneWidget);
      expect(find.byIcon(PinPointIcons.linkOff), findsNothing);
      expect(tester.hasRunningAnimations, isTrue);
      final start = gap(tester);
      expect(start, greaterThan(6), reason: 'the halves start apart');
      expect(find.text('BRIDGE OFFLINE'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 100));
      final middle = gap(tester);
      expect(middle, lessThan(start), reason: 'coming together');
      expect(find.text('BRIDGE OFFLINE'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 150));
      expect(gap(tester), closeTo(0, 0.01), reason: 'met at 250 ms');
      expect(find.text('BRIDGE ONLINE'), findsOneWidget);
      expect(find.text('BRIDGE OFFLINE'), findsNothing);

      // Stays about 600 ms, then fades out in 250 ms.
      await tester.pump(const Duration(milliseconds: 500));
      expect(online, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(online, findsOneWidget, reason: 'fading');
      await tester.pumpAndSettle();
      expect(online, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('when Pinpoint stops, the badge only goes: no reconnect', (
      tester,
    ) async {
      await pump(tester);
      lines.value = ['bridge offline: 127.0.0.1:4747'];
      await tester.pump();
      active.value = false;
      lines.value = const [];
      await tester.pump();
      expect(online, findsNothing);
      expect(offlineBadge, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('offline again while it plays: the badge comes back at '
        'once', (tester) async {
      await pump(tester);
      lines.value = ['bridge offline: 127.0.0.1:4747'];
      await tester.pump();
      lines.value = const [];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      lines.value = ['bridge offline: 127.0.0.1:4747'];
      await tester.pump();
      expect(online, findsNothing);
      expect(offlineBadge, findsOneWidget);
      await tester.pumpAndSettle();
      expect(offlineBadge, findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('reduced motion: the badge just goes', (tester) async {
      await pump(tester, reduced: true);
      lines.value = ['bridge offline: 127.0.0.1:4747'];
      await tester.pump();
      lines.value = const [];
      await tester.pump();
      expect(online, findsNothing);
      expect(offlineBadge, findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('in the system badges', () {
    testWidgets('the layer plays it when a sink answers again', (tester) async {
      final controller = PinPointController();
      final sink = HttpSink.bridge();
      final offline = ValueNotifier<List<HttpSink>>([sink]);
      addTearDown(() {
        controller.dispose();
        offline.dispose();
      });
      controller.startPicking();
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: [
              SystemBadgeLayer(controller: controller, offline: offline),
            ],
          ),
        ),
      );
      expect(offlineBadge, findsOneWidget);

      offline.value = const [];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(online, findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(online, findsNothing);
      expect(offlineBadge, findsNothing);
    });

    testWidgets('the frozen badge is not touched', (tester) async {
      final controller = PinPointController();
      final offline = ValueNotifier<List<HttpSink>>(const []);
      addTearDown(() {
        controller.dispose();
        offline.dispose();
      });
      controller.startPicking();
      controller.toggleFreeze();
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: [
              SystemBadgeLayer(controller: controller, offline: offline),
            ],
          ),
        ),
      );
      expect(find.byKey(SystemBadgeLayer.frozenKey), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
