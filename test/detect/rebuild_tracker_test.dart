import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/detect/rebuild_tracker.dart';

import '../support/markers.dart';

const String _file = 'test/detect/rebuild_tracker_test.dart';

/// Milestone 10, build step 4: rebuild heat.
///
/// `debugOnRebuildDirtyWidget` is a single global slot: every test puts it
/// back to null in its own body.
void main() {
  late Duration now;
  late HookRegistry registry;
  late RebuildTracker tracker;

  setUp(() {
    now = Duration.zero;
    registry = HookRegistry();
    tracker = RebuildTracker(registry: registry, clock: () => now);
  });

  Future<void> rebuild(WidgetTester tester, GlobalKey<_TickState> key) async {
    key.currentState!.tick();
    await tester.pump();
  }

  testWidgets('is off until installed', (tester) async {
    expect(debugOnRebuildDirtyWidget, isNull);
    expect(tracker.install(), isTrue);
    expect(debugOnRebuildDirtyWidget, isNotNull);
    registry.dispose();
    expect(debugOnRebuildDirtyWidget, isNull);
  });

  testWidgets('counts rebuilds per element in a rolling 5 second window', (
    tester,
  ) async {
    final key = GlobalKey<_TickState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            // PIN:hot_widget
            _Tick(key: key),
            const Text('cold'),
          ],
        ),
      ),
    );
    tracker.install();
    for (var i = 0; i < 12; i++) {
      await rebuild(tester, key);
    }
    final locator = FindingLocator(boundary: tester.binding.rootElement);
    var top = tracker.findings(locator: locator);
    expect(top.first.kind, 'rebuild_heat');
    expect(top.first.severity, Severity.info);
    expect(top.first.data['count'], 12);
    expect(top.first.summary, '_Tick rebuilt 12 times in 5 s');
    expect(top.first.source?.line, markerLine(_file, 'hot_widget'));
    expect(top.first.rect, tester.getRect(find.byType(_Tick)));

    // Three seconds later, three more; six seconds after the first ones,
    // only the last three are in the window.
    now = const Duration(seconds: 3);
    for (var i = 0; i < 3; i++) {
      await rebuild(tester, key);
    }
    top = tracker.findings(locator: locator);
    expect(top.first.data['count'], 15);
    now = const Duration(seconds: 6);
    top = tracker.findings(locator: locator, minCount: 1);
    expect(top.first.data['count'], 3);
    registry.dispose();
  });

  testWidgets("lists the top ten, without Pinpoint's own elements", (
    tester,
  ) async {
    final keys = [for (var i = 0; i < 12; i++) GlobalKey<_TickState>()];
    final outside = GlobalKey<_TickState>();
    final app = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            KeyedSubtree(
              key: app,
              child: Column(children: [for (final k in keys) _Tick(key: k)]),
            ),
            // Beside the app, as Pinpoint's UI is.
            _Tick(key: outside),
          ],
        ),
      ),
    );
    tracker.install();
    for (var round = 0; round < 20; round++) {
      for (final k in keys) {
        k.currentState!.tick();
      }
      outside.currentState!.tick();
      await tester.pump();
    }
    final top = tracker.findings(
      locator: FindingLocator(boundary: app.currentContext! as Element),
    );
    expect(top, hasLength(10));
    expect(top.map((f) => f.element), isNot(contains(outside.currentContext)));
    registry.dispose();
  });

  testWidgets('watch out for: DevTools takes the slot over', (tester) async {
    void devTools(Element element, bool builtOnce) {}

    // DevTools first: its tracking holds the slot, and Pinpoint must not
    // write it (DevTools asserts the slot is null when it turns on).
    debugOnRebuildDirtyWidget = devTools;
    expect(tracker.install(), isFalse);
    expect(debugOnRebuildDirtyWidget, same(devTools));
    debugOnRebuildDirtyWidget = null;

    // Pinpoint first, then DevTools turns its tracking off, which clears
    // the slot: Pinpoint notices and does not put itself back.
    expect(tracker.install(), isTrue);
    expect(tracker.takenOver, isFalse);
    debugOnRebuildDirtyWidget = null;
    expect(tracker.takenOver, isTrue);
    debugOnRebuildDirtyWidget = devTools;
    tracker.uninstall();
    expect(debugOnRebuildDirtyWidget, same(devTools));
    debugOnRebuildDirtyWidget = null;
    registry.dispose();
  });

  testWidgets('uninstalling forgets the counts', (tester) async {
    final key = GlobalKey<_TickState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: _Tick(key: key),
      ),
    );
    tracker.install();
    await rebuild(tester, key);
    tracker.uninstall();
    expect(debugOnRebuildDirtyWidget, isNull);
    tracker.install();
    expect(
      tracker.findings(
        locator: FindingLocator(boundary: tester.binding.rootElement),
        minCount: 1,
      ),
      isEmpty,
    );
    registry.dispose();
  });

  group('in the wrapper', () {
    late PinPointController controller;

    setUp(() => controller = PinPointController());
    tearDown(() => controller.dispose());

    testWidgets('the switch installs and removes the hook', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: child),
          home: const SizedBox(),
        ),
      );
      expect(debugOnRebuildDirtyWidget, isNull);
      controller.findings.trackRebuilds = true;
      expect(debugOnRebuildDirtyWidget, isNotNull);
      controller.findings.trackRebuilds = false;
      expect(debugOnRebuildDirtyWidget, isNull);

      controller.findings.trackRebuilds = true;
      await tester.pumpWidget(const SizedBox());
      expect(debugOnRebuildDirtyWidget, isNull);
    });

    testWidgets('a slot DevTools holds turns the switch back off and says '
        'so', (tester) async {
      void devTools(Element element, bool builtOnce) {}
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: child),
          home: const SizedBox(),
        ),
      );
      debugOnRebuildDirtyWidget = devTools;
      controller.findings.trackRebuilds = true;
      expect(controller.findings.trackRebuilds, isFalse);
      expect(controller.findings.rebuildsTakenOver, isTrue);
      expect(debugOnRebuildDirtyWidget, same(devTools));
      debugOnRebuildDirtyWidget = null;
    });
  });
}

class _Tick extends StatefulWidget {
  const _Tick({super.key});

  @override
  State<_Tick> createState() => _TickState();
}

class _TickState extends State<_Tick> {
  int _count = 0;

  void tick() => setState(() => _count++);

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 20, height: 20, child: Text('$_count'));
}
