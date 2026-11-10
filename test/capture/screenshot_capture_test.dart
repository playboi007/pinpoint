import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/capture/screenshot.dart';

/// Milestone 6, build step 2: capture from the app's boundary and draw the
/// outline on.
void main() {
  const white = Color(0xFFFFFFFF);
  const blue = Color(0xFF0000FF);
  const box = Rect.fromLTWH(200, 150, 100, 60);
  final boundaryKey = GlobalKey();
  final boxKey = GlobalKey();

  /// A blue box on white, with the boundary moved by [offset].
  Future<RenderRepaintBoundary> pumpScene(
    WidgetTester tester, {
    EdgeInsets offset = EdgeInsets.zero,
  }) async {
    await tester.pumpWidget(
      Padding(
        padding: offset,
        child: RepaintBoundary(
          key: boundaryKey,
          child: ColoredBox(
            color: white,
            child: Stack(
              textDirection: TextDirection.ltr,
              children: [
                Positioned.fromRect(
                  rect: box,
                  child: ColoredBox(key: boxKey, color: blue),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
  }

  for (final ratio in [1.0, 1.25, 2.0]) {
    testWidgets('acceptance: the PNG decodes, and its size is the crop size '
        'times the pixel ratio ($ratio)', (tester) async {
      final boundary = await pumpScene(tester);
      final shot = (await tester.runAsync(
        () => captureScreenshot(
          boundary,
          tester.getRect(find.byKey(boxKey)),
          pixelRatio: ratio,
        ),
      ))!;
      final image = (await tester.runAsync(() => _decode(shot.png)))!;
      expect(image.width, (shot.crop.width * ratio).round());
      expect(image.height, (shot.crop.height * ratio).round());
      expect(image.width, shot.plan.width);
      expect(image.height, shot.plan.height);
    });

    testWidgets('acceptance: the red outline sits on the target within 1 px '
        '($ratio)', (tester) async {
      final boundary = await pumpScene(tester);
      final target = tester.getRect(find.byKey(boxKey));
      final shot = (await tester.runAsync(
        () => captureScreenshot(boundary, target, pixelRatio: ratio),
      ))!;
      final image = (await tester.runAsync(() => _decode(shot.png)))!;
      final outline = shot.plan.outline;

      expect(image.at(outline.center), _near(blue), reason: 'the box itself');
      for (final corner in [
        outline.topLeft,
        outline.topRight,
        outline.bottomLeft,
        outline.bottomRight,
      ]) {
        expect(image.at(corner), _near(outlineColor), reason: 'at $corner');
      }
      // The middle of each side, on the target's edge.
      for (final edge in [
        Offset(outline.center.dx, outline.top),
        Offset(outline.center.dx, outline.bottom),
        Offset(outline.left, outline.center.dy),
        Offset(outline.right, outline.center.dy),
      ]) {
        expect(image.at(edge), _near(outlineColor), reason: 'at $edge');
      }
      // Clear of the stroke on both sides.
      final stroke = outlineWidthFor(ratio);
      final inside = Offset(outline.left + stroke + 1, outline.center.dy);
      final outside = Offset(outline.left - stroke - 2, outline.center.dy);
      expect(image.at(inside), _near(blue));
      expect(image.at(outside), _near(white));
    });
  }

  testWidgets('a boundary away from the origin: the target is converted '
      'into the boundary first (what-if viewport, Milestone 9)', (
    tester,
  ) async {
    final boundary = await pumpScene(
      tester,
      offset: const EdgeInsets.only(left: 37, top: 21),
    );
    final target = tester.getRect(find.byKey(boxKey));
    expect(target.topLeft, box.topLeft + const Offset(37, 21));
    final shot = (await tester.runAsync(
      () => captureScreenshot(boundary, target, pixelRatio: 1),
    ))!;
    final image = (await tester.runAsync(() => _decode(shot.png)))!;
    final outline = shot.plan.outline;
    expect(image.at(outline.topLeft), _near(outlineColor));
    expect(image.at(outline.center), _near(blue));
    // The crop is reported in global coordinates, like every rect.
    expect(shot.crop.overlaps(target), isTrue);
    expect(shot.crop.left, greaterThanOrEqualTo(37));
  });

  testWidgets('every ui.Image and Picture made for the capture is disposed', (
    tester,
  ) async {
    final boundary = await pumpScene(tester);
    final live = <Object>{};
    var created = 0;
    void add(Object object) {
      created++;
      live.add(object);
    }

    ui.Image.onCreate = add;
    ui.Image.onDispose = live.remove;
    ui.Picture.onCreate = add;
    ui.Picture.onDispose = live.remove;
    try {
      await tester.runAsync(
        () => captureScreenshot(
          boundary,
          tester.getRect(find.byKey(boxKey)),
          pixelRatio: 2,
        ),
      );
    } finally {
      ui.Image.onCreate = null;
      ui.Image.onDispose = null;
      ui.Picture.onCreate = null;
      ui.Picture.onDispose = null;
    }
    // The full capture, the composed picture and its image.
    expect(created, greaterThanOrEqualTo(3));
    expect(live, isEmpty);
  });

  testWidgets('a target off the boundary gives no screenshot', (tester) async {
    final boundary = await pumpScene(tester);
    final shot = await tester.runAsync(
      () => captureScreenshot(
        boundary,
        const Rect.fromLTWH(5000, 10, 20, 20),
        pixelRatio: 1,
      ),
    );
    expect(shot, isNull);
  });
}

class _Decoded {
  _Decoded(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final ByteData rgba;

  /// The pixel at [point], clamped into the image.
  Color at(Offset point) {
    final x = point.dx.floor().clamp(0, width - 1);
    final y = point.dy.floor().clamp(0, height - 1);
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      rgba.getUint8(i + 3),
      rgba.getUint8(i),
      rgba.getUint8(i + 1),
      rgba.getUint8(i + 2),
    );
  }
}

Future<_Decoded> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = (await image.toByteData())!;
  final decoded = _Decoded(image.width, image.height, rgba);
  image.dispose();
  codec.dispose();
  return decoded;
}

Matcher _near(Color expected) => predicate<Color>((actual) {
  int channel(Color c, double Function(Color) read) => (read(c) * 255).round();
  for (final read in <double Function(Color)>[
    (c) => c.r,
    (c) => c.g,
    (c) => c.b,
  ]) {
    if ((channel(actual, read) - channel(expected, read)).abs() > 8) {
      return false;
    }
  }
  return true;
}, 'within 8 of $expected');
