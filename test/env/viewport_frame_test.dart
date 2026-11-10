import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/capture/screenshot.dart';
import 'package:pinpoint/src/env/device_presets.dart';
import 'package:pinpoint/src/env/environment_host.dart';
import 'package:pinpoint/src/overlay/highlight_painter.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';

/// Milestone 9, build step 1: the wrapper keeps the app in a viewport
/// frame and an environment host that are always present.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  /// The test window in logical pixels.
  void window(WidgetTester tester, Size size) {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
  }

  Widget host(Widget home) => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: home,
  );

  RenderViewportFrame frame(WidgetTester tester) =>
      tester.renderObject(find.byType(ViewportFrame));

  Future<void> setViewport(WidgetTester tester, Size? size) async {
    controller.environment.setViewport(size);
    await tester.pump();
  }

  group('acceptance', () {
    testWidgets('switching between three viewport presets keeps a counter '
        "and a text field's content", (tester) async {
      window(tester, const Size(1400, 1200));
      await tester.pumpWidget(host(const _CounterPage()));
      await tester.tap(find.text('increment'));
      await tester.tap(find.text('increment'));
      await tester.enterText(find.byType(TextField), 'kept');
      await tester.pump();
      final state = tester.state(find.byType(_CounterPage));

      for (final preset in devicePresets.take(3)) {
        await setViewport(tester, preset.size);
        expect(find.text('count: 2'), findsOneWidget, reason: '$preset');
        expect(find.text('kept'), findsOneWidget, reason: '$preset');
        expect(
          tester.state(find.byType(_CounterPage)),
          same(state),
          reason: 'the app must never remount',
        );
      }
      await setViewport(tester, null);
      expect(tester.state(find.byType(_CounterPage)), same(state));
    });

    testWidgets('at 360 wide a LayoutBuilder and MediaQuery.sizeOf both '
        'report 360', (tester) async {
      final probe = _Probe();
      await tester.pumpWidget(host(probe.build()));
      await setViewport(tester, const Size(360, 800));

      expect(probe.constraints!.maxWidth, 360);
      expect(probe.constraints!.isTight, isTrue);
      expect(probe.mediaSize, const Size(360, 800));
      // In an 800 x 600 window the frame is scaled down, never laid out
      // smaller: the app's layout does not change with the window.
      expect(frame(tester).scale, lessThan(1));
    });
  });

  group('restructure', () {
    testWidgets('with no viewport the app gets the window, unscaled', (
      tester,
    ) async {
      final probe = _Probe();
      await tester.pumpWidget(host(probe.build()));
      expect(probe.mediaSize, const Size(800, 600));
      expect(probe.constraints, BoxConstraints.tight(const Size(800, 600)));
      expect(frame(tester).appRect, Offset.zero & const Size(800, 600));
      expect(frame(tester).scale, 1);
    });

    testWidgets('the frame is outside the app boundary, the host inside', (
      tester,
    ) async {
      await tester.pumpWidget(host(const _CounterPage()));
      final boundary = find
          .descendant(
            of: find.byType(ViewportFrame),
            matching: find.byType(RepaintBoundary),
          )
          .first;
      expect(
        find.descendant(of: boundary, matching: find.byType(EnvironmentHost)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: boundary, matching: find.byType(_CounterPage)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ViewportFrame),
          matching: find.byType(InspectorOverlay),
        ),
        findsNothing,
      );
    });

    testWidgets('a viewport smaller than the window is centered at scale 1', (
      tester,
    ) async {
      window(tester, const Size(1000, 1000));
      await tester.pumpWidget(host(const _CounterPage()));
      await setViewport(tester, const Size(360, 800));
      expect(frame(tester).scale, 1);
      expect(frame(tester).appRect, const Rect.fromLTWH(320, 100, 360, 800));
      expect(
        tester.getRect(find.byType(_CounterPage)),
        const Rect.fromLTWH(320, 100, 360, 800),
      );
    });

    testWidgets('a window smaller than the viewport scales the app down, '
        'with no overflow', (tester) async {
      await tester.pumpWidget(host(const _CounterPage()));
      await setViewport(tester, const Size(1920, 1080));
      expect(tester.takeException(), isNull);
      final f = frame(tester);
      expect(f.scale, closeTo(800 / 1920, 1e-9));
      final shown = tester.getRect(find.byType(_CounterPage));
      expect(shown.width, closeTo(800, 1e-6));
      expect((Offset.zero & const Size(800, 600)).contains(shown.center), true);
      expect(shown.top, greaterThanOrEqualTo(0));
      expect(shown.bottom, lessThanOrEqualTo(600));
    });

    testWidgets('with a viewport the idle app schedules no frames', (
      tester,
    ) async {
      await tester.pumpWidget(host(const _CounterPage()));
      await setViewport(tester, const Size(360, 800));
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('taps reach the app inside a moved and scaled frame', (
      tester,
    ) async {
      await tester.pumpWidget(host(const _CounterPage()));
      await setViewport(tester, const Size(1200, 900));
      await tester.tap(find.text('increment'));
      await tester.pump();
      expect(find.text('count: 1'), findsOneWidget);
    });

    testWidgets('the frame paints the checker and the size label around '
        'the app', (tester) async {
      window(tester, const Size(1000, 1000));
      await tester.pumpWidget(host(const _CounterPage()));
      await setViewport(tester, const Size(360, 800));
      expect(
        frame(tester),
        paints
          ..rect(color: RenderViewportFrame.backdrop)
          ..path(color: RenderViewportFrame.checker),
      );
      final label = frame(tester).debugLabelText;
      expect(label, '360 × 800');
    });
  });

  group('watch out for: the boundary is no longer at the origin', () {
    // The Milestone 2 picker tests and the Milestone 6 pixel test, again
    // with a viewport active: once moved, once moved and scaled.
    for (final (name, window_) in [
      ('moved', const Size(1000, 1000)),
      ('moved and scaled', const Size(800, 600)),
    ]) {
      testWidgets('hovering a Text outlines exactly its bounds ($name)', (
        tester,
      ) async {
        window(tester, window_);
        await tester.pumpWidget(host(const _TextPage()));
        await setViewport(tester, const Size(360, 800));
        controller.startPicking();
        await tester.pump();
        final target = find.descendant(
          of: find.byType(Scaffold),
          matching: find.text('target'),
        );
        final textRect = tester.getRect(target);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(textRect.center);
        await tester.pump();

        final hovered = controller.hovered.value!;
        expect(hovered.renderObject, isA<RenderParagraph>());
        expect(hovered.globalRect.left, closeTo(textRect.left, 1e-6));
        expect(hovered.globalRect.top, closeTo(textRect.top, 1e-6));
        expect(hovered.globalRect.width, closeTo(textRect.width, 1e-6));
        expect(
          tester.renderObject(find.byKey(InspectorOverlay.highlightKey)),
          paints..rect(color: HighlightColors.hover.withValues(alpha: 0.12)),
        );
      });

      testWidgets('a screenshot of the app outlines the target ($name)', (
        tester,
      ) async {
        window(tester, window_);
        await tester.pumpWidget(host(const _BoxPage()));
        await setViewport(tester, const Size(360, 800));
        final boundary = tester.renderObject(
          find
              .descendant(
                of: find.byType(ViewportFrame),
                matching: find.byType(RepaintBoundary),
              )
              .first,
        ) as RenderRepaintBoundary;
        final target = tester.getRect(find.byKey(_BoxPage.boxKey));
        final shot = (await tester.runAsync(
          () => captureScreenshot(boundary, target, pixelRatio: 1),
        ))!;
        final image = (await tester.runAsync(() => _decode(shot.png)))!;
        final outline = shot.plan.outline;
        expect(image.at(outline.center), _near(_BoxPage.blue));
        expect(image.at(outline.topLeft), _near(outlineColor));
        expect(image.at(outline.bottomRight), _near(outlineColor));
        // The crop is in global coordinates and holds the target.
        expect(shot.crop.overlaps(target), isTrue);
      });
    }

    testWidgets('a pointer outside the viewport frame is over nothing', (
      tester,
    ) async {
      window(tester, const Size(1000, 1000));
      // A box moved 250 px left out of the app: at (70..170, 500..600) on
      // screen, outside the frame (x 320..680). The frame clips it, so the
      // picker must not find it there either.
      await tester.pumpWidget(
        host(
          Stack(
            children: [
              Positioned(
                left: 0,
                top: 400,
                child: Transform.translate(
                  offset: const Offset(-250, 0),
                  child: const SizedBox(
                    width: 100,
                    height: 100,
                    child: ColoredBox(color: Color(0xFF00FF00)),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await setViewport(tester, const Size(360, 800));
      controller.startPicking();
      await tester.pump();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(100, 550));
      await mouse.moveTo(const Offset(110, 550));
      await tester.pump();
      expect(controller.hovered.value, isNull);

      await tester.tapAt(const Offset(100, 550));
      await tester.pump();
      expect(controller.selection.value, isNull);
      expect(controller.mode, PinPointMode.picking);

      // Inside the frame it picks as before.
      await mouse.moveTo(const Offset(500, 500));
      await tester.pump();
      expect(controller.hovered.value, isNotNull);
    });

    testWidgets('a wheel outside the frame scrolls nothing', (tester) async {
      window(tester, const Size(1000, 1000));
      await tester.pumpWidget(
        host(
          Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < 100; i++)
                  SizedBox(height: 40, child: Text('row $i')),
              ],
            ),
          ),
        ),
      );
      await setViewport(tester, const Size(360, 800));
      controller.startPicking();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(100, 550));
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(100, 500),
          scrollDelta: Offset(0, 200),
        ),
      );
      await tester.pump();
      expect(position.pixels, 0);

      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(500, 500),
          scrollDelta: Offset(0, 200),
        ),
      );
      await tester.pump();
      expect(position.pixels, 200);
    });
  });
}

