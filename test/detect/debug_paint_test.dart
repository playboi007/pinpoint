import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/capture/screenshot.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/detect/debug_paint.dart';

/// Milestone 10, build step 4: the debug paint toggles.
///
/// `flutter test` fails a test that leaves a debug paint flag on, or the
/// repaint rainbow's color changed: every test turns them off in its body.
void main() {
  RenderBox box(WidgetTester tester) =>
      tester.renderObject<RenderBox>(find.byKey(_box));

  Widget app() => const Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(child: SizedBox(key: _box, width: 40, height: 40)),
    ),
  );

  testWidgets('each flag goes on and off twice, and the screen repaints '
      'each time without a rebuild', (tester) async {
    final registry = HookRegistry();
    final toggles = DebugPaintToggles(registry);
    await tester.pumpWidget(app());

    for (final flag in DebugPaintFlag.values) {
      for (var round = 0; round < 2; round++) {
        toggles.apply({flag});
        expect(flag.isOn, isTrue, reason: '$flag on, round $round');
        // Marked for paint now, not at the next rebuild.
        expect(box(tester).debugNeedsPaint, isTrue, reason: '$flag');
        await tester.pump();
        expect(box(tester).debugNeedsPaint, isFalse);

        toggles.apply(const {});
        expect(flag.isOn, isFalse, reason: '$flag off, round $round');
        expect(box(tester).debugNeedsPaint, isTrue, reason: '$flag');
        await tester.pump();
      }
    }
    expect(debugPaintFlagsOn(), isEmpty);
    registry.dispose();
  });

  testWidgets('the rainbow color comes back when the rainbow goes off', (
    tester,
  ) async {
    final registry = HookRegistry();
    final toggles = DebugPaintToggles(registry);
    final before = debugCurrentRepaintColor;
    await tester.pumpWidget(app());
    toggles.apply({DebugPaintFlag.rainbow});
    await tester.pump();
    toggles.apply(const {});
    expect(debugCurrentRepaintColor, before);
    registry.dispose();
  });

  testWidgets('disposing the registry turns every flag off', (tester) async {
    final registry = HookRegistry();
    DebugPaintToggles(registry).apply(DebugPaintFlag.values.toSet());
    expect(debugPaintFlagsOn(), hasLength(DebugPaintFlag.values.length));
    registry.dispose();
    expect(debugPaintFlagsOn(), isEmpty);
  });

  testWidgets('a flag the developer turned on stays on', (tester) async {
    debugPaintBaselinesEnabled = true;
    final registry = HookRegistry();
    final toggles = DebugPaintToggles(registry)
      ..apply({DebugPaintFlag.baselines})
      ..apply(const {});
    expect(debugPaintBaselinesEnabled, isTrue);
    registry.dispose();
    expect(debugPaintBaselinesEnabled, isTrue);
    debugPaintBaselinesEnabled = false;
    expect(toggles, isNotNull);
  });

  group('in the wrapper', () {
    late PinPointController controller;

    setUp(() => controller = PinPointController());
    tearDown(() => controller.dispose());

    testWidgets('the panel chips set the flags; disposing restores them', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: child),
          home: const SizedBox(),
        ),
      );
      controller.findings.setDebugPaint(DebugPaintFlag.size, on: true);
      expect(debugPaintSizeEnabled, isTrue);
      controller.findings.setDebugPaint(DebugPaintFlag.size, on: false);
      expect(debugPaintSizeEnabled, isFalse);
      controller.findings.setDebugPaint(DebugPaintFlag.layers, on: true);
      expect(debugPaintLayerBordersEnabled, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(debugPaintLayerBordersEnabled, isFalse);
    });
  });
}

const Key _box = ValueKey<String>('box');
