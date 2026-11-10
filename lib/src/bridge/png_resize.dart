// Plain Dart with `dart:io` (for zlib): the bridge shrinks screenshots for
// the agent with this. No image package, so the bridge adds no dependency.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// [png] scaled down to at most [maxWidth] pixels wide, keeping its aspect
/// ratio; [png] itself when it is narrow enough.
///
/// Reads 8-bit RGB and RGBA PNGs without interlacing, which is what
/// Flutter's `toByteData(format: png)` writes. Returns null for anything
/// else, and for a file that is not a valid PNG.
Uint8List? downscalePng(Uint8List png, {int maxWidth = 800}) {
  final image = decodePng(png);
  if (image == null) return null;
  if (image.width <= maxWidth) return png;
  return encodePng(_shrink(image, maxWidth));
}

/// An 8-bit image, [channels] bytes per pixel (3: RGB, 4: RGBA).
class RawImage {
  const RawImage(this.width, this.height, this.channels, this.pixels);

  final int width;
  final int height;
  final int channels;

  /// Rows top to bottom, no padding.
  final Uint8List pixels;
}

const List<int> _signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// [png] as raw pixels, or null when it is not an 8-bit RGB or RGBA PNG
/// without interlacing.
RawImage? decodePng(Uint8List png) {
  try {
    if (png.length < 8) return null;
    for (var i = 0; i < 8; i++) {
      if (png[i] != _signature[i]) return null;
    }
    final data = ByteData.sublistView(png);
    var offset = 8;
    int? width;
    int? height;
    var channels = 0;
    final idat = BytesBuilder(copy: false);
    while (offset + 8 <= png.length) {
      final length = data.getUint32(offset);
      final type = String.fromCharCodes(png, offset + 4, offset + 8);
      final start = offset + 8;
      if (start + length > png.length) return null;
      if (type == 'IHDR') {
        width = data.getUint32(start);
        height = data.getUint32(start + 4);
        final depth = png[start + 8];
        final color = png[start + 9];
        final interlace = png[start + 12];
        if (depth != 8 || interlace != 0) return null;
        channels = switch (color) {
          2 => 3,
          6 => 4,
          _ => 0,
        };
        if (channels == 0) return null;
      } else if (type == 'IDAT') {
        idat.add(Uint8List.sublistView(png, start, start + length));
      } else if (type == 'IEND') {
        break;
      }
      offset = start + length + 4; // and the CRC
    }
    if (width == null || height == null || width == 0 || height == 0) {
      return null;
    }
    final raw = Uint8List.fromList(zlib.decode(idat.takeBytes()));
    final stride = width * channels;
    if (raw.length < height * (stride + 1)) return null;
    final pixels = Uint8List(height * stride);
    for (var y = 0; y < height; y++) {
      final filter = raw[y * (stride + 1)];
      final source = y * (stride + 1) + 1;
      final row = y * stride;
      final previous = row - stride;
      for (var x = 0; x < stride; x++) {
        final a = x >= channels ? pixels[row + x - channels] : 0;
        final b = y > 0 ? pixels[previous + x] : 0;
        final c = y > 0 && x >= channels ? pixels[previous + x - channels] : 0;
        final value = raw[source + x];
        pixels[row + x] =
            switch (filter) {
              0 => value,
              1 => value + a,
              2 => value + b,
              3 => value + ((a + b) >> 1),
              4 => value + _paeth(a, b, c),
              _ => throw const FormatException('PNG filter'),
            } &
            0xFF;
      }
    }
    return RawImage(width, height, channels, pixels);
  } on Object {
    return null;
  }
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

/// [image] [maxWidth] wide: each target pixel is the average of the source
/// pixels it covers (a box filter), so text stays readable.
RawImage _shrink(RawImage image, int maxWidth) {
  final width = maxWidth;
  final height = math.max(1, (image.height * maxWidth / image.width).round());
  final channels = image.channels;
  final out = Uint8List(width * height * channels);
  final sums = List<int>.filled(channels, 0);
  for (var y = 0; y < height; y++) {
    final y0 = y * image.height ~/ height;
    final y1 = math.max(y0 + 1, (y + 1) * image.height ~/ height);
    for (var x = 0; x < width; x++) {
      final x0 = x * image.width ~/ width;
      final x1 = math.max(x0 + 1, (x + 1) * image.width ~/ width);
      sums.fillRange(0, channels, 0);
      for (var sy = y0; sy < y1; sy++) {
        var i = (sy * image.width + x0) * channels;
        for (var sx = x0; sx < x1; sx++) {
          for (var c = 0; c < channels; c++) {
            sums[c] += image.pixels[i++];
          }
        }
      }
      final count = (y1 - y0) * (x1 - x0);
      final o = (y * width + x) * channels;
      for (var c = 0; c < channels; c++) {
        out[o + c] = (sums[c] / count).round();
      }
    }
  }
  return RawImage(width, height, channels, out);
}

/// [image] as a PNG: no row filters, zlib at the default level.
Uint8List encodePng(RawImage image) {
  final stride = image.width * image.channels;
  final raw = Uint8List(image.height * (stride + 1));
  for (var y = 0; y < image.height; y++) {
    raw.setRange(
      y * (stride + 1) + 1,
      (y + 1) * (stride + 1),
      image.pixels,
      y * stride,
    );
  }
  final header = ByteData(13)
    ..setUint32(0, image.width)
    ..setUint32(4, image.height)
    ..setUint8(8, 8)
    ..setUint8(9, image.channels == 4 ? 6 : 2);
  final out = BytesBuilder(copy: false)
    ..add(_signature)
    ..add(_chunk('IHDR', header.buffer.asUint8List()))
    ..add(_chunk('IDAT', Uint8List.fromList(zlib.encode(raw))))
    ..add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

Uint8List _chunk(String type, Uint8List data) {
  final out = ByteData(12 + data.length)..setUint32(0, data.length);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(4, 8, type.codeUnits);
  bytes.setRange(8, 8 + data.length, data);
  out.setUint32(8 + data.length, _crc(bytes, 4, 8 + data.length));
  return bytes;
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(Uint8List bytes, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
