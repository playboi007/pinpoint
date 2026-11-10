import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/png_resize.dart';

/// Milestone 8, build step 4: the bridge shrinks screenshots for the agent
/// without an image package.
void main() {
  RawImage solid(int width, int height, List<int> pixel) {
    final pixels = Uint8List(width * height * pixel.length);
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] = pixel[i % pixel.length];
    }
    return RawImage(width, height, pixel.length, pixels);
  }

  test('a wide PNG comes back 800 px wide, same aspect, same colour', () {
    final png = encodePng(solid(1600, 1000, [10, 120, 250, 255]));
    final small = downscalePng(png)!;
    final image = decodePng(small)!;
    expect(image.width, 800);
    expect(image.height, 500);
    expect(image.channels, 4);
    expect(image.pixels.sublist(0, 4), [10, 120, 250, 255]);
    expect(small.length, lessThan(png.length));
  });

  test('a narrow PNG is returned as it is', () {
    final png = encodePng(solid(320, 200, [1, 2, 3]));
    expect(identical(downscalePng(png), png), isTrue);
  });

  test('averages, so a 1 px line does not vanish or alias', () {
    // Two columns, black then white, scaled to one: grey.
    final pixels = Uint8List.fromList([0, 0, 0, 255, 255, 255]);
    final png = encodePng(RawImage(2, 1, 3, pixels));
    final image = decodePng(downscalePng(png, maxWidth: 1)!)!;
    expect(image.pixels, [128, 128, 128]);
  });

  test('not a PNG, or a format it does not read: null', () {
    expect(downscalePng(Uint8List.fromList([1, 2, 3])), isNull);
    final png = encodePng(solid(1000, 1, [1, 2, 3, 4]));
    png[8 + 8 + 8] = 16; // IHDR bit depth 16
    expect(decodePng(png), isNull);
  });

  // The real input: what Flutter's encoder writes, with its row filters.
  testWidgets('reads a PNG that Flutter wrote', (tester) async {
    final bytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 900, 40),
        Paint()..color = const Color(0xFF2962FF),
      );
      canvas.drawRect(
        const Rect.fromLTWH(0, 20, 900, 20),
        Paint()..color = const Color(0xFFFF0000),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(900, 40);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    });
    final raw = decodePng(bytes!)!;
    expect(raw.width, 900);
    expect(raw.height, 40);
    final top = raw.pixels.sublist(0, raw.channels);
    expect(top.take(3), [0x29, 0x62, 0xFF]);
    final bottom = (39 * 900 + 899) * raw.channels;
    expect(raw.pixels.sublist(bottom, bottom + 3), [0xFF, 0, 0]);

    final small = decodePng(downscalePng(bytes)!)!;
    expect(small.width, 800);
    expect(small.height, 36);
  });
}
