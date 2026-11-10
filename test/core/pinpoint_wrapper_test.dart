import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';

/// Milestone 1 acceptance tests for the wrapper.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  /// The app under test, wrapped the way a host app does it: in
  /// `MaterialApp.builder`, above the Navigator.
  Widget host({
    Widget home = const _CounterPage(),
    PinPointConfig config = const PinPointConfig(),
    bool withHome = true,
  }) {
    return MaterialApp(
      builder: (context, child) => PinPointWrapper(
        config: config,
        controller: controller,
        child: child,
      ),
      home: withHome ? home : null,
    );
  }

  Finder appBoundary() => find
      .descendant(
        of: find.byType(PinPointWrapper),
        matching: find.byType(RepaintBoundary),
      )
      .first;

  group('acceptance', () {
    testWidgets('a counter keeps its value and its State across toggling', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('increment'));
      await tester.tap(find.text('increment'));
      await tester.pump();
      expect(find.text('count: 2'), findsOneWidget);
      final stateBefore = tester.state(find.byType(_CounterPage));

      for (var i = 0; i < 3; i++) {
        controller.toggle();
        await tester.pump();
        expect(controller.isActive, isTrue);
        controller.toggle();
        await tester.pump();
        expect(controller.isActive, isFalse);
      }

      expect(find.text('count: 2'), findsOneWidget);
      expect(
        tester.state(find.byType(_CounterPage)),
        same(stateBefore),
        reason: 'the app subtree must never remount',
      );
    });

    testWidgets('with enabled: false the wrapper adds nothing', (
      tester,
    ) async {
      const app = _CounterPage();
      await tester.pumpWidget(
        MaterialApp(
          home: PinPointWrapper(
            config: const PinPointConfig(enabled: false),
            controller: controller,
            child: app,
          ),
        ),
      );

      final wrapper = tester.element(find.byType(PinPointWrapper));
      final children = <Element>[];
      wrapper.visitChildren(children.add);
      expect(children, hasLength(1));
      expect(children.single.widget, same(app));
      expect(find.byType(InspectorOverlay), findsNothing);
    });
  });

  group('watch out for', () {
    testWidgets('builder child is null when the app has no home or routes', (
      tester,
    ) async {
      await tester.pumpWidget(host(withHome: false));
      expect(tester.takeException(), isNull);
      expect(find.byType(InspectorOverlay), findsOneWidget);
    });

    testWidgets('the app sees the same tight constraints as without Pinpoint', (
      tester,
    ) async {
      BoxConstraints? seen;
      Widget probe() => LayoutBuilder(
        builder: (context, constraints) {
          seen = constraints;
          return const SizedBox();
        },
      );

      await tester.pumpWidget(
        MaterialApp(builder: (context, child) => probe()),
      );
      final without = seen;

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: probe()),
        ),
      );
      final withWrapper = seen;

      expect(without!.isTight, isTrue);
      expect(withWrapper, without);
    });
  });

  group('idle', () {
    testWidgets('taps reach the app through the Pinpoint layer', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('increment'));
      await tester.pump();
      expect(find.text('count: 1'), findsOneWidget);
    });

    testWidgets('schedules no frames', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the app sits inside the app RepaintBoundary', (tester) async {
      await tester.pumpWidget(host());
      expect(
        find.descendant(of: appBoundary(), matching: find.byType(_CounterPage)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: appBoundary(),
          matching: find.byType(InspectorOverlay),
        ),
        findsNothing,
      );
    });
  });

  testWidgets('hot reload clears the selection', (tester) async {
    await tester.pumpWidget(host());
    controller
      ..startPicking()
      ..select(const Offset(10, 10));
    await tester.pump();

    // reassembleApplication() completes at the end of the next frame, so
    // pump that frame before awaiting it, or the test hangs.
    final reassembled = tester.binding.reassembleApplication();
    await tester.pump();
    await reassembled;

    expect(controller.selectedPosition, isNull);
    expect(controller.mode, PinPointMode.picking);
  });
}

class _CounterPage extends StatefulWidget {
  const _CounterPage();

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('count: $_count'),
            ElevatedButton(
              onPressed: () => setState(() => _count++),
              child: const Text('increment'),
            ),
          ],
        ),
      ),
    );
  }
}