/// Reads what the app inherits.
class _Probe {
  BoxConstraints? constraints;
  Size? mediaSize;

  Widget build() => Builder(
    builder: (context) {
      mediaSize = MediaQuery.sizeOf(context);
      return LayoutBuilder(
        builder: (context, c) {
          constraints = c;
          return const SizedBox.expand();
        },
      );
    },
  );
}

class _CounterPage extends StatefulWidget {
  const _CounterPage();

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('count: $_count'),
          TextButton(
            onPressed: () => setState(() => _count++),
            child: const Text('increment'),
          ),
          const SizedBox(width: 200, child: TextField()),
        ],
      ),
    ),
  );
}

class _TextPage extends StatelessWidget {
  const _TextPage();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('target')));
}

class _BoxPage extends StatelessWidget {
  const _BoxPage();

  static const Key boxKey = ValueKey<String>('box');
  static const Color blue = Color(0xFF0000FF);

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFFFFFFFF),
    child: Center(
      child: SizedBox(
        width: 100,
        height: 60,
        child: ColoredBox(key: boxKey, color: blue),
      ),
    ),
  );
}

Future<_Pixels> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = (await image.toByteData())!;
  final pixels = _Pixels(image.width, image.height, data);
  image.dispose();
  codec.dispose();
  return pixels;
}

class _Pixels {
  _Pixels(this.width, this.height, this.data);

  final int width;
  final int height;
  final ByteData data;

  Color at(Offset p) {
    final x = p.dx.floor().clamp(0, width - 1);
    final y = p.dy.floor().clamp(0, height - 1);
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }
}

Matcher _near(Color expected) => predicate<Color>(
  (c) =>
      ((c.r - expected.r) * 255).abs() <= 8 &&
      ((c.g - expected.g) * 255).abs() <= 8 &&
      ((c.b - expected.b) * 255).abs() <= 8,
  'near $expected',
);
